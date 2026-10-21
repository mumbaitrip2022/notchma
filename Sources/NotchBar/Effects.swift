import AppKit
import SwiftUI

// Flat design system + Core Animation effects. Continuous motion runs in the
// render server (≈0% app CPU) and is capped at 30 fps.

extension CAFrameRateRange {
    static let lowPower = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
}

/// Solid palette. No gradients anywhere.
enum Palette {
    static let surface1 = Color(white: 0.075)   // grouped list background
    static let surface2 = Color(white: 0.115)   // cards
    static let surface3 = Color(white: 0.17)    // secondary buttons, tiles
    static let code = Color(white: 0.045)
    static let hairline = Color.white.opacity(0.07)
    static let text2 = Color.white.opacity(0.70)   // secondary
    static let text3 = Color.white.opacity(0.50)   // tertiary — still readable at 10–11pt
}

// MARK: - Activity ring (indeterminate spinner, solid arc)

struct ActivityRing: NSViewRepresentable {
    var color: NSColor
    var size: CGFloat = 13
    var lineWidth: CGFloat = 1.8

    func makeNSView(context: Context) -> RingNSView {
        let v = RingNSView(); v.configure(color: color, lineWidth: lineWidth); return v
    }
    func updateNSView(_ v: RingNSView, context: Context) { v.configure(color: color, lineWidth: lineWidth) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RingNSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class RingNSView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var lastSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, arc] {
            l.fillColor = nil
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        arc.strokeStart = 0
        arc.strokeEnd = 0.28
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, lineWidth: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = color.withAlphaComponent(0.18).cgColor
        arc.strokeColor = color.cgColor
        track.lineWidth = lineWidth
        arc.lineWidth = lineWidth
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        let inset = arc.lineWidth / 2 + 0.5
        let path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [track, arc] {
            l.frame = bounds
            l.path = path
        }
        CATransaction.commit()
        arc.removeAllAnimations()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 0.9
        spin.repeatCount = .infinity
        spin.preferredFrameRateRange = .lowPower
        arc.add(spin, forKey: "spin")
    }
}

// MARK: - Agent glyph

/// The mark for each agent: Claude's spark, a hexagon for Codex, an arrow for Cursor.
struct AgentGlyph: View {
    let agent: Agent
    var active = false
    var size: CGFloat = 14
    var tinted = true

    var body: some View {
        let color = tinted ? agent.tint : .white
        Group {
            switch agent {
            case .claude:
                SparkView(color: NSColor(tinted ? Color.claude : .white),
                          spinning: active, size: size)
                    .frame(width: size, height: size)
            case .codex:
                Image(systemName: "hexagon")
                    .font(.system(size: size * 0.92, weight: .bold))
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, options: .repeating, isActive: active)
            case .cursor:
                if let icon = AppIcons.icon(for: .cursor) {
                    // The real Cursor logo, taken from the installed Cursor.app.
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 1.25, height: size * 1.25)
                } else {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: size * 0.95, weight: .bold))
                        .foregroundStyle(color)
                        .symbolEffect(.pulse, options: .repeating, isActive: active)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Square tile holding an agent glyph, with a status badge in the corner.
struct AgentTile: View {
    let agent: Agent
    var status: SessionStatus? = nil
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            if let icon = AppIcons.icon(for: agent) {
                // App icons bring their own rounded-square background.
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 1.12, height: size * 1.12) // icon art has built-in margins
            } else {
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).fill(Palette.surface3)
                AgentGlyph(agent: agent, active: status?.isWorking ?? false, size: size * 0.46)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let status { StatusBadge(status: status).offset(x: 4, y: 4) }
        }
    }
}

/// Small badge on a tile's corner.
struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            switch status {
            case .thinking, .tool:
                ActivityRing(color: .white, size: 10, lineWidth: 1.5).frame(width: 10, height: 10)
            case .needsApproval:
                Circle().fill(Color.approval).frame(width: 8, height: 8)
            case .waitingForInput:
                Circle().fill(Color.waiting).frame(width: 8, height: 8)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .black))
                    .foregroundStyle(Color.success)
            case .idle:
                Circle().fill(Color.white.opacity(0.28)).frame(width: 6, height: 6)
            }
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - Working text ("thinking" breath)

/// Status text that gently breathes (solid colour, brightness easing 100% ↔ 45%)
/// while an agent works. No gradients. Animated by Core Animation, so no
/// per-frame CPU work; still when idle or with Reduce Motion on.
struct ShimmerText: NSViewRepresentable {
    var text: String
    var active: Bool
    var size: CGFloat = 12.5
    var weight: NSFont.Weight = .regular
    var color: NSColor = NSColor.white.withAlphaComponent(0.70)

    func makeNSView(context: Context) -> ShimmerTextView {
        let v = ShimmerTextView()
        v.configure(text: text, active: active, font: .systemFont(ofSize: size, weight: weight), color: color)
        return v
    }

    func updateNSView(_ v: ShimmerTextView, context: Context) {
        v.configure(text: text, active: active, font: .systemFont(ofSize: size, weight: weight), color: color)
    }

    /// Measured from *this* text, not the view's previous state — SwiftUI may ask for
    /// the size before it hands the new text to the view.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerTextView, context: Context) -> CGSize? {
        let s = ShimmerTextView.measure(text, font: .systemFont(ofSize: size, weight: weight))
        var w = s.width
        if let pw = proposal.width, pw.isFinite { w = min(w, pw) }
        return CGSize(width: max(0, w), height: s.height)
    }
}

final class ShimmerTextView: NSView {
    static func measure(_ text: String, font: NSFont) -> CGSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(s.width) + 1, height: ceil(s.height))
    }

    private let label = CATextLayer()
    private var key = ""
    private var breathing = false
    private(set) var textSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.truncationMode = .end
        label.isWrapped = false
        label.alignmentMode = .left
        layer?.addSublayer(label)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(text: String, active: Bool, font: NSFont, color: NSColor) {
        let k = "\(text)|\(font.pointSize)|\(font.fontName)|\(color)|\(active)"
        guard k != key else { return }
        let textChanged = !key.hasPrefix(text + "|")
        key = k
        label.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        textSize = Self.measure(text, font: font)
        if textChanged { invalidateIntrinsicContentSize() }
        needsLayout = true

        let shouldBreathe = active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldBreathe != breathing else { return }
        breathing = shouldBreathe
        if shouldBreathe {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0
            a.toValue = 0.45
            a.duration = 1.1
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.preferredFrameRateRange = .lowPower
            label.add(a, forKey: "breathe")
        } else {
            label.removeAnimation(forKey: "breathe")
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let y = max(0, (bounds.height - textSize.height) / 2) // CATextLayer draws from the top
        label.frame = CGRect(x: 0, y: y, width: bounds.width, height: textSize.height)
        label.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

// MARK: - Real app icons

/// Official agent logos, read from the apps installed on this Mac (never bundled
/// with NotchBar). Currently used for Cursor; nil means "not installed" and the
/// built-in glyph is used instead.
enum AppIcons {
    private static var cache: [Agent: NSImage?] = [:]

    static func icon(for agent: Agent) -> NSImage? {
        if let cached = cache[agent] { return cached }
        var image: NSImage?
        if agent == .cursor,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalJump.cursorBundle) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache[agent] = image
        return image
    }
}
