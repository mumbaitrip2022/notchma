import SwiftUI

/// Colour for "how much is used": calm white, amber when getting close, red near the cap.
func usageColor(_ pct: Double) -> Color {
    pct >= 90 ? .danger : (pct >= 70 ? .approval : .white)
}

/// Static ring gauge (no continuous animation, so it costs nothing at rest).
struct LimitRing: View {
    let percent: Double
    var size: CGFloat = 15
    var lineWidth: CGFloat = 2.4

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.13), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, percent / 100)))
                .stroke(usageColor(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.5), value: percent)
    }
}

/// Plan-limit strip under the header: one group per agent that reports limits.
struct UsageStrip: View {
    let limits: [(Agent, [UsageWindow])]
    /// When a window will run out at the current pace (nil = not before reset).
    var forecast: (Agent, UsageWindow) -> Date? = { _, _ in nil }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(showResets: true)
            content(showResets: false)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface1))
    }

    private func content(showResets: Bool) -> some View {
        HStack(spacing: 16) {
            ForEach(Array(limits.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(Palette.hairline).frame(width: 1, height: 16) }
                HStack(spacing: 12) {
                    AgentGlyph(agent: item.0, active: false, size: 12)
                    ForEach(item.1) { w in
                        HStack(spacing: 6) {
                            LimitRing(percent: w.usedPercent)
                            Text("\(Int(w.usedPercent.rounded()))%")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(usageColor(w.usedPercent))
                                .contentTransition(.numericText())
                            Text(w.label)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.text2)
                            if let eta = forecast(item.0, w) {
                                Text("full ~" + Fmt.clock(eta))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.approval)
                            } else if showResets, let r = w.resetsAt {
                                Text("↻ " + Fmt.reset(r))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.text3)
                            }
                        }
                        .help("\(item.0.shortName) \(w.label) limit: \(Int(w.usedPercent))% used"
                              + (forecast(item.0, w).map { ", full by \(Fmt.clock($0)) at this pace" } ?? "")
                              + (w.resetsAt.map { ", resets \(Fmt.reset($0))" } ?? ""))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Determinate ring for plan progress (static — no animation cost at rest).
struct ProgressRing: View {
    let fraction: Double
    var size: CGFloat = 13
    var lineWidth: CGFloat = 1.8
    var color: Color = .white

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.04, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// Thin context-window meter for a session row.
struct ContextMeter: View {
    let percent: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.1))
            Capsule().fill(usageColor(percent).opacity(percent >= 70 ? 1 : 0.55))
                .frame(width: max(2, 34 * min(1, percent / 100)))
        }
        .frame(width: 34, height: 3)
        .help("Context \(Int(percent))% used" + (percent >= 80 ? " — will compact soon" : ""))
    }
}
