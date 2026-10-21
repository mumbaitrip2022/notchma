import AppKit
import SwiftUI

/// A hardware-notch silhouette: concave flares at the top corners that melt into
/// the menu bar, and soft rounded corners at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = min(topRadius, r.width / 4)
        let b = min(bottomRadius, (r.height - t) , (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Claude-style starburst drawn with Core Animation. Spinning is done by the
/// render server, so it costs ~0% CPU (unlike a SwiftUI repeatForever animation).
struct SparkView: NSViewRepresentable {
    var color: NSColor
    var spinning: Bool
    var size: CGFloat = 14

    func makeNSView(context: Context) -> SparkNSView {
        let v = SparkNSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.update(color: color, spinning: spinning)
        return v
    }

    func updateNSView(_ v: SparkNSView, context: Context) {
        v.update(color: color, spinning: spinning)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SparkNSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// Claude-style starburst that feels alive while working: a wave ripples around
/// the 12 rays (each grows and shrinks just after its neighbour) while the star
/// slowly turns. Built from two CAReplicatorLayers, so one ray layer is drawn
/// and the GPU does the rest — ~0% CPU, capped at 30 fps.
final class SparkNSView: NSView {
    private let spinner = CALayer()              // slow rotation
    private let longRep = CAReplicatorLayer()    // 6 long rays
    private let shortRep = CAReplicatorLayer()   // 6 short rays, offset half a step
    private let longRay = CALayer()
    private let shortRay = CALayer()
    private var animating = false
    private var lastSize: CGSize = .zero

    private static let wave: CFTimeInterval = 1.2   // one ray's grow-shrink cycle
    private static let step: CFTimeInterval = wave / 12 // delay between neighbouring rays

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(spinner)
        for (rep, ray) in [(longRep, longRay), (shortRep, shortRay)] {
            rep.instanceCount = 6
            rep.instanceTransform = CATransform3DMakeRotation(.pi / 3, 0, 0, 1)
            rep.addSublayer(ray)
            ray.anchorPoint = CGPoint(x: 0.5, y: 0) // grow outward from the centre
            spinner.addSublayer(rep)
        }
        // Short rays sit between the long ones.
        shortRep.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 6))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        let b = bounds
        let outer = min(b.width, b.height) / 2
        let w = max(1.2, outer * 0.17), inner = outer * 0.12
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.frame = b
        for (rep, ray, len) in [(longRep, longRay, outer), (shortRep, shortRay, outer * 0.72)] {
            rep.bounds = b
            rep.position = CGPoint(x: b.midX, y: b.midY)
            ray.bounds = CGRect(x: 0, y: 0, width: w, height: max(1, len - inner))
            ray.position = CGPoint(x: b.midX, y: b.midY + inner)
            ray.cornerRadius = w / 2
        }
        CATransaction.commit()
        if animating { animating = false; startAnimating() } // restart with new geometry
    }

    func update(color: NSColor, spinning: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        longRay.backgroundColor = color.cgColor
        shortRay.backgroundColor = color.cgColor
        CATransaction.commit()

        let shouldAnimate = spinning && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate != animating else { return }
        shouldAnimate ? startAnimating() : stopAnimating()
    }

    private func startAnimating() {
        guard !animating else { return }
        animating = true
        let now = CACurrentMediaTime()

        // The ripple: rays breathe in sequence around the circle.
        func wave(offset: CFTimeInterval) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = 1.0
            a.toValue = 0.55
            a.duration = Self.wave / 2
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.beginTime = now + offset
            a.fillMode = .backwards
            a.preferredFrameRateRange = .lowPower
            return a
        }
        // Long rays are every other position (2 steps apart); short ones fill the gaps.
        longRep.instanceDelay = Self.step * 2
        shortRep.instanceDelay = Self.step * 2
        longRay.add(wave(offset: 0), forKey: "wave")
        shortRay.add(wave(offset: Self.step), forKey: "wave")

        // Gentle turn underneath the ripple.
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 9
        spin.repeatCount = .infinity
        spin.preferredFrameRateRange = .lowPower
        spinner.add(spin, forKey: "spin")
    }

    private func stopAnimating() {
        animating = false
        // Settle smoothly back to the resting star instead of snapping.
        for l in [longRay, shortRay, spinner] {
            if let p = l.presentation() { l.transform = p.transform }
            l.removeAllAnimations()
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        for l in [longRay, shortRay, spinner] { l.transform = CATransform3DIdentity }
        CATransaction.commit()
    }

    /// 12 tapered rays, alternating long/short, like Claude's mark.
    static func starburst(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        let c = CGPoint(x: r.midX, y: r.midY)
        let outer = min(r.width, r.height) / 2
        let rays = 12
        for i in 0..<rays {
            let angle = CGFloat(i) / CGFloat(rays) * .pi * 2
            let len = outer * (i % 2 == 0 ? 1.0 : 0.72)
            let w = outer * 0.17
            let rect = CGRect(x: -w / 2, y: outer * 0.12, width: w, height: len - outer * 0.12)
            var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle)
            path.addPath(CGPath(roundedRect: rect, cornerWidth: w / 2, cornerHeight: w / 2, transform: &t))
        }
        return path
    }
}

extension Color {
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)      // #D97757
    static let approval = Color(red: 1.0, green: 0.72, blue: 0.24)
    static let success = Color(red: 0.33, green: 0.85, blue: 0.52)
    static let dim = Color.white.opacity(0.5)
    static let waiting = Color(red: 0.45, green: 0.7, blue: 1)
    static let danger = Color(red: 1, green: 0.38, blue: 0.4)
}

extension NSColor {
    static let claude = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    static let approval = NSColor(red: 1.0, green: 0.72, blue: 0.24, alpha: 1)
}
