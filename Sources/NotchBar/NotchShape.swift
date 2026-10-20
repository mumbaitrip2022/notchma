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

final class SparkNSView: NSView {
    private let shape = CAShapeLayer()
    private var isSpinning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(shape)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.bounds = b
        shape.position = CGPoint(x: b.midX, y: b.midY)
        shape.path = Self.starburst(in: b)
        shape.shadowPath = shape.path
        CATransaction.commit()
    }

    func update(color: NSColor, spinning: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        shape.fillColor = color.cgColor
        // Soft halo; shadowPath keeps it cheap even while rotating.
        shape.shadowColor = color.cgColor
        shape.shadowOpacity = 0
        shape.shadowRadius = 3.5
        shape.shadowOffset = .zero
        CATransaction.commit()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldSpin = spinning && !reduceMotion
        guard shouldSpin != isSpinning else { return }
        isSpinning = shouldSpin
        if shouldSpin {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -Double.pi * 2
            spin.duration = 5
            spin.repeatCount = .infinity
            spin.preferredFrameRateRange = .lowPower
            shape.add(spin, forKey: "spin")

            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.82
            breathe.toValue = 1.06
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.preferredFrameRateRange = .lowPower
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(breathe, forKey: "breathe")
        } else {
            shape.removeAllAnimations()
        }
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
