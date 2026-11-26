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
        "samples": 11,        // density: one copy every 16/11 ≈ 1.5 pt of travel
        "strength": 0.99,     // overall trail opacity
        "headBias": 0.56,     // 0 = uniform trail, 1 = fades toward the tail
        "minDistance": 10.0,  // movement (pt) below which no trail is drawn
        "frames": 2,          // past frames covered by the trail ("shutter")
        "hideCursor": true,   // show only the motion-blurred cursor
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
        let f = Settings.factory
        samples = f["samples"] as! Int; strength = f["strength"] as! Double
        headBias = f["headBias"] as! Double; minDistance = f["minDistance"] as! Double
        frames = f["frames"] as! Int; hideCursor = f["hideCursor"] as! Bool
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

    /// Rendering variant, switchable only for the comparison render (CURSORBLUR_RENDER_TRAILS).
    /// `.fixed` = v0.1.0, `.adaptive` = v0.1.1 (straight segments), `.spline` = current.
    enum Mode { case fixed, adaptive, spline }
    static var mode: Mode = .spline

    // MARK: Curved path

    /// Turns a few samples into a dense curve with a centripetal Catmull-Rom spline,
    /// which passes through every sample without loops or overshoot on sharp turns.
    /// The end tangents are extrapolated from the samples themselves (quadratic), so
    /// the segment leading to the head bends like the path before it without waiting
    /// for a future sample: no added latency.
    static func smooth(_ raw: [CGPoint], step: CGFloat = 1.5) -> [CGPoint] {
        var q: [CGPoint] = []
        for p in raw where q.last.map({ hypot(p.x - $0.x, p.y - $0.y) >= 0.25 }) ?? true { q.append(p) }
        if let last = raw.last, let ql = q.last, ql != last { q[q.count - 1] = last }   // keep the exact head
        guard q.count >= 3 else { return q }

        func lerp(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat, _ t: CGFloat) -> CGPoint {
            let d = tb - ta
            guard d > 1e-6 else { return a }
            return CGPoint(x: a.x * (tb - t) / d + b.x * (t - ta) / d, y: a.y * (tb - t) / d + b.y * (t - ta) / d)
        }
        func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(1e-3, sqrt(hypot(b.x - a.x, b.y - a.y))) }

        var out = [q[0]]
        let n = q.count
        for i in 0..<(n - 1) {
            let p1 = q[i], p2 = q[i + 1]
            // Phantom neighbours past the ends: quadratic extrapolation keeps the curvature.
            let p0 = i > 0 ? q[i - 1]
                : CGPoint(x: 3 * p1.x - 3 * p2.x + q[2].x, y: 3 * p1.y - 3 * p2.y + q[2].y)
            let p3 = i + 2 < n ? q[i + 2]
                : CGPoint(x: 3 * p2.x - 3 * p1.x + q[i - 1].x, y: 3 * p2.y - 3 * p1.y + q[i - 1].y)
            let t0: CGFloat = 0, t1 = t0 + knot(p0, p1), t2 = t1 + knot(p1, p2), t3 = t2 + knot(p2, p3)
            let m = min(32, max(1, Int((hypot(p2.x - p1.x, p2.y - p1.y) / step).rounded(.up))))
            for j in 1...m {
                let t = t1 + (t2 - t1) * CGFloat(j) / CGFloat(m)
                let a1 = lerp(p0, p1, t0, t1, t), a2 = lerp(p1, p2, t1, t2, t), a3 = lerp(p2, p3, t2, t3, t)
                let b1 = lerp(a1, a2, t0, t2, t), b2 = lerp(a2, a3, t1, t3, t)
                out.append(j == m ? p2 : lerp(b1, b2, t1, t2, t))
            }
        }
        return out
    }

    /// Ghost copies evenly spaced by arc length along a dense path (oldest → newest).
    /// `frames`: how many display frames the path spans, so opacity per frame of motion
    /// matches the straight-segment renderer.
    private static func drawPath(in ctx: CGContext, path: [CGPoint], frames: Int, cursor c: CursorSnapshot,
                                 samples: Int, strength: Double, headBias: Double, includeHead: Bool,
                                 minDistance: Double, stamp: (CGPoint, CGFloat) -> Void) {
        guard let head = path.last else { return }
        var cum: [CGFloat] = [0]
        for (a, b) in zip(path, path.dropFirst()) { cum.append(cum.last! + hypot(b.x - a.x, b.y - a.y)) }
        let total = cum.last!
        let lo = CGFloat(minDistance), hi = lo + 16
        let u = min(1, max(0, (total - lo) / (hi - lo)))
        let fade = u * u * (3 - 2 * u)
        guard total >= 0.5, fade > 0 else { if includeHead { stamp(head, 1) }; return }

        let maxN = max(2, samples)
        let perFrame = CGFloat(max(1, frames))
        let count = min(maxCopies * max(1, frames), max(2, Int((total / spacing(density: samples)).rounded(.up))))
        let alphaN = min(CGFloat(count), 2 * CGFloat(maxN) * perFrame)
        let base = min(1, CGFloat(strength) * 2 * perFrame / alphaN) * fade
        let bias = CGFloat(headBias)
        var seg = 0
        for i in 0..<(includeHead ? count + 1 : count) {
            let f = CGFloat(i) / CGFloat(count)
            let d = f * total
            while seg < path.count - 2 && cum[seg + 1] < d { seg += 1 }
            let span = cum[seg + 1] - cum[seg]
            let k = span > 0 ? (d - cum[seg]) / span : 0
            let a = path[seg], b = path[seg + 1]
            stamp(CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k), base * ((1 - bias) + bias * f))
        }
        if includeHead && fade < 1 { stamp(head, 1 - fade) }
    }
    /// Hard cap on copies per frame segment, to bound GPU work on extreme flicks.
    static let maxCopies = 128

    /// Distance between ghost copies (pt) for a given Density setting (4…48).
    /// Copies stay evenly spaced, so fast flicks get more of them (no comb effect)
    /// and slow moves fewer (no muddy pile-up).
    static func spacing(density: Int) -> CGFloat { 16 / CGFloat(max(1, density)) }

    /// Draws ghost copies of the cursor along `pts` (oldest → newest).
    /// `includeHead`: the drawn cursor stands in for the (hidden) real one. While it
    /// moves, the head dissolves into the blur like a real motion-blurred object;
    /// once it stops, it is drawn sharp. Without it, the real cursor is the head.
    /// `minDistance`: path length at which the trail starts; it fades in above it.
    static func draw(in ctx: CGContext, points pts: [CGPoint], cursor c: CursorSnapshot,
                     samples: Int, strength: Double, headBias: Double, includeHead: Bool,
                     minDistance: Double = 0, frames: Int? = nil) {
        guard let img = c.image, let head = pts.last else { return }
        func stamp(_ p: CGPoint, _ a: CGFloat) { ctx.setAlpha(a); ctx.draw(img, in: rect(at: p, c)) }
        if mode == .spline {
            // `pts` is already a dense path (see `smooth`).
            drawPath(in: ctx, path: pts, frames: frames ?? max(1, pts.count - 1), cursor: c,
                     samples: samples, strength: strength, headBias: headBias, includeHead: includeHead,
                     minDistance: minDistance, stamp: stamp)
            ctx.setAlpha(1)
            return
        }

        let maxN = max(2, samples)
        let gap = spacing(density: samples)
        let k = pts.count - 1
        var lastSegmentDrawn = false
        // Fade the trail in over a range above the threshold instead of switching it on.
        var fade: CGFloat = 1
        if mode == .adaptive && k >= 1 {
            var total: CGFloat = 0
            for j in 0..<k { total += hypot(pts[j + 1].x - pts[j].x, pts[j + 1].y - pts[j].y) }
            let lo = CGFloat(minDistance), hi = lo + 16
            let u = min(1, max(0, (total - lo) / (hi - lo)))
            fade = u * u * (3 - 2 * u)                       // smoothstep
        }
        if k >= 1 && fade > 0 {
            let bias = CGFloat(headBias)
            for j in 0..<k {
                let a = pts[j], b = pts[j + 1]
                let len = hypot(b.x - a.x, b.y - a.y)
                if len < 0.5 { continue }
                let isLast = j == k - 1
                if isLast { lastSegmentDrawn = true }
                let n = mode == .fixed ? maxN : min(maxCopies, max(2, Int((len / gap).rounded(.up))))
                // Long, fast segments spread the same opacity over more copies; cap the
                // dilution so quick flicks stay as visible as in fixed mode.
                let alphaN = mode == .fixed ? n : min(n, 2 * maxN)
                let base = min(1, CGFloat(strength) * 2 / CGFloat(alphaN)) * fade
                let count = isLast && includeHead ? n + 1 : n   // i == n is the head itself
                for i in 0..<count {
                    let tl = CGFloat(i) / CGFloat(n)
                    let p = CGPoint(x: a.x + (b.x - a.x) * tl, y: a.y + (b.y - a.y) * tl)
                    let tg = (CGFloat(j) + tl) / CGFloat(k)
                    stamp(p, base * ((1 - bias) + bias * tg))
                }
            }
        }
        if includeHead && !lastSegmentDrawn { stamp(head, 1) }
        else if includeHead && fade < 1 { stamp(head, 1 - fade) }   // still mostly sharp
        ctx.setAlpha(1)
    }
}

/// Builds the shutter path from the per-frame pointer samples (`NSEvent.mouseLocation`
/// read every display tick), which are always where the pointer really was.
///
/// v0.1.2 also merged mouse/trackpad events between frames. That was dropped: macOS can
/// hold events back and deliver them in a burst with stale positions (e.g. during the
/// minimize animation, which stretched the trail back to the window button), their
/// timestamps don't line up exactly with frame samples, and on most hardware they
/// arrive less often than display frames anyway. The spline does the smoothing.
enum PathSampler {
    struct Sample { var p: CGPoint; var t: TimeInterval }

    /// Samples inside [start, now], preceded by the position exactly at `start`.
    /// Bounded by time, not by count: if ticks stall, the trail cannot reach back
    /// to where the pointer was before the stall.
    static func path(_ all: [Sample], start: TimeInterval, now: TimeInterval) -> [CGPoint] {
        guard let last = all.last else { return [] }
        var out: [CGPoint] = []
        if let i = all.lastIndex(where: { $0.t < start }), i + 1 < all.count {
            let a = all[i], b = all[i + 1]
            let k = CGFloat((start - a.t) / max(1e-6, b.t - a.t))
            out.append(CGPoint(x: a.p.x + (b.p.x - a.p.x) * k, y: a.p.y + (b.p.y - a.p.y) * k))
        }
        out += all.filter { $0.t >= start && $0.t <= now }.map(\.p)
        if out.last != last.p { out.append(last.p) }
        return out
    }

    /// Checks used by `CURSORBLUR_SELFTEST`.
    static func selfTest() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print(cond ? "PASS" : "FAIL", name); ok = ok && cond }
        func length(_ p: [CGPoint]) -> CGFloat { zip(p, p.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
        let dt = 1.0 / 120
        // Cursor moving right 10 pt per frame; trail of 2 frames.
        let samples = (0...4).map { Sample(p: CGPoint(x: 500 + 10 * CGFloat($0), y: 300), t: Double($0) * dt) }
        let now = 4 * dt
        check("trail spans exactly 2 frames (20 pt)", abs(length(path(samples, start: now - 2 * dt, now: now)) - 20) < 0.5)
        // Ticks stalled for 0.4 s (e.g. during a system animation) while the pointer moved far.
        let stalled = [Sample(p: CGPoint(x: 20, y: 900), t: 0), Sample(p: CGPoint(x: 800, y: 300), t: 0.4)]
        check("after a stall the trail does not reach back to the old position",
              length(path(stalled, start: 0.4 - 2 * dt, now: 0.4)) < 70)
        return ok
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
    private var frames = 1

    func update(points global: [CGPoint], frames: Int, moving: Bool, hide: Bool, cursor: CursorSnapshot) {
        pts = global.map { CGPoint(x: $0.x - screenOrigin.x, y: $0.y - screenOrigin.y) }
        self.frames = frames
        self.moving = moving
        self.hide = hide
        self.cursor = cursor

        var dirty = NSRect.zero
        if moving || hide, cursor.image != nil, let head = pts.last {
            let span = moving ? pts : [head]
            let lo = CGPoint(x: span.map(\.x).min()!, y: span.map(\.y).min()!)
            let hi = CGPoint(x: span.map(\.x).max()!, y: span.map(\.y).max()!)
            dirty = Trail.rect(at: lo, cursor).union(Trail.rect(at: hi, cursor))
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
                   includeHead: hide, minDistance: s.minDistance, frames: frames)
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
        let hide = s.enabled && s.hideCursor
        Trail.draw(in: ctx, points: moving ? Trail.smooth(history) : [head], cursor: cursor,
                   samples: s.samples, strength: s.strength, headBias: s.headBias, includeHead: hide,
                   minDistance: s.minDistance, frames: max(1, s.frames))
        if !hide {                                   // stand-in for the real, sharp cursor
            Trail.draw(in: ctx, points: [head], cursor: cursor,
                       samples: s.samples, strength: s.strength, headBias: s.headBias, includeHead: true)
        }
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
    /// Timestamped pointer positions (system uptime), one per display frame, oldest first.
    private var samples: [PathSampler.Sample] = []
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
        if ProcessInfo.processInfo.environment["CURSORBLUR_SELFTEST"] != nil {
            exit(PathSampler.selfTest() ? 0 : 1)
        }
        if let path = ProcessInfo.processInfo.environment["CURSORBLUR_RENDER_TRAILS"] {
            renderTrailComparison(to: path); exit(0)
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

    /// The path covered during the "shutter" (the last `frames` display frames), oldest
    /// first, ending exactly at the current pointer position.
    private func shutterPath(frames: Int, head: CGPoint) -> [CGPoint] {
        let now = ProcessInfo.processInfo.systemUptime
        samples.append(.init(p: head, t: now))
        if let cut = samples.firstIndex(where: { $0.t >= now - 0.25 }), cut > 0 { samples.removeFirst(cut) }
        let path = PathSampler.path(samples, start: now - Double(frames) / Timing.hz, now: now)
        return path.isEmpty ? [head] : path
    }

    @objc private func tick(_ link: CADisplayLink) {
        let s = Settings.shared
        let head = NSEvent.mouseLocation

        let samples = shutterPath(frames: max(1, s.frames), head: head)
        var length: CGFloat = 0
        for (a, b) in zip(samples, samples.dropFirst()) { length += hypot(b.x - a.x, b.y - a.y) }
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
        let path = moving ? Trail.smooth(samples) : samples
        for v in views { v.update(points: path, frames: max(1, s.frames), moving: moving, hide: hide, cursor: cursor) }
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
            SliderRow(title: "Density", kind: .samples, min: 4, max: 48, format: int,
                      caption: { v in captionText(latency: ok, ok: true,
                          "A copy every \(String(format: "%.1f", Trail.spacing(density: Int(v.rounded())))) pt: fast moves get more copies, slow ones fewer.") },
                      get: { Double(s.samples) }, set: { s.samples = Int($0.rounded()) }),
            SliderRow(title: "Head bias", kind: .bias, min: 0, max: 1,
                      format: { "\(Int(($0 * 100).rounded()))%" },
                      caption: { _ in captionText(latency: ok, ok: true, "Fades the trail toward its tail. 0% keeps it uniform.") },
                      get: { s.headBias }, set: { s.headBias = $0 }),
            SliderRow(title: "Movement threshold", kind: .threshold, min: 0, max: 10,
                      format: { String(format: "%.1f pt", $0) },
                      caption: { _ in captionText(latency: ok, ok: true, "Below this the cursor stays crisp; above it the trail fades in.") },
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
        preview.needsDisplay = true
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
        hideItem.state = Settings.shared.hideCursor ? .on : .off
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

    /// Debug aid: fast circles as a one-turn long exposure. v0.1.1 joins one sample per
    /// frame with straight lines; the current renderer draws a spline through them.
    private func renderTrailComparison(to path: String) {
        let s = Settings.shared
        let cases: [(turns: Double, frames: Int)] = [(3, s.frames), (6, s.frames), (6, 4)]
        let cols = ["v0.1.1: straight segments", "v0.1.3: spline, same samples"]
        let scale: CGFloat = 2, cell: CGFloat = 230, labelW: CGFloat = 100, header: CGFloat = 34
        let W = Int((labelW + cell * 2) * scale), H = Int((cell * CGFloat(cases.count) + header) * scale)
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.25, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor(white: 1, alpha: 0.7)]
        let top = cell * CGFloat(cases.count) + header
        for (i, c) in cols.enumerated() {
            NSAttributedString(string: c, attributes: attrs).draw(at: NSPoint(x: labelW + cell * CGFloat(i) + 12, y: top - 22))
        }
        let cursor = CursorSnapshot.of(.arrow)
        let hz = Timing.hz, r: CGFloat = 70
        for (row, cs) in cases.enumerated() {
            let cy = top - header - cell * CGFloat(row) - cell / 2
            let speed = Int((2 * .pi * Double(r) * cs.turns).rounded())
            NSAttributedString(string: "\(Int(cs.turns)) turns/s\n\(speed) pt/s\ntrail \(cs.frames) fr", attributes: attrs)
                .draw(at: NSPoint(x: 10, y: cy - 22))
            let omega = 2 * .pi * cs.turns
            let perTurn = Int((hz / cs.turns).rounded())         // frames in one turn
            for col in 0..<2 {
                let cx = labelW + cell * CGFloat(col) + cell / 2
                func pos(_ a: Double) -> CGPoint { CGPoint(x: cx + r * CGFloat(cos(a)), y: cy + r * CGFloat(sin(a))) }
                // the true path, faint
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(1)
                ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)); ctx.strokePath()
                // Long exposure: every frame of one turn, as the eye integrates them.
                for f in 0..<perTurn {
                    let theta = omega * Double(f) / hz
                    let frameSamples = (0...cs.frames).map { pos(theta - omega * Double(cs.frames - $0) / hz) }
                    let pts: [CGPoint]
                    switch col {
                    case 0: Trail.mode = .adaptive; pts = frameSamples
                    default: Trail.mode = .spline; pts = Trail.smooth(frameSamples)
                    }
                    ctx.saveGState()
                    ctx.setAlpha(0.55)
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                    Trail.draw(in: ctx, points: pts, cursor: cursor, samples: s.samples, strength: s.strength,
                               headBias: s.headBias, includeHead: true, minDistance: s.minDistance, frames: cs.frames)
                    ctx.endTransparencyLayer()
                    ctx.restoreGState()
                }
            }
        }
        Trail.mode = .spline
        NSGraphicsContext.restoreGraphicsState()
        try? NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
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
