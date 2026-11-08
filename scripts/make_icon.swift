// Generates packaging/AppIcon.icns: a dark rounded square with an arrow cursor
// and a fading motion-blur trail. Run via build.sh (needs only Xcode CLT).
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging/AppIcon.icns"
let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "cursorblur.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func arrowPath(scale k: CGFloat) -> NSBezierPath {
    // Classic arrow cursor, tip at origin, pointing up-left (y grows up).
    let pts: [(CGFloat, CGFloat)] = [
        (0, 0), (0, -17), (4, -13), (7, -20), (9.5, -19), (6.5, -12.2), (12, -12.2),
    ]
    let p = NSBezierPath()
    for (i, (x, y)) in pts.enumerated() {
        let pt = NSPoint(x: x * k, y: y * k)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    p.lineJoinStyle = .round
    return p
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Background: macOS-style rounded square with a margin.
    let inset = s * 0.1, side = s - inset * 2
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side),
                          xRadius: side * 0.225, yRadius: side * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.32, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.13, alpha: 1)])!
        .draw(in: bg, angle: -90)

    // Trail: copies of the arrow from bottom-left toward the head, fading in.
    let k = side / 34
    let head = NSPoint(x: s * 0.56, y: s * 0.72)
    let delta = NSPoint(x: -side * 0.30, y: -side * 0.24)
    let n = 22
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)          // 0 = oldest, 1 = head
        let a = i == n ? 1.0 : 0.03 + 0.14 * t * t
        NSGraphicsContext.saveGraphicsState()
        let xf = NSAffineTransform()
        xf.translateX(by: head.x + delta.x * (1 - t), yBy: head.y + delta.y * (1 - t))
        xf.concat()
        let p = arrowPath(scale: k)
        NSColor.white.withAlphaComponent(a).setFill()
        p.fill()
        if i == n {
            NSColor.black.setStroke()
            p.lineWidth = k * 1.1
            p.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for mult in [1, 2] {
        let name = mult == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * mult).write(to: URL(fileURLWithPath: iconset + "/" + name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", out]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(atPath: iconset)
print(task.terminationStatus == 0 ? "Icon → \(out)" : "iconutil failed")
exit(task.terminationStatus)
