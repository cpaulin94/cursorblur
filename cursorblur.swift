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

// Deprecated in the SDK but still exported and accurate; used to notice when
// macOS resets the hide count (app switches, Dock, Mission Control, menus…).
@_silgen_name("CGCursorIsVisible")
func systemCursorIsVisible() -> Int32

// MARK: - Cached cursor image

/// The current system cursor, rasterized once at the display's backing scale.
/// Fetching `NSCursor.currentSystem` is a window-server round trip that returns a
/// fresh NSImage, so the controller refreshes it only when needed.
struct CursorSnapshot {
    var image: CGImage?
    var size: CGSize = .zero
    var hotSpot: CGPoint = .zero

    static func of(_ c: NSCursor) -> CursorSnapshot {
        let size = c.image.size
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        guard size.width > 0, size.height > 0,
              let cg = CGContext(data: nil, width: Int((size.width * scale).rounded(.up)),
                                 height: Int((size.height * scale).rounded(.up)),
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CursorSnapshot() }
        cg.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        c.image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return CursorSnapshot(image: cg.makeImage(), size: size, hotSpot: c.hotSpot)
    }

    static func current() -> CursorSnapshot { of(NSCursor.currentSystem ?? .arrow) }
}

// MARK: - Trail rendering (shared by the overlay and the menu preview)

enum Trail {
    /// Rect of the cursor image whose hot spot sits at `p` (non-flipped coordinates).
    static func rect(at p: CGPoint, _ c: CursorSnapshot) -> CGRect {
        CGRect(x: p.x - c.hotSpot.x, y: p.y - (c.size.height - c.hotSpot.y),
               width: c.size.width, height: c.size.height)
    }

    /// Draws ghost copies of the cursor along `pts` (oldest → newest).
    /// `sharpHead` adds a fully opaque cursor at the newest position.
    static func draw(in ctx: CGContext, points pts: [CGPoint], cursor c: CursorSnapshot,
                     samples: Int, strength: Double, headBias: Double, sharpHead: Bool) {
        guard let img = c.image, let head = pts.last else { return }
        func stamp(_ p: CGPoint, _ a: CGFloat) { ctx.setAlpha(a); ctx.draw(img, in: rect(at: p, c)) }

        let n = max(2, samples)
        let k = pts.count - 1
        if k >= 1 {
            let base = min(1, CGFloat(strength) * 2 / CGFloat(n))
            let bias = CGFloat(headBias)
            for j in 0..<k {
                let a = pts[j], b = pts[j + 1]
                if hypot(b.x - a.x, b.y - a.y) < 0.5 { continue }
                for i in 0..<n {                       // i/n < 1: the head is never a ghost
                    let tl = CGFloat(i) / CGFloat(n)
                    let p = CGPoint(x: a.x + (b.x - a.x) * tl, y: a.y + (b.y - a.y) * tl)
                    let tg = (CGFloat(j) + tl) / CGFloat(k)
                    stamp(p, base * ((1 - bias) + bias * tg))
                }
            }
        }
        if sharpHead { stamp(head, 1) }
        ctx.setAlpha(1)
    }
}

/// Display timing used for the latency figures shown in the menu.
enum Timing {
    static var hz: Double { Double(NSScreen.main?.maximumFramesPerSecond ?? 60) }
    static var frameMs: Double { 1000 / hz }
    static func ms(_ v: Double) -> String {
        v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }
}

// MARK: - Overlay view

final class BlurView: NSView {
    var screenOrigin: CGPoint = .zero
    private var pts: [CGPoint] = []
    private var moving = false
    private var hide = false
    private var cursor = CursorSnapshot()
    private var lastDirty: NSRect = .zero

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    /// `global`: positions from oldest to newest, in global coordinates.
    func update(points global: [CGPoint], moving: Bool, hide: Bool, cursor: CursorSnapshot) {
        pts = global.map { CGPoint(x: $0.x - screenOrigin.x, y: $0.y - screenOrigin.y) }
        self.moving = moving
        self.hide = hide
        self.cursor = cursor

        var dirty = NSRect.zero
        if moving || hide, cursor.image != nil, let head = pts.last {
            let rects = moving ? pts.map { Trail.rect(at: $0, cursor) } : [Trail.rect(at: head, cursor)]
            dirty = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
                .insetBy(dx: -2, dy: -2).intersection(bounds)
        }
        let toInvalidate = dirty.union(lastDirty)
        if !toInvalidate.isEmpty { setNeedsDisplay(toInvalidate) }
        lastDirty = dirty
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)
        guard let head = pts.last else { return }
        let s = Settings.shared
        // Without "hide real cursor" the head is the real cursor: never draw over it.
        Trail.draw(in: ctx, points: moving ? pts : [head], cursor: cursor,
                   samples: s.samples, strength: s.strength, headBias: s.headBias,
                   sharpHead: hide)
    }
}

// MARK: - Menu: slider

/// A slider drawn and tracked by hand. NSSlider inside an NSMenuItem loses its
/// mouse-up when the drag leaves the menu (e.g. dragging past the left end to
/// reach the minimum) and stays stuck in its pressed state. Here the drag is
/// tracked with a local event loop, which receives every event until release.
final class MenuSlider: NSView {
    let minValue: Double, maxValue: Double
    var value: Double { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    var onRelease: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    private let knob: CGFloat = 16

    init(min: Double, max: Double, value: Double) {
        minValue = min; maxValue = max; self.value = value
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var fraction: CGFloat { CGFloat((value - minValue) / (maxValue - minValue)) }
    private var trackRect: NSRect { bounds.insetBy(dx: knob / 2, dy: 0) }

    override func draw(_ dirtyRect: NSRect) {
        let r = trackRect
        let midY = bounds.midY
        let x = r.minX + r.width * fraction
        let track = NSBezierPath(roundedRect: NSRect(x: r.minX, y: midY - 2, width: r.width, height: 4),
                                 xRadius: 2, yRadius: 2)
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        track.fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: midY - 2, width: max(4, x - r.minX), height: 4),
                     xRadius: 2, yRadius: 2).fill()

        let d = pressed ? knob + 2 : knob
        let k = NSRect(x: x - d / 2, y: midY - d / 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: k).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let ring = NSBezierPath(ovalIn: k.insetBy(dx: 0.25, dy: 0.25))
        ring.lineWidth = 0.5
        ring.stroke()
    }

    private func set(fromX x: CGFloat) {
        let r = trackRect
        let f = Double(min(1, max(0, (x - r.minX) / r.width)))
        let v = minValue + f * (maxValue - minValue)
        if v != value { value = v; onChange?(v) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        set(fromX: convert(event.locationInWindow, from: nil).x)
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            set(fromX: convert(e.locationInWindow, from: nil).x)
            if e.type == .leftMouseUp { break }
        }
        pressed = false
        onRelease?()
    }

    override func scrollWheel(with event: NSEvent) {
        let step = (maxValue - minValue) / 100
        let v = min(maxValue, max(minValue, value + Double(event.scrollingDeltaY - event.scrollingDeltaX) * step * 0.5))
        if v != value { value = v; onChange?(v) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { value }
    override func accessibilityMinValue() -> Any? { minValue }
    override func accessibilityMaxValue() -> Any? { maxValue }
    override func accessibilityPerformIncrement() -> Bool { nudge(+1) }
    override func accessibilityPerformDecrement() -> Bool { nudge(-1) }
    private func nudge(_ dir: Double) -> Bool {
        value = min(maxValue, max(minValue, value + dir * (maxValue - minValue) / 20))
        onChange?(value); onRelease?(); return true
    }
}

// MARK: - Menu: per-control illustration

/// Tiny monochrome diagram of what a control does, redrawn as its value changes.
final class IllustrationView: NSView {
    enum Kind { case strength, trail, samples, bias, threshold }
    let kind: Kind
    var value: Double = 0 { didSet { needsDisplay = true } }

    init(kind: Kind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    /// Arrow cursor outline with its tip at (0, 0), pointing up-left.
    private func arrow(at tip: CGPoint, scale k: CGFloat) -> NSBezierPath {
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -17), (4, -13), (7, -20), (9.5, -19), (6.5, -12.2), (12, -12.2)]
        let p = NSBezierPath()
        for (i, (x, y)) in pts.enumerated() {
            let pt = NSPoint(x: tip.x + x * k, y: tip.y + y * k)
            i == 0 ? p.move(to: pt) : p.line(to: pt)
        }
        p.close()
        p.lineJoinStyle = .round
        return p
    }

    private func ghosts(head: CGPoint, length: CGFloat, count: Int, alpha: (CGFloat) -> CGFloat) {
        let n = max(1, count)
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n)            // 0 = tail
            let p = CGPoint(x: head.x - length * (1 - t), y: head.y)
            NSColor.labelColor.withAlphaComponent(min(1, alpha(t))).setFill()
            arrow(at: p, scale: 0.72).fill()
        }
    }

    private func headArrow(_ head: CGPoint) {
        let a = arrow(at: head, scale: 0.72)
        NSColor.labelColor.setFill()
        a.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        bg.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setStroke()
        bg.lineWidth = 0.5
        bg.stroke()

        let accent = NSColor.controlAccentColor
        let head = CGPoint(x: bounds.maxX - 14, y: bounds.midY + 9)
        let v = CGFloat(value)

        switch kind {
        case .strength:                                  // 0.2 … 2.0 → ghost opacity
            ghosts(head: head, length: 22, count: 9) { t in min(1, v / 2) * 0.55 * (0.35 + 0.65 * t) }
            headArrow(head)
        case .trail:                                     // 1 … 6 frames → trail length
            let len = 4 + (v - 1) / 5 * 22
            ghosts(head: head, length: len, count: 9) { t in 0.38 * (0.35 + 0.65 * t) }
            headArrow(head)
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: head.x - len, y: bounds.minY + 6, width: max(2, len), height: 2.5),
                         xRadius: 1.25, yRadius: 1.25).fill()
        case .samples:                                   // 4 … 48 copies
            let n = Int(v.rounded())
            ghosts(head: head, length: 22, count: n) { _ in min(0.5, 3.2 / CGFloat(n)) + 0.06 }
            headArrow(head)
        case .bias:                                      // 0 … 1: fade toward the tail
            ghosts(head: head, length: 22, count: 10) { t in 0.5 * ((1 - v) + v * t) }
            headArrow(head)
            let bar = NSRect(x: head.x - 22, y: bounds.minY + 6, width: 24, height: 2.5)
            NSGradient(starting: accent.withAlphaComponent(1 - 0.92 * v), ending: accent)?
                .draw(in: NSBezierPath(roundedRect: bar, xRadius: 1.25, yRadius: 1.25), angle: 0)
        case .threshold:                                 // 0 … 10 pt dead zone
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            let r = 2 + v * 1.25
            let zone = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            accent.withAlphaComponent(0.14).setFill()
            zone.fill()
            accent.setStroke()
            zone.lineWidth = 1
            zone.setLineDash([2, 2], count: 2, phase: 0)
            zone.stroke()
            let a = arrow(at: c, scale: 0.6)
            NSColor.labelColor.setFill()
            a.fill()
        }
    }
}

// MARK: - Menu: rows

private func captionText(latency: String, ok: Bool, _ text: String) -> NSAttributedString {
    let s = NSMutableAttributedString(string: latency, attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: ok ? NSColor.systemGreen : NSColor.systemOrange,
    ])
    s.append(NSAttributedString(string: "  " + text, attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]))
    return s
}

let menuWidth: CGFloat = 316

/// One setting: illustration, title, value, slider and a caption with its latency.
final class SliderRow: NSView {
    private let illus: IllustrationView
    private let slider: MenuSlider
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let format: (Double) -> String
    private let captionFor: (Double) -> NSAttributedString
    private let getter: () -> Double
    private let setter: (Double) -> Void
    var onRelease: (() -> Void)? { didSet { slider.onRelease = onRelease } }
    var onChange: (() -> Void)?

    override var isFlipped: Bool { true }

    init(title: String, kind: IllustrationView.Kind, min: Double, max: Double,
         format: @escaping (Double) -> String,
         caption: @escaping (Double) -> NSAttributedString,
         get: @escaping () -> Double, set: @escaping (Double) -> Void) {
        illus = IllustrationView(kind: kind)
        slider = MenuSlider(min: min, max: max, value: get())
        self.format = format; captionFor = caption; getter = get; setter = set
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 84))

        let left: CGFloat = 16, textX: CGFloat = 70, right = menuWidth - 16
        illus.frame = NSRect(x: left, y: 8, width: 44, height: 40)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.stringValue = title
        titleLabel.frame = NSRect(x: textX, y: 8, width: 170, height: 17)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: right - 70, y: 9, width: 70, height: 16)
        slider.frame = NSRect(x: textX - 2, y: 28, width: right - textX + 4, height: 20)
        self.caption.frame = NSRect(x: left, y: 52, width: right - left, height: 28)
        self.caption.maximumNumberOfLines = 2
        [illus, titleLabel, valueLabel, slider, self.caption].forEach(addSubview)

        slider.onChange = { [weak self] v in
            guard let self else { return }
            self.setter(v)
            self.refresh()
            self.onChange?()
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload() { slider.value = getter(); refresh() }

    func refresh() {
        let v = slider.value
        valueLabel.stringValue = format(v)
        illus.value = v
        caption.attributedStringValue = captionFor(v)
    }
}

/// Live preview of the current settings, animated only while the menu is open.
final class PreviewRow: NSView {
    private var timer: Timer?
    private var history: [CGPoint] = []
    private let cursor = CursorSnapshot.of(.arrow)
    private let info = NSTextField(labelWithString: "")
    private var simTime: CFTimeInterval = 0
    override var isFlipped: Bool { false }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 70))
        info.font = .systemFont(ofSize: 10, weight: .medium)
        info.textColor = .tertiaryLabelColor
        info.alignment = .right
        info.frame = NSRect(x: menuWidth - 16 - 180, y: 48, width: 172, height: 13)
        info.stringValue = PreviewRow.rateText
        let label = NSTextField(labelWithString: "PREVIEW")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: 26, y: 48, width: 120, height: 13)
        addSubview(label); addSubview(info)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var area: NSRect { NSRect(x: 16, y: 4, width: menuWidth - 32, height: 64) }
    static var rateText: String { "\(Int(Timing.hz)) Hz · \(Timing.ms(Timing.frameMs)) ms per frame" }

    func start() {
        info.stringValue = PreviewRow.rateText
        stop()
        let t = Timer(timeInterval: 1 / Timing.hz, repeats: true) { [weak self] _ in
            self?.step(CACurrentMediaTime())
        }
        RunLoop.main.add(t, forMode: .common)        // keeps running during menu tracking
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Cursor x position: quick eased flicks back and forth with pauses, like real use.
    private func position(_ t: CFTimeInterval) -> CGPoint {
        let a = area
        let x0 = a.minX + 30, x1 = a.maxX - 30
        let move = 0.24, hold = 0.5, period = 2 * (move + hold)
        let ph = t.truncatingRemainder(dividingBy: period)
        func ease(_ u: Double) -> Double { 0.5 - 0.5 * cos(.pi * min(1, max(0, u))) }
        let u: Double
        if ph < move { u = ease(ph / move) }
        else if ph < move + hold { u = 1 }
        else if ph < 2 * move + hold { u = 1 - ease((ph - move - hold) / move) }
        else { u = 0 }
        return CGPoint(x: x0 + (x1 - x0) * u, y: a.midY + cursor.size.height / 2 - 12)
    }

    func step(_ t: CFTimeInterval) {
        simTime = t
        let s = Settings.shared
        history.append(position(t))
        let maxCount = max(1, s.frames) + 1
        if history.count > maxCount { history.removeFirst(history.count - maxCount) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: area, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        bg.fill()
        NSColor.labelColor.withAlphaComponent(0.09).setStroke()
        bg.lineWidth = 0.5
        bg.stroke()
        guard let ctx = NSGraphicsContext.current?.cgContext, let head = history.last else { return }
        let s = Settings.shared
        var length: CGFloat = 0
        for (a, b) in zip(history, history.dropFirst()) { length += hypot(b.x - a.x, b.y - a.y) }
        let moving = s.enabled && length >= CGFloat(s.minDistance)
        ctx.saveGState()
        ctx.clip(to: area.insetBy(dx: 1, dy: 1))
        Trail.draw(in: ctx, points: moving ? history : [head], cursor: cursor,
                   samples: s.samples, strength: s.strength, headBias: s.headBias, sharpHead: true)
        ctx.restoreGState()
    }
}

/// Headline: how much latency the current settings add to the pointer.
final class LatencyRow: NSView {
    private let title = NSTextField(labelWithString: "Pointer latency")
    private let value = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 54))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 16, y: 4, width: 180, height: 17)
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        value.alignment = .right
        value.frame = NSRect(x: menuWidth - 16 - 120, y: 4, width: 120, height: 17)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.frame = NSRect(x: 16, y: 23, width: menuWidth - 32, height: 28)
        [title, value, detail].forEach(addSubview)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let s = Settings.shared
        let f = Timing.frameMs
        if s.enabled && s.hideCursor {
            value.stringValue = "+\(Timing.ms(f))–\(Timing.ms(2 * f)) ms"
            value.textColor = .systemOrange
            detail.stringValue = "The visible cursor is redrawn by cursorblur, 1–2 frames behind the hardware cursor."
        } else {
            value.stringValue = "+0 ms"
            value.textColor = .systemGreen
            detail.stringValue = "macOS draws the real cursor; the trail is painted behind it."
        }
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
    private var sliders: [SliderRow] = []
    private let preview = PreviewRow()
    private let latencyRow = LatencyRow()
    private var enabledItem: NSMenuItem!
    private var hideItem: NSMenuItem!
    private var hideCount = 0   // CGDisplayHideCursor è a conteggio: teniamo traccia delle chiamate
    private var signalSources: [DispatchSourceSignal] = []
    private var cursor = CursorSnapshot.current()
    private var tickCount = 0
    private var activity: NSObjectProtocol?
    private let debug = ProcessInfo.processInfo.environment["CURSORBLUR_DEBUG"] != nil
    private var debugFrames = 0
    private var debugStart = CACurrentMediaTime()

    func start() {
        // Keep the display link at full rate: without this, App Nap throttles the
        // (background, menu-bar-only) app and the trail stutters or lingers.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Real-time cursor rendering")
        setupMenu()
        if let path = ProcessInfo.processInfo.environment["CURSORBLUR_RENDER_MENU"] {
            renderMenu(to: path); exit(0)
        }
        buildWindows()
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
        tickCount &+= 1
        if debug {
            debugFrames += 1
            let now = CACurrentMediaTime()
            if now - debugStart >= 1 {
                NSLog("cursorblur: %d fps", debugFrames)
                debugFrames = 0; debugStart = now
            }
        }
        // The drawn cursor *is* the cursor in hide mode: refresh its shape every frame.
        if hide || tickCount % 3 == 0 { cursor = CursorSnapshot.current() }
        if hide && tickCount % 15 == 0 { reassertIfShown() }
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
        reassertIfShown()
    }

    /// If the system reset the hide count and the real cursor is visible again,
    /// start counting from zero and hide it once more.
    private func reassertIfShown() {
        guard systemCursorIsVisible() != 0 else { return }
        hideCount = 0
        hideNow()
    }

    func menuWillOpen(_ menu: NSMenu) {
        latencyRow.refresh()
        sliders.forEach { $0.refresh() }
        preview.start()
    }

    func menuDidClose(_ menu: NSMenu) {
        preview.stop()
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
        if #available(macOS 14.4, *) {
            hideItem.subtitle = "Show only the drawn cursor · adds 1–2 frames"
        }
        menu.addItem(hideItem)

        menu.addItem(.separator())
        menu.addItem(viewItem(preview))
        menu.addItem(viewItem(latencyRow))
        menu.addItem(.separator())

        sliders = makeSliderRows()
        for v in sliders {
            v.onRelease = { [weak self] in self?.reassertHidden() }
            menu.addItem(viewItem(v))
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

    private func makeSliderRows() -> [SliderRow] {
        let s = Settings.shared
        let ok = "0 ms"
        let int: (Double) -> String = { "\(Int($0.rounded()))" }
        return [
            SliderRow(title: "Strength", kind: .strength, min: 0.2, max: 2.0,
                      format: { String(format: "%.2f", $0) },
                      caption: { _ in captionText(latency: ok, ok: true, "Opacity of the trail: higher makes fast flicks easier to see.") },
                      get: { s.strength }, set: { s.strength = $0 }),
            SliderRow(title: "Trail length", kind: .trail, min: 1, max: 6,
                      format: { "\(Int($0.rounded())) fr" },
                      caption: { v in
                          let n = Int(v.rounded())
                          return captionText(latency: ok, ok: true,
                              "Smears the last \(n) frame\(n == 1 ? "" : "s") (\(Timing.ms(Double(n) * Timing.frameMs)) ms) of motion. The pointer isn't delayed.")
                      },
                      get: { Double(s.frames) }, set: { s.frames = Int($0.rounded()) }),
            SliderRow(title: "Samples", kind: .samples, min: 4, max: 48, format: int,
                      caption: { _ in captionText(latency: ok, ok: true, "Copies drawn per frame: smoother trail, more GPU work.") },
                      get: { Double(s.samples) }, set: { s.samples = Int($0.rounded()) }),
            SliderRow(title: "Head bias", kind: .bias, min: 0, max: 1,
                      format: { "\(Int(($0 * 100).rounded()))%" },
                      caption: { _ in captionText(latency: ok, ok: true, "Fades the trail toward its tail. 0% keeps it uniform.") },
                      get: { s.headBias }, set: { s.headBias = $0 }),
            SliderRow(title: "Movement threshold", kind: .threshold, min: 0, max: 10,
                      format: { String(format: "%.1f pt", $0) },
                      caption: { _ in captionText(latency: ok, ok: true, "Smaller movements draw no trail, so the cursor stays crisp when still.") },
                      get: { s.minDistance }, set: { s.minDistance = $0 }),
        ]
    }

    private func viewItem(_ v: NSView) -> NSMenuItem {
        let mi = NSMenuItem()
        mi.view = v
        return mi
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
        latencyRow.refresh()
        applyCursorVisibility()
    }

    @objc private func toggleHide() {
        let s = Settings.shared
        s.hideCursor.toggle()
        hideItem.state = s.hideCursor ? .on : .off
        latencyRow.refresh()
        applyCursorVisibility()
    }

    @objc private func resetDefaults() {
        Settings.shared.reset()
        sliders.forEach { $0.reload() }
        hideItem.state = .off
        latencyRow.refresh()
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

    /// Debug aid: renders the custom menu rows to a PNG (dark appearance).
    private func renderMenu(to path: String) {
        let pv = PreviewRow()
        let rows: [NSView] = [pv, LatencyRow()] + makeSliderRows()
        let height = rows.reduce(0) { $0 + $1.frame.height } + 16
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))
        container.appearance = NSAppearance(named: .darkAqua)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        var y = height - 8
        for r in rows { y -= r.frame.height; r.setFrameOrigin(NSPoint(x: 0, y: y)); container.addSubview(r) }
        for i in 0..<14 { pv.step(0.02 + Double(i) / Timing.hz) }   // mid-flick
        let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
        container.cacheDisplay(in: container.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
