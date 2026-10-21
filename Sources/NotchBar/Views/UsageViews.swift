import SwiftUI

/// Colour for "how much is used": neutral until it matters — amber from 85%, red from 95%.
func usageColor(_ pct: Double) -> Color {
    pct >= 95 ? .danger : (pct >= 85 ? .approval : .white)
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
    /// Inside a shared card (no own background).
    var bare = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(showResets: true)
            content(showResets: false)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(bare ? Color.clear : Palette.surface1))
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
        .help("Context \(Int(percent))% used" + (percent >= 80 ? ", will compact soon" : ""))
    }
}


// MARK: - Resources card (plan limits + system vitals)

/// One quiet card: plan limits on top, CPU · MEM · SSD below. Gray unless something needs attention.
struct ResourcesCard: View {
    let limits: [(Agent, [UsageWindow])]
    var forecast: (Agent, UsageWindow) -> Date?
    @ObservedObject var system: SystemMonitor
    let showVitals: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !limits.isEmpty {
                UsageStrip(limits: limits, forecast: forecast, bare: true)
            }
            if !limits.isEmpty && showVitals {
                Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 12)
            }
            if showVitals { VitalsRow(system: system) }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface1))
    }
}

/// CPU · MEM · SSD in three equal columns: label, thin bar, number.
struct VitalsRow: View {
    @ObservedObject var system: SystemMonitor

    var body: some View {
        HStack(spacing: 14) {
            Vital(label: "CPU",
                  value: system.cpuReady ? "\(Int(system.cpu.rounded()))%" : "…",
                  fraction: system.cpu / 100,
                  overlay: system.agentCPU / 100,
                  bar: Color.white.opacity(0.28),
                  overlayColor: Color.white.opacity(0.9),
                  alert: nil,
                  help: cpuHelp)
            Vital(label: "MEM",
                  value: SystemMonitor.memString(system.memUsed),
                  fraction: Double(system.memUsed) / Double(max(system.memTotal, 1)),
                  bar: memAlert ?? Color.white.opacity(0.5),
                  alert: memAlert,
                  help: memHelp)
            Vital(label: "SSD",
                  value: SystemMonitor.diskString(system.diskFree) + " free",
                  fraction: system.diskTotal > 0 ? 1 - Double(system.diskFree) / Double(system.diskTotal) : 0,
                  bar: diskAlert ?? Color.white.opacity(0.5),
                  alert: diskAlert,
                  help: "\(SystemMonitor.diskString(system.diskFree)) available of \(SystemMonitor.diskString(system.diskTotal)). \(SystemMonitor.diskString(system.diskFreeNow)) is free right now, plus \(SystemMonitor.diskString(max(0, system.diskFree - system.diskFreeNow))) of caches macOS clears automatically when space is needed")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var cpuHelp: String {
        guard system.cpuReady else { return "Measuring…" }
        return "CPU \(Int(system.cpu.rounded()))% of the whole Mac. Agents and the tools they started: \(Int(system.agentCPU.rounded()))% (bright part)"
    }

    /// Only critical pressure is coloured — "warning" is everyday life on small-RAM Macs.
    private var memAlert: Color? { system.pressure == .critical ? .danger : nil }

    private var memHelp: String {
        let p: String
        switch system.pressure {
        case .normal: p = "normal"
        case .warning: p = "elevated"
        case .critical: p = "critical, the Mac is short of memory"
        }
        return "\(SystemMonitor.memString(system.memUsed)) of \(SystemMonitor.memString(system.memTotal)) used (\(SystemMonitor.memString(system.memCompressed)) compressed) · memory pressure \(p)"
    }

    private var diskAlert: Color? {
        guard system.diskTotal > 0 else { return nil }
        let gb = Double(system.diskFree) / 1_000_000_000
        return gb < 3 ? .danger : (gb < 10 ? .approval : nil)
    }
}

private struct Vital: View {
    let label: String
    let value: String
    let fraction: Double
    var overlay: Double = 0
    let bar: Color
    var overlayColor: Color = .clear
    /// Set only when the value needs attention; otherwise the number stays neutral white.
    let alert: Color?
    let help: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Palette.text3)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule().fill(bar).frame(width: g.size.width * clamp(fraction))
                    if overlay > 0 {
                        Capsule().fill(overlayColor).frame(width: max(2, g.size.width * clamp(overlay)))
                    }
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.6), value: fraction)
            .animation(.easeOut(duration: 0.6), value: overlay)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(alert ?? Color.white.opacity(0.88))
                .contentTransition(.numericText())
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .help(help)
    }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v.isFinite ? v : 0)) }
}
