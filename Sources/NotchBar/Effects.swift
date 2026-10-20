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
    static let text2 = Color.white.opacity(0.56)
    static let text3 = Color.white.opacity(0.34)
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
                Image(systemName: "cursorarrow")
                    .font(.system(size: size * 0.95, weight: .bold))
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, options: .repeating, isActive: active)
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
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).fill(Palette.surface3)
            AgentGlyph(agent: agent, active: status?.isWorking ?? false, size: size * 0.46)
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
