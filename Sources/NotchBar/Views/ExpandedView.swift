import SwiftUI

struct ExpandedView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    @ObservedObject var prefs: Prefs
    @ObservedObject var trust: TrustPolicy
    @ObservedObject var launcher: Launcher
    let system: SystemMonitor
    var actions: NotchActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch ui.page {
            case .home: home
            case .launcher:
                LauncherView(store: store, ui: ui, prefs: prefs, launcher: launcher)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 14)
        .animation(NotchUI.motion, value: ui.page)
    }

    @ViewBuilder private var home: some View {
        header
        if !trust.active.isEmpty { TrustBar(trust: trust) }
        let limits = store.activeLimits
        if !limits.isEmpty || prefs.showVitals {
            ResourcesCard(limits: limits, forecast: { agent, w in store.forecast.fullAt(agent, w) },
                          system: system, showVitals: prefs.showVitals)
        }
        if let approval = store.approvals.first {
            let siblings = store.approvals.filter { $0.sessionID == approval.sessionID && !$0.risky }.count
            ApprovalCard(
                approval: approval,
                session: store.sessions[approval.sessionID],
                position: 1, total: store.approvals.count,
                trustMinutes: prefs.trustMinutes,
                batchCount: siblings,
                decide: { store.decide(approval, $0) },
                allowAll: { store.allowAll(sessionID: approval.sessionID) })
            .id(approval.id)
            .transition(AnyTransition.asymmetric(
                insertion: AnyTransition(.blurReplace).combined(with: .move(edge: .top)),
                removal: AnyTransition(.blurReplace).combined(with: .scale(scale: 0.96))))
        }
        sessionList
            .animation(NotchUI.motion, value: store.approvals.map(\.id))
            .animation(NotchUI.motion, value: store.sortedSessions.map(\.id))
    }

    // MARK: header (sits in the menu-bar band)

    private var header: some View {
        let queue = store.queue
        return BandRow(gap: ui.cameraGap) {
            if !queue.isEmpty {
                Text(ui.hasHardwareNotch ? "\(queue.count) waiting" : "\(queue.count) waiting on you")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                if !ui.hasHardwareNotch, let oldest = queue.compactMap(\.waitingSince).min() {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text("oldest " + Self.age(ctx.date.timeIntervalSince(oldest)))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.text3)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
        } trailing: {
            if !queue.isEmpty {
                Button { if let s = queue.first { store.jump(to: s.id) } } label: {
                    HStack(spacing: 5) {
                        Text("Next")
                        if prefs.jumpShortcut && !ui.hasHardwareNotch { Text("⌃⌥J").opacity(0.5) }
                    }
                }
                .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                .help("Jump to the oldest thing waiting on you (⌃⌥J)")
            }
            if prefs.installed.isEmpty {
                Button(action: actions.connect) { Text("Connect") }
                    .buttonStyle(NBButtonStyle(kind: .primary, compact: true))
            }
            Button { ui.page = .launcher } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(CircleIconButtonStyle())
            .help("Start a new agent task")
            Button(action: actions.showMenu) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(CircleIconButtonStyle())
            .help("Settings")
        }
        .frame(height: max(ui.bandHeight, 30))
        .padding(.horizontal, 8)
        .animation(NotchUI.motion, value: store.queue.count)
    }

    static func age(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    private var headline: String {
        let w = store.activeCount
        if w > 0 { return w == 1 ? "1 agent working" : "\(w) agents working" }
        if !store.sessions.isEmpty { return "All caught up" }
        return "NotchBar"
    }

    // MARK: sessions

    @ViewBuilder private var sessionList: some View {
        let sessions = store.sortedSessions
        if sessions.isEmpty {
            EmptyStateView(installed: prefs.installed)
        } else {
            let queued = Set(store.queue.map(\.id))
            let rows = VStack(spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in
                    if i > 0 {
                        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 58)
                    }
                    SessionRow(session: s, open: ui.openRow == s.id, queued: queued.contains(s.id),
                               queuedFollowUp: store.queued[s.id] != nil,
                               onTap: { store.jump(to: s.id) },
                               onToggle: {
                                   ui.openRow = ui.openRow == s.id ? nil : s.id
                                   if ui.openRow == s.id { store.attend(s.id) }
                               })
                        .id(s.id)
                    if ui.openRow == s.id {
                        SessionDetail(store: store, ui: ui, prefs: prefs, session: s, actions: actions)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(4)
            .animation(NotchUI.motion, value: ui.openRow)
            Group {
                if sessions.count <= 3 && ui.openRow == nil {
                    rows
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) { rows }
                            .frame(maxHeight: ui.openRow == nil ? 4 * 58 + 8 : 400)
                            .fixedSize(horizontal: false, vertical: true)
                            .onChange(of: ui.openRow) { _, id in
                                // Bring an opened row (and its details) into view.
                                guard let id else { return }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    withAnimation(NotchUI.motion) { proxy.scrollTo(id, anchor: .top) }
                                }
                            }
                            .onAppear { if let id = ui.openRow { proxy.scrollTo(id, anchor: .top) } }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface1))
        }
    }
}

// MARK: - Trust bar

struct TrustBar: View {
    @ObservedObject var trust: TrustPolicy

    var body: some View {
        VStack(spacing: 6) {
            ForEach(trust.active, id: \.project) { item in
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(Color.success)
                    Text((item.project as NSString).lastPathComponent).fontWeight(.semibold).foregroundStyle(.white)
                    Text("is trusted, safe requests are auto-allowed").foregroundStyle(Palette.text2).lineLimit(1)
                    Spacer(minLength: 6)
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text("\(max(1, Int(item.until.timeIntervalSince(ctx.date) / 60)))m left")
                            .monospacedDigit()
                            .foregroundStyle(Palette.text3)
                    }
                    Button("End") { trust.end(project: item.project) }
                        .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                }
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.success.opacity(0.08)))
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: Session
    let open: Bool
    let queued: Bool
    var queuedFollowUp = false
    let onTap: () -> Void
    let onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            AgentTile(agent: session.agent, status: session.status, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if queued {
                        Circle().fill(dotColor)
                            .frame(width: 6, height: 6)
                            .help(yourTurn ? "Waiting on you" : "Finished, not reviewed yet")
                    }
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let branch = session.branch {
                        Text(branch)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.text3)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 0) {
                    if session.alert != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.approval)
                            .padding(.trailing, 5)
                    } else if session.status.isWorking, let phase = session.livePhase ?? session.actions.last?.phase {
                        Image(systemName: phase.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.text3)
                            .frame(width: 14)
                            .padding(.trailing, 4)
                    }
                    Group {
                        if session.status == .waitingForInput && session.alert == nil {
                            WaitingLine(session: session)
                        } else if session.status.isWorking && session.alert == nil {
                            ShimmerText(text: session.statusText, active: true, size: 11.5,
                                        color: NSColor(statusColor))
                                .frame(height: 14)
                        } else {
                            Text(session.alert?.text ?? session.statusText)
                                .foregroundStyle(session.alert != nil ? Color.approval : statusColor)
                                .lineLimit(1)
                        }
                    }
                    .layoutPriority(1)
                    if !detailLine.isEmpty {
                        Text("  ·  " + detailLine)
                            .foregroundStyle(Palette.text3)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11.5))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if session.status.isWorking, let p = session.planProgress {
                    HStack(spacing: 5) {
                        Text("\(p.done)/\(p.total)").font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Palette.text2)
                        ProgressRing(fraction: Double(p.done) / Double(max(p.total, 1)), size: 12)
                    }
                    .help("Step \(min(p.done + 1, p.total)) of \(p.total) in its plan")
                } else if session.status == .done, let cost = session.lastTask?.costUSD, cost > 0 {
                    Text(Fmt.cost(cost))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.text2)
                        .help("API-equivalent cost of the last task (not billed on Pro/Max)")
                } else {
                    ElapsedLabel(session: session)
                }
                if let ctx = session.contextPercent { ContextMeter(percent: ctx) }
            }
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10.5, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(CircleIconButtonStyle())
            .opacity(hover || open ? 1 : 0.35)
            .help(open ? "Hide details" : "Answer, review and next prompt")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 54)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white.opacity(hover || open ? 0.06 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 15))
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .onTapGesture(perform: onTap)
        .help("Jump to \(session.agent == .cursor ? "Cursor" : "its terminal")")
    }

    /// Amber: approve something. Blue: your reply. White: finished, not reviewed yet.
    private var dotColor: Color {
        if case .needsApproval = session.status { return .approval }
        if session.alert != nil { return .approval }
        if session.status == .waitingForInput { return .waiting }
        return Color.white.opacity(0.85)
    }

    /// Approval or input needed (vs. a finished task you haven't looked at).
    private var yourTurn: Bool {
        if case .needsApproval = session.status { return true }
        return session.status == .waitingForInput || session.alert != nil
    }

    /// After a task: its receipt (time, tokens, lines, tests). Otherwise: the prompt.
    private var detailLine: String {
        if session.status.isWorking {
            var bits: [String] = []
            if let item = session.currentPlanItem, (item.activeText ?? item.text) != session.liveLine {
                bits.append(item.activeText ?? item.text)
            }
            if session.steps > 0 { bits.append("\(session.steps) step\(session.steps == 1 ? "" : "s")") }
            if queuedFollowUp { bits.insert("follow-up queued", at: 0) }
            if session.autoAllowed > 0 { bits.append("\(session.autoAllowed) auto-allowed") }
            if !bits.isEmpty { return bits.joined(separator: " · ") }
        }
        if session.status == .done, let r = session.lastTask {
            var t = r
            t.costUSD = nil // cost is shown on the right
            var parts = [Fmt.receipt(t)].filter { !$0.isEmpty }
            if let tr = session.testResult { parts.insert(tr.summary, at: 0) }
            if !parts.isEmpty { return parts.joined(separator: "  ·  ") }
        }
        return ToolInfo.firstLine(session.lastPrompt)
    }

    private var statusColor: Color {
        switch session.status {
        case .needsApproval: return .approval
        case .thinking, .tool: return Palette.text2
        case .waitingForInput: return .waiting
        case .done: return session.testResult.map { $0.failed > 0 ? Color.danger : .success } ?? .success
        case .idle: return Palette.text3
        }
    }
}

// MARK: - Session detail (answer · review · next prompt)

struct SessionDetail: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUI
    @ObservedObject var prefs: Prefs
    let session: Session
    let actions: NotchActions
    @FocusState private var focused: Bool
    @State private var copied = false

    private var draft: Binding<String> {
        Binding(get: { store.drafts[session.id] ?? "" },
                set: { store.drafts[session.id] = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let msg = session.lastMessage, !msg.isEmpty {
                ScrollView(.vertical) {
                    Text(Self.markdown(msg))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.code))
            }
            if !session.plan.isEmpty { PlanList(plan: session.plan, tint: .white) }
            if !session.actions.isEmpty && (session.status.isWorking || session.lastMessage == nil) {
                ActivityTrail(actions: session.actions)
            }

            if !summaryChips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(summaryChips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(chip.hasPrefix("tests ✗") ? Color.danger : Palette.text2)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Palette.surface3))
                    }
                }
            }

            HStack(spacing: 8) {
                Button { actions.openDiff(session.id) } label: { Label("Open diff", systemImage: "plus.forwardslash.minus") }
                    .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                    .help("Open the project's uncommitted changes in your editor")
                Button {
                    actions.copySummary(session.id)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy summary", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                    .help("Commit-style summary: what it did, files, tests")
                Spacer()
            }

            // A follow-up already waiting for this session.
            if let q = store.queued[session.id] {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.success)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Queued, sends when it finishes").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.success)
                        Text(q).font(.system(size: 12)).foregroundStyle(.white).lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    Button("Edit") { store.cancelQueued(session.id); focused = true }
                        .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.success.opacity(0.08)))
            }

            // Next prompt: queue it while the agent works, or send it now.
            HStack(alignment: .bottom, spacing: 8) {
                TextField(store.isBusy(session) ? "Follow-up for when it finishes…" : "Next prompt…",
                          text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.code))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(focused ? Color.white.opacity(0.25) : Palette.hairline, lineWidth: 1))
                    .onSubmit { send() }
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30)
                }
                .buttonStyle(CircleSolidButtonStyle())
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(deliveryHint)
            }
            Text(deliveryHint)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.text3)
                .padding(.leading, 4)
                .padding(.top, -4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .onChange(of: focused) { _, f in ui.editing = f }
        .onDisappear { if focused { ui.editing = false } }
    }

    private func send() {
        focused = false
        store.sendDraft(session.id)
    }

    private var deliveryHint: String {
        store.isBusy(session) ? "Sends itself the moment it finishes. No copy paste needed"
            : TerminalJump.deliveryHint(for: session, pasteAllowed: prefs.autoPaste)
    }

    private var summaryChips: [String] {
        var chips: [String] = []
        if let t = session.testResult { chips.append(t.summary) }
        if !session.editedFiles.isEmpty {
            chips.append("\(session.editedFiles.count) file\(session.editedFiles.count == 1 ? "" : "s") edited")
        }
        if session.status == .done, let r = session.lastTask {
            let s = Fmt.receipt(r, includeDuration: false)
            if !s.isEmpty { chips.append(s) }
        }
        return chips
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Live elapsed timer. The TimelineView only exists while the panel is expanded
/// and the session is working, so there is no ticking otherwise.
struct ElapsedLabel: View {
    let session: Session

    var body: some View {
        Group {
            if session.status.isWorking || isApproval, let start = session.turnStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.format(ctx.date.timeIntervalSince(start)))
                        .contentTransition(.numericText())
                }
            } else if session.status == .done, let s = session.turnStartedAt, let e = session.turnEndedAt {
                Text(Self.format(e.timeIntervalSince(s)))
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Palette.text3)
    }

    private var isApproval: Bool {
        if case .needsApproval = session.status { return true }
        return false
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct EmptyStateView: View {
    let installed: Set<Agent>

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(Agent.allCases) { a in
                    AgentTile(agent: a, size: 30).opacity(installed.contains(a) ? 1 : 0.35)
                }
            }
            VStack(spacing: 4) {
                Text("All quiet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(installed.isEmpty
                     ? "Connect Claude Code, Codex or Cursor from the gear menu."
                     : "Start an agent with + and it shows up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface1))
    }
}

/// Solid white circular button (send).
struct CircleSolidButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? Color.black : Palette.text3)
                .background(Circle().fill(enabled ? Color.white : Palette.surface3))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

// MARK: - Plan & activity

/// The agent's own to-do list: ✓ done, ● now, ○ next.
struct PlanList: View {
    let plan: [PlanItem]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(plan) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        switch item.status {
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.success)
                        case .active: Image(systemName: "circle.inset.filled").foregroundStyle(tint)
                        case .pending: Image(systemName: "circle").foregroundStyle(Palette.text3)
                        }
                    }
                    .font(.system(size: 11))
                    Text(item.status == .active ? (item.activeText ?? item.text) : item.text)
                        .font(.system(size: 12, weight: item.status == .active ? .semibold : .regular))
                        .foregroundStyle(item.status == .pending ? Palette.text2 : (item.status == .done ? Palette.text3 : .white))
                        .strikethrough(item.status == .done, color: Palette.text3)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.code))
    }
}

/// What it just did, newest first.
struct ActivityTrail: View {
    let actions: [ActionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(actions.suffix(5).reversed()) { a in
                HStack(spacing: 8) {
                    Image(systemName: a.phase.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.text3)
                        .frame(width: 14)
                    Text(a.ok == nil ? ToolInfo.verb(for: a.tool) + (a.detail.isEmpty ? "" : " " + a.detail) : a.pastTense)
                        .font(.system(size: 11.5))
                        .foregroundStyle(a.ok == false ? Color.danger : (a.ok == nil ? .white : Palette.text2))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    TimelineView(.periodic(from: .now, by: 15)) { ctx in
                        Text(ExpandedView.age(ctx.date.timeIntervalSince(a.at)))
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Palette.text3)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }
}
