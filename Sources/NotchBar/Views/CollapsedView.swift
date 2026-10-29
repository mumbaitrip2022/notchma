import SwiftUI

/// The resting island: a compact "live activity".
struct CollapsedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    let pet: PetBrain
    let showPet: Bool
    let showsActivity: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if showPet && !showsActivity {
            // Nothing running: the pet hangs out in the notch.
            // Whole device pixels only, so the art stays crisp: 1.5pt on Retina, 2pt on 1x screens.
            let px: CGFloat = ui.bandHeight >= 30 || displayScale < 2 ? 2 : 1.5
            PetView(brain: pet, pixel: px, roams: true, ground: ui.bandHeight >= 30 ? 1 : 0,
                    hiddenWidth: ui.hardwareNotchWidth)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { ui.pinned.toggle() }
                .transition(.opacity)
        } else {
            activity
        }
    }

    private var activity: some View {
        HStack(spacing: 8) {
            leading
            if showsActivity && !ui.hasHardwareNotch, let c = ciFocus, let ci = c.ci {
                // CI is running: which project, and the step GitHub is on right now.
                HStack(spacing: 7) {
                    Text(c.projectName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                    CIShimmerLine(text: ciLine(ci), size: 12.5)
                        .frame(height: 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            } else if showsActivity && !ui.hasHardwareNotch, let s = focus {
                HStack(spacing: 7) {
                    Text(s.projectName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                    if s.status == .waitingForInput && s.alert == nil && store.approvals.isEmpty && !store.doneFlash {
                        WaitingLine(session: s, size: 12.5)
                    } else {
                        // While it works, the status gently breathes.
                        ShimmerText(text: statusLabel, active: isThinkingLine(s), size: 12.5,
                                    color: NSColor(statusColor))
                            .frame(height: 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
            if ui.hasHardwareNotch || !showsActivity { Spacer(minLength: ui.hasHardwareNotch ? ui.hardwareNotchWidth : 4) }
            trailing
        }
        .padding(.leading, 12)
        .padding(.trailing, 11)
        .opacity(showsActivity || !store.sessions.isEmpty ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { ui.pinned.toggle() }
    }

    /// CI takes the notch when nothing more urgent is on. An agent that just pushed is
    /// usually waiting for you, so a running pipeline wins over "waiting".
    private var ciFocus: Session? {
        guard store.approvals.isEmpty, !store.doneFlash, !store.isAnyWorking else { return nil }
        return store.liveCI
    }

    private func ciLine(_ ci: CIStatus) -> String {
        if case .waiting = ci.state { return "waiting for GitHub" }
        return ci.step ?? (ci.stages.isEmpty ? "CI running" : "CI \(ci.stages.filter { $0.state == .passed }.count)/\(ci.stages.count)")
    }

    private var focus: Session? {
        if let a = store.approvals.first { return store.sessions[a.sessionID] }
        if store.doneFlash, let s = store.sortedSessions.first(where: { $0.status == .done }) { return s }
        return store.primary
    }

    private var statusLabel: String {
        if let a = store.approvals.first {
            return a.risky ? "risky command" : "wants to \(ToolInfo.approvalVerb(a.toolName))"
        }
        guard let s = focus else { return "" }
        if let alert = s.alert { return alert.text.lowercased() }
        if store.doneFlash && s.status == .done { return "done" }
        if s.status.isWorking { return s.compactLine }
        return s.statusText.lowercased()
    }

    /// Shimmer only for genuine work-in-progress lines, not alerts, approvals or "done".
    private func isThinkingLine(_ s: Session) -> Bool {
        s.status.isWorking && s.alert == nil && store.approvals.isEmpty && !store.doneFlash
    }

    private var statusColor: Color {
        if let a = store.approvals.first { return a.risky ? .danger : .approval }
        if focus?.alert != nil { return .approval }
        if store.doneFlash { return .success }
        if focus?.status == .waitingForInput { return .waiting }
        return Palette.text2
    }

    @ViewBuilder private var leading: some View {
        if let c = ciFocus, let ci = c.ci {
            CIGlimpseMark(state: ci.overall, size: 16)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        } else if let a = store.approvals.first {
            Image(systemName: "circle.fill")
                .font(.system(size: 8.5))
                .foregroundStyle(a.risky ? Color.danger : Color.approval)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: 15, height: 15)
        } else if let s = focus {
            AgentGlyph(agent: s.agent, active: s.status.isWorking, size: 15)
        } else {
            AgentGlyph(agent: .claude, active: false, size: 15)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let c = ciFocus, let ci = c.ci {
            HStack(spacing: 8) {
                CIMiniPipeline(stages: ci.stages)
                if !ui.hasHardwareNotch {
                    CIElapsed(ci: ci)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.text2)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: ci.stages)
            .transition(.opacity)
        } else if !store.approvals.isEmpty {
            Text("\(store.approvals.count)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.black)
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, store.approvals.count > 9 ? 4 : 0)
                .background(Capsule().fill(Color.approval))
                .transition(.scale.combined(with: .opacity))
        } else if store.doneFlash {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.black, Color.success)
                .symbolEffect(.bounce, value: store.doneFlash)
                .transition(.scale.combined(with: .opacity))
        } else if let s = store.sortedSessions.first(where: { $0.status.isWorking }) {
            HStack(spacing: 7) {
                if let ci = store.liveCI?.ci {
                    CIGlimpseMark(state: ci.overall, size: 13)
                        .help("CI is running")
                        .transition(.scale.combined(with: .opacity))
                }
                if let p = s.planProgress {
                    // Real progress through the agent's own plan.
                    Text("\(p.done)/\(p.total)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Palette.text2)
                    ProgressRing(fraction: Double(p.done) / Double(max(p.total, 1)))
                } else if let start = s.turnStartedAt {
                    // Ticks once a second, only while something is running.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(ElapsedLabel.format(ctx.date.timeIntervalSince(start)))
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: false))
                            .foregroundStyle(Palette.text2)
                    }
                }
                if s.planProgress == nil { ActivityRing(color: .white, size: 13).frame(width: 13, height: 13) }
            }
            .transition(.opacity)
        } else if store.sessions.values.contains(where: { $0.status == .waitingForInput }) {
            Circle().fill(Color.waiting).frame(width: 7, height: 7)
        }
    }
}
