// cursorblur.swift — real-time motion blur for the macOS cursor
//
// Build:    ./build.sh            (CLI binary)   |   ./build.sh app   (cursorblur.app)
// Run:      ./build.sh run        (add --hide to start with the real cursor hidden)
// Settings and Quit: the ◐ icon in the menu bar (or Ctrl+C in Terminal)
//
// Requires macOS 14+ (native display link, follows ProMotion refresh up to 120 Hz).

import AppKit
import QuartzCore
import ServiceManagement

// MARK: - Impostazioni persistenti

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    static let factory: [String: Any] = [
        "samples": 24,        // copie interpolate per segmento
        "strength": 1.0,      // intensità complessiva
        "headBias": 0.6,      // 0 = scia uniforme, 1 = sfuma verso la coda
        "minDistance": 1.5,   // soglia di movimento in punti
        "frames": 1,          // quanti frame passati copre la scia ("tempo di otturazione")
        "hideCursor": false,
        "enabled": true,
    ]

    var samples: Int       { didSet { d.set(samples, forKey: "samples") } }
    var strength: Double   { didSet { d.set(strength, forKey: "strength") } }
    var headBias: Double   { didSet { d.set(headBias, forKey: "headBias") } }
    var minDistance: Double { didSet { d.set(minDistance, forKey: "minDistance") } }
    var frames: Int        { didSet { d.set(frames, forKey: "frames") } }
    var hideCursor: Bool   { didSet { d.set(hideCursor, forKey: "hideCursor") } }
    var enabled: Bool      { didSet { d.set(enabled, forKey: "enabled") } }

    private init() {
        d.register(defaults: Settings.factory)
        samples = d.integer(forKey: "samples")
        strength = d.double(forKey: "strength")
        headBias = d.double(forKey: "headBias")
        minDistance = d.double(forKey: "minDistance")
        frames = d.integer(forKey: "frames")
        hideCursor = d.bool(forKey: "hideCursor")
        enabled = d.bool(forKey: "enabled")
        if CommandLine.arguments.contains("--hide") { hideCursor = true }
    }

    func reset() {
        samples = 24; strength = 1.0; headBias = 0.6
        minDistance = 1.5; frames = 1; hideCursor = false
    }
}

// MARK: - API private per nascondere il cursore anche in background

@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> Int32

@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ targetCid: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

func hideSystemCursor() {
    let cid = _CGSDefaultConnection()
    _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    CGDisplayHideCursor(CGMainDisplayID())
}

func showSystemCursor() {
    CGDisplayShowCursor(CGMainDisplayID())
}

// MARK: - Vista che disegna la scia

final class BlurView: NSView {
    var screenOrigin: CGPoint = .zero
    private var pts: [CGPoint] = []
    private var moving = false
    private var hide = false
    private var image: NSImage?
    private var hotSpot: CGPoint = .zero
    private var lastDirty: NSRect = .zero

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    /// `global`: posizioni dalla più vecchia alla più recente, in coordinate globali.
    func update(points global: [CGPoint], moving: Bool, hide: Bool, cursor: NSCursor) {
        pts = global.map { CGPoint(x: $0.x - screenOrigin.x, y: $0.y - screenOrigin.y) }
        self.moving = moving
        self.hide = hide
        image = cursor.image
        hotSpot = cursor.hotSpot

        var dirty = NSRect.zero
        if moving || hide, let img = image, let head = pts.last {
            let rects = moving ? pts.map { cursorRect(at: $0, size: img.size) }
                               : [cursorRect(at: head, size: img.size)]
            dirty = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
                .insetBy(dx: -2, dy: -2).intersection(bounds)
        }
        let toInvalidate = dirty.union(lastDirty)
        if !toInvalidate.isEmpty { setNeedsDisplay(toInvalidate) }
        lastDirty = dirty
    }

    private func cursorRect(at p: CGPoint, size: CGSize) -> NSRect {
        // hotSpot è in coordinate immagine con origine in alto a sinistra
        NSRect(x: p.x - hotSpot.x, y: p.y - (size.height - hotSpot.y),
               width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill(using: .copy)
        guard let img = image, let head = pts.last else { return }
        let size = img.size

        func stamp(_ p: CGPoint, _ alpha: CGFloat) {
            img.draw(in: cursorRect(at: p, size: size), from: .zero,
                     operation: .sourceOver, fraction: alpha)
        }

        if !moving {
            if hide { stamp(head, 1) }
            return
        }

        let s = Settings.shared
        let n = max(2, s.samples)
        let k = pts.count - 1
        guard k >= 1 else { return }
        let base = min(1, CGFloat(s.strength) * 2.0 / CGFloat(n))
        let bias = CGFloat(s.headBias)

        var lastSegmentDrawn = false
        for j in 0..<k {
            let a = pts[j], b = pts[j + 1]
            if hypot(b.x - a.x, b.y - a.y) < 0.5 { continue }
            let isLast = (j == k - 1)
            if isLast { lastSegmentDrawn = true }
            // Senza "nascondi cursore" saltiamo la testa per non sdoppiare il cursore reale
            let count = (isLast && hide) ? n + 1 : n
            for i in 0..<count {
                let tl = CGFloat(i) / CGFloat(n)
                let p = CGPoint(x: a.x + (b.x - a.x) * tl, y: a.y + (b.y - a.y) * tl)
                let tg = (CGFloat(j) + tl) / CGFloat(k)
                stamp(p, base * ((1 - bias) + bias * tg))
            }
        }
        // Cursore quasi fermo ma scia ancora in coda: testa nitida
        if hide && !lastSegmentDrawn { stamp(head, 1) }
    }
}

// MARK: - Riga del menu con slider

final class SliderItemView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let title: String
    private let format: (Double) -> String
    private let getter: () -> Double
    private let setter: (Double) -> Void
    var onRelease: (() -> Void)?

    init(title: String, min: Double, max: Double,
         format: @escaping (Double) -> String,
         get: @escaping () -> Double, set: @escaping (Double) -> Void) {
        self.title = title
        self.format = format
        self.getter = get
        self.setter = set
        slider = NSSlider(value: get(), minValue: min, maxValue: max, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 46))

        label.font = .menuFont(ofSize: 13)
        label.frame = NSRect(x: 20, y: 25, width: 236, height: 17)
        slider.frame = NSRect(x: 18, y: 4, width: 236, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        addSubview(label)
        addSubview(slider)
        refreshLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        setter(slider.doubleValue)
        refreshLabel()
        if NSApp.currentEvent?.type == .leftMouseUp { onRelease?() }
    }

    func reload() {
        slider.doubleValue = getter()
        refreshLabel()
    }

    private func refreshLabel() {
        label.stringValue = "\(title): \(format(slider.doubleValue))"
    }
}

// MARK: - Controller

final class Controller: NSObject, NSMenuDelegate {
    private var views: [BlurView] = []
    private var windows: [NSWindow] = []
    private var link: CADisplayLink?
    private var history: [CGPoint] = [NSEvent.mouseLocation]
    private var statusItem: NSStatusItem?
    private var loginItem: NSMenuItem?
    private var sliders: [SliderItemView] = []
    private var enabledItem: NSMenuItem!
    private var hideItem: NSMenuItem!
    private var hideCount = 0   // CGDisplayHideCursor è a conteggio: teniamo traccia delle chiamate
    private var signalSources: [DispatchSourceSignal] = []

    func start() {
        buildWindows()
        setupMenu()
        setupSignals()
        applyCursorVisibility()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(cleanup),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    // Finestre trasparenti, una per schermo
    private func buildWindows() {
        link?.invalidate()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll(); views.removeAll()

        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]

            let v = BlurView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.wantsLayer = true
            v.screenOrigin = screen.frame.origin
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w); views.append(v)
        }

        if let first = views.first {
            let dl = first.displayLink(target: self, selector: #selector(tick(_:)))
            dl.add(to: .main, forMode: .common)   // .common: continua anche col menu aperto
            link = dl
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let s = Settings.shared
        history.append(NSEvent.mouseLocation)
        let maxCount = max(1, s.frames) + 1
        if history.count > maxCount { history.removeFirst(history.count - maxCount) }

        var length: CGFloat = 0
        if history.count >= 2 {
            for i in 1..<history.count {
                length += hypot(history[i].x - history[i - 1].x, history[i].y - history[i - 1].y)
            }
        }
        let moving = s.enabled && length >= CGFloat(s.minDistance)
        let hide = s.enabled && s.hideCursor
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        for v in views { v.update(points: history, moving: moving, hide: hide, cursor: cursor) }
    }

    private func hideNow() { hideSystemCursor(); hideCount += 1 }

    private func showAll() {
        while hideCount > 0 { showSystemCursor(); hideCount -= 1 }
    }

    private func applyCursorVisibility() {
        let s = Settings.shared
        let want = s.enabled && s.hideCursor
        if want && hideCount == 0 { hideNow() }
        else if !want { showAll() }
    }

    /// macOS rimostra il cursore dopo l'interazione col menu: se serve, lo rinascondiamo.
    private func reassertHidden() {
        let s = Settings.shared
        guard s.enabled && s.hideCursor else { return }
        hideNow()
    }

    func menuDidClose(_ menu: NSMenu) {
        // piccolo ritardo: il sistema ripristina il cursore subito dopo la chiusura
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.reassertHidden()
        }
    }

    // Menu nella barra
    private func setupMenu() {
        let s = Settings.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◐"
        let menu = NSMenu()
        menu.delegate = self

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = s.enabled ? .on : .off
        menu.addItem(enabledItem)

        hideItem = NSMenuItem(title: "Hide real cursor", action: #selector(toggleHide), keyEquivalent: "")
        hideItem.target = self
        hideItem.state = s.hideCursor ? .on : .off
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let int: (Double) -> String = { "\(Int($0.rounded()))" }
        sliders = [
            SliderItemView(title: "Strength", min: 0.2, max: 2.0,
                           format: { String(format: "%.2f", $0) },
                           get: { s.strength }, set: { s.strength = $0 }),
            SliderItemView(title: "Trail length (frames)", min: 1, max: 6, format: int,
                           get: { Double(s.frames) }, set: { s.frames = Int($0.rounded()) }),
            SliderItemView(title: "Samples", min: 4, max: 48, format: int,
                           get: { Double(s.samples) }, set: { s.samples = Int($0.rounded()) }),
            SliderItemView(title: "Head bias", min: 0, max: 1,
                           format: { "\(Int(($0 * 100).rounded()))%" },
                           get: { s.headBias }, set: { s.headBias = $0 }),
            SliderItemView(title: "Movement threshold (pt)", min: 0, max: 10,
                           format: { String(format: "%.1f", $0) },
                           get: { s.minDistance }, set: { s.minDistance = $0 }),
        ]
        for v in sliders {
            v.onRelease = { [weak self] in self?.reassertHidden() }
            let mi = NSMenuItem()
            mi.view = v
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        if Bundle.main.bundleIdentifier != nil {
            loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
            loginItem?.target = self
            loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(loginItem!)
        }
        let reset = NSMenuItem(title: "Reset to defaults", action: #selector(resetDefaults), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        let quit = NSMenuItem(title: "Quit cursorblur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("cursorblur: launch at login failed: \(error)")
        }
        loginItem?.state = svc.status == .enabled ? .on : .off
    }

    @objc private func toggleEnabled() {
        let s = Settings.shared
        s.enabled.toggle()
        enabledItem.state = s.enabled ? .on : .off
        item(title: s.enabled ? "◐" : "○")
        applyCursorVisibility()
    }

    @objc private func toggleHide() {
        let s = Settings.shared
        s.hideCursor.toggle()
        hideItem.state = s.hideCursor ? .on : .off
        applyCursorVisibility()
    }

    @objc private func resetDefaults() {
        Settings.shared.reset()
        sliders.forEach { $0.reload() }
        hideItem.state = .off
        applyCursorVisibility()
    }

    private func item(title: String) { statusItem?.button?.title = title }

    @objc private func screensChanged() { buildWindows() }

    private func setupSignals() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    @objc private func cleanup() {
        showAll()
    }
}

// MARK: - Avvio

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
app.run()
