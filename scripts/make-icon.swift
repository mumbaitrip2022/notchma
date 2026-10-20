// Renders Resources/AppIcon.icns: a black squircle with Claude's orange spark.
import AppKit

let out = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NotchBar.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.13, alpha: 1), NSColor(white: 0.02, alpha: 1)])!.draw(in: squircle, angle: -90)
    // notch at the top
    let nw = body.width * 0.46, nh = body.height * 0.12
    let notch = NSBezierPath(roundedRect: NSRect(x: body.midX - nw / 2, y: body.maxY - nh, width: nw, height: nh * 1.6),
                             xRadius: nh * 0.6, yRadius: nh * 0.6)
    NSColor.black.setFill(); notch.fill()
    // spark
    let c = NSPoint(x: body.midX, y: body.midY - body.height * 0.04)
    let outer = body.width * 0.27
    NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1).setFill()
    for i in 0..<12 {
        let len = outer * (i % 2 == 0 ? 1 : 0.72), w = outer * 0.17
        let ray = NSBezierPath(roundedRect: NSRect(x: -w / 2, y: outer * 0.12, width: w, height: len - outer * 0.12),
                               xRadius: w / 2, yRadius: w / 2)
        var t = AffineTransform(translationByX: c.x, byY: c.y)
        t.rotate(byRadians: CGFloat(i) / 12 * .pi * 2)
        ray.transform(using: t)
        ray.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run(); p.waitUntilExit()
print("Icon written to \(out)")
