import AppKit
import Combine
import Foundation

/// Single source of truth for sessions, approvals and everything derived from
/// them. Main thread only. Heavy work (file reads, git) runs on `io`.
final class SessionStore: ObservableObject {
    // MARK: published state
    @Published private(set) var sessions: [String: Session] = [:] {
        didSet { syncLedger(oldValue) }
    }
    @Published private(set) var approvals: [Approval] = []
    @Published private(set) var doneFlash = false
    /// Transient Dynamic-Island-style alert (turn finished, waiting for you…).
    @Published private(set) var banner: Banner?
    /// Plan-limit windows per agent (Claude 5h/week, Codex windows).
    @Published private(set) var limits: [Agent: [UsageWindow]] = SessionStore.loadLimits()
    /// Your drafted next prompt per session (still being written).
    @Published var drafts: [String: String] = [:]
    /// Follow-ups waiting to be sent automatically when the session finishes its turn.
    @Published private(set) var queued: [String: String] = [:]

    // MARK: collaborators
    let rules = RuleStore()
    let trust = TrustPolicy()
    let forecast = UsageForecast()
    let ledger = DayLedger()
    private let conflicts = ConflictTracker()
    private let io = DispatchQueue(label: "notchbar.usage", qos: .utility)

    // MARK: settings (injected by the controller)
    var cursorApprovalsEnabled: () -> Bool = { false }
    var readOnlyDefaults: () -> Bool = { false }
    var nudgesEnabled: () -> Bool = { true }
    var isQuiet: () -> Bool = { false }
    var autoPaste: () -> Bool = { true }

    // MARK: callbacks
    var onNewApproval: (() -> Void)?
    var onTurnDone: (() -> Void)?
    var sendReply: ((SocketServer.ClientID, [String: Any]) -> Void)?
    /// Recently seen project roots (for the launcher).
    var onProjectSeen: ((String) -> Void)?

    // MARK: private state
    private struct Tracking {
        var recentCalls: [(sig: String, at: Date)] = []
        var failStreak: [String: Int] = [:]
        var contextWarned = false
    }
    private var tracking: [String: Tracking] = [:]
    private var lastStatusSig: [String: String] = [:]
    private var codexRefreshAt: [String: Date] = [:]
    private var narrationAt: [String: Date] = [:]
    private var alertedKeys = Set<String>()
    private var livenessTimer: Timer?
    private var slowTimer: Timer?
    private var doneFlashWork: DispatchWorkItem?
    private var bannerWork: DispatchWorkItem?
    private var bannerQueue: [Banner] = []
    private(set) var digest: [String] = [] // what happened while quiet

    init() {
        startSlowTimer()
    }

    // MARK: - Derived

    var sortedSessions: [Session] {
        sessions.values.sorted { a, b in
            // Problems float up: approvals first, then sessions with an alert.
            let pa = priority(a.status) * 2 - (a.alert != nil ? 1 : 0)
            let pb = priority(b.status) * 2 - (b.alert != nil ? 1 : 0)
            return pa != pb ? pa < pb : a.lastEventAt > b.lastEventAt
        }
    }

    var activeCount: Int { sessions.values.filter { $0.status.isWorking }.count }
    var isAnyWorking: Bool { sessions.values.contains { $0.status.isWorking } }
    var primary: Session? { sortedSessions.first }

    /// Everything waiting on you that you haven't looked at, most urgent and oldest first.
    var queue: [Session] {
        sessions.values.filter { s in
            hasApproval(for: s.id) || (!s.attended && s.waitingSince != nil)
        }.sorted { a, b in
            let ra = queueRank(a), rb = queueRank(b)
            if ra != rb { return ra < rb }
            return (a.waitingSince ?? .distantFuture) < (b.waitingSince ?? .distantFuture)
        }
    }

    private func queueRank(_ s: Session) -> Int {
        if hasApproval(for: s.id) { return 0 }
        if s.status == .waitingForInput { return 1 }
        if s.alert != nil { return 2 }
        return 3 // finished, not yet reviewed
    }

    private func priority(_ s: SessionStatus) -> Int {
        switch s {
        case .needsApproval: return 0
        case .tool, .thinking: return 1
        case .waitingForInput: return 2
        case .done: return 3
        case .idle: return 4
        }
    }

    func session(_ id: String) -> Session? { sessions[id] }

    // MARK: - Events from the hook

    func handle(_ e: [String: Any], clientID: SocketServer.ClientID?) {
        guard let sid = e["session_id"] as? String, !sid.isEmpty else {
            if let clientID { sendReply?(clientID, ["behavior": "ask"]) }
            return
        }
        let event = e["hook_event_name"] as? String ?? ""
        let now = Date()

        if event == "SessionEnd" { remove(sessionID: sid); return }
        if event == "StatusLine" { applyStatusLine(e, sid: sid); return }

        let agent = Agent(rawValue: e["_agent"] as? String ?? "") ?? .claude
        DiagLog.log("\(event) \(agent.rawValue) s\(sid.prefix(4))\(clientID != nil ? " waits" : "")")
        var s = sessions[sid] ?? newSession(sid, e)
        s.agent = agent
        updateIdentity(&s, e)
        s.lastEventAt = now

        var needsCodexBaseline = false
        var turnFinished = false
        let tool = e["tool_name"] as? String ?? ""
        let input = e["tool_input"] as? [String: Any] ?? [:]
        if case .stuck = s.alert { s.alert = nil } // any event is progress
        var newAlert: SessionAlert?
        var t = tracking[sid] ?? Tracking()

        switch event {
        case "SessionStart":
            s.status = .idle

        case "UserPromptSubmit":
            beginTurn(&s, &t, prompt: e["prompt"] as? String ?? "", agent: agent, now: now)
            needsCodexBaseline = agent == .codex
            if drafts[sid]?.trimmingCharacters(in: .whitespacesAndNewlines) == s.lastPrompt { drafts[sid] = nil }

        case "PreToolUse":
            s.question = nil
            s.status = .tool(name: tool, detail: ToolInfo.detail(tool: tool, input: input))
            if s.turnStartedAt == nil { s.turnStartedAt = now }
            s.waitingSince = nil
            newAlert = trackCall(&t, &s, tool: tool, input: input, now: now)
            noteEdits(&s, tool: tool, input: input)
            recordStep(&s, tool: tool, input: input, now: now)

        case "PostToolUseFailure":
            let sig = Self.callSignature(tool, input)
            t.failStreak[sig, default: 0] += 1
            let n = t.failStreak[sig] ?? 0
            if n >= 3 { newAlert = .failing(what: Self.callLabel(tool, input), count: n) }
            s.status = .thinking
            if agent == .cursor { recordStep(&s, tool: tool, input: input, now: now) }
            finishStep(&s, tool: tool, ok: false)
            noteOutput(&s, tool: tool, e)

        case "PostToolUse":
            if let pending = approvals.first(where: { $0.sessionID == sid }) {
                s.status = .needsApproval(tool: pending.toolName)
            } else if agent == .cursor && !s.actions.contains(where: { $0.tool == tool && $0.ok == nil }) {
                // A Cursor step we only heard about afterwards (no preToolUse): show it as the latest action.
                s.status = .tool(name: tool, detail: ToolInfo.detail(tool: tool, input: input))
                if s.turnStartedAt == nil { s.turnStartedAt = now }
                newAlert = trackCall(&t, &s, tool: tool, input: input, now: now)
                noteEdits(&s, tool: tool, input: input)
                recordStep(&s, tool: tool, input: input, now: now)
            } else {
                s.status = .thinking
            }
            t.failStreak[Self.callSignature(tool, input)] = nil // it worked
            finishStep(&s, tool: tool, ok: true)
            noteOutput(&s, tool: tool, e)

        case "PermissionRequest":
            tracking[sid] = t
            if handlePermission(&s, agent: agent, tool: tool, input: input, clientID: clientID, now: now) { return }

        case "Notification":
            if !hasApproval(for: sid), s.status != .waitingForInput {
                s.status = .waitingForInput
                s.waitingSince = now; s.attended = false
                if s.question == nil, let m = s.lastMessage { s.question = Self.openQuestion(in: m) }
                showBanner(Banner(kind: .waiting, sessionID: sid, agent: agent,
                                  title: s.question != nil ? "\(s.projectName) has a question 👀" : "\(s.projectName) is waiting on you ✨",
                                  subtitle: s.question.map { "“" + ToolInfo.clip($0, 62) + "”" }
                                      ?? "\(agent.shortName.lowercased()) is all ears. tap to jump in",
                                  important: true))
            }

        case "AgentThought":
            if let h = Narration.headline(e["text"] as? String ?? "") { s.intent = h; s.intentAt = now }

        case "AgentResponse":
            if let m = e["last_assistant_message"] as? String, !m.isEmpty { s.lastMessage = m }

        case "Interrupt":
            s.status = .idle
            s.turnEndedAt = now
            s.alert = nil
            clearApprovals(for: sid)

        case "Stop":
            let failed = (e["status"] as? String).map { $0 == "error" || $0 == "aborted" } ?? false
            if let clientID {
                // You queued a follow-up: hand it to the agent so it carries straight on.
                if !failed, let text = queued[sid]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    queued[sid] = nil
                    sendReply?(clientID, ["behavior": "followup", "text": text])
                    beginTurn(&s, &t, prompt: text, agent: agent, now: now)
                    needsCodexBaseline = agent == .codex
                    showBanner(Banner(kind: .draft, sessionID: sid, agent: agent,
                                      title: "Sent your follow-up to \(s.projectName)",
                                      subtitle: ToolInfo.clip(ToolInfo.firstLine(text), 70), action: .expand))
                    break
                }
                sendReply?(clientID, ["behavior": "none"])
            }
            finishTurn(&s, agent: agent, e: e, now: now)
            s.intent = nil; s.intentAt = nil
            t.recentCalls = []; t.failStreak = [:]
            turnFinished = true

        default:
            break
        }

        if let newAlert, newAlert != s.alert {
            s.alert = newAlert
            raise(newAlert, for: s)
        }
        tracking[sid] = t
        sessions[sid] = s
        if turnFinished { afterTurn(sid) }
        if s.status.isWorking, ["PreToolUse", "PostToolUse", "UserPromptSubmit"].contains(event) {
            refreshNarration(sid, delay: event == "UserPromptSubmit" ? 2 : 0.3)
        }
        // Read Codex usage only after the session is stored (it needs the log path).
        if needsCodexBaseline { refreshCodex(sid: sid, setBaseline: true) }
        else if agent == .codex, event == "PostToolUse" || event == "PreToolUse" { refreshCodex(sid: sid, setBaseline: false) }
        ensureLivenessTimer()
    }

    private func newSession(_ sid: String, _ e: [String: Any]) -> Session {
        let pid = e["_agent_pid"] as? Int ?? e["_claude_pid"] as? Int ?? 0
        return Session(id: sid, cwd: e["cwd"] as? String ?? "", pid: Int32(pid),
                       termProgram: e["_term_program"] as? String ?? "",
                       bundleID: e["_bundle_id"] as? String ?? "")
    }

    /// Where the session runs: folder, process, terminal.
    private func updateIdentity(_ s: inout Session, _ e: [String: Any]) {
        if let cwd = e["cwd"] as? String, !cwd.isEmpty, cwd != s.cwd || s.projectRoot.isEmpty {
            s.cwd = cwd
            s.branch = Git.branch(at: cwd)
            s.projectRoot = Git.root(at: cwd) ?? cwd
            onProjectSeen?(s.projectRoot)
        }
        if let pid = e["_agent_pid"] as? Int ?? e["_claude_pid"] as? Int, pid > 1 { s.pid = Int32(pid) }
        if let b = e["_bundle_id"] as? String, !b.isEmpty { s.bundleID = b }
        if let v = e["_term_program"] as? String, !v.isEmpty { s.termProgram = v }
        if let v = e["transcript_path"] as? String, !v.isEmpty { s.transcriptPath = v }
        if let v = e["_tty"] as? String, !v.isEmpty { s.tty = v }
        if let v = e["_tmux_pane"] as? String, !v.isEmpty { s.tmuxPane = v }
        if let v = e["_tmux"] as? String, !v.isEmpty { s.tmuxSocket = v }
        if let v = e["_iterm_session"] as? String, !v.isEmpty { s.itermSession = v }
    }

    // MARK: - Permissions

    /// Returns true if the request was fully handled (session already stored).
    private func handlePermission(_ s: inout Session, agent: Agent, tool: String, input: [String: Any],
                                  clientID: SocketServer.ClientID?, now: Date) -> Bool {
        let sid = s.id
        guard let clientID else {
            s.status = .waitingForInput // e.g. AskUserQuestion — answered in the agent's own UI
            s.waitingSince = now; s.attended = false
            s.question = Self.question(tool: tool, input: input)
            return false
        }
        if agent == .cursor, !cursorApprovalsEnabled() {
            sendReply?(clientID, ["behavior": "ask"])
            s.status = .tool(name: tool, detail: ToolInfo.detail(tool: tool, input: input))
            return false
        }
        let project = s.projectRoot.isEmpty ? s.cwd : s.projectRoot
        if let reason = autoAllow(agent: agent, project: project, tool: tool, input: input) {
            sendReply?(clientID, ["behavior": "allow"])
            if case let .rule(r) = reason { rules.noteUse(r) }
            s.autoAllowed += 1
            ledger.autoAllowed()
            s.status = .tool(name: tool, detail: ToolInfo.detail(tool: tool, input: input))
            noteEdits(&s, tool: tool, input: input)
            sessions[sid] = s
            return true
        }
        var approval = Approval(clientID: clientID, sessionID: sid, toolName: tool,
                                detail: ToolInfo.detail(tool: tool, input: input),
                                preview: ToolInfo.preview(tool: tool, input: input),
                                risky: ToolInfo.isRisky(tool: tool, input: input))
        approval.project = project
        approval.trustable = TrustPolicy.trustCovers(tool: tool, input: input, project: project)
        if !approval.risky, let c = RuleStore.candidate(tool: tool, input: input) {
            approval.candidate = AllowCandidate(agent: agent, project: project, tool: c.tool, pattern: c.pattern)
            approval.timesAllowed = rules.timesAllowed(agent: agent, project: project, tool: c.tool, pattern: c.pattern)
            approval.offerAlways = approval.timesAllowed >= RuleStore.suggestAfter
        }
        approvals.append(approval)
        s.status = .needsApproval(tool: tool)
        if s.waitingSince == nil { s.waitingSince = now }
        s.attended = false
        sessions[sid] = s
        onNewApproval?()
        ensureLivenessTimer()
        return true
    }

    /// Rules first, then a trust window, then the read-only defaults. Never for risky requests.
    func autoAllow(agent: Agent, project: String, tool: String, input: [String: Any]) -> AutoAllowReason? {
        guard !ToolInfo.isRisky(tool: tool, input: input) else { return nil }
        if let r = rules.match(agent: agent, project: project, tool: tool, input: input) { return .rule(r) }
        if trust.isTrusted(project), TrustPolicy.trustCovers(tool: tool, input: input, project: project) { return .trust }
        if readOnlyDefaults(), TrustPolicy.isReadOnly(tool: tool, input: input) { return .readOnly }
        return nil
    }

    enum Decision: Equatable { case allow, always, trust(minutes: Int), deny, terminal }

    func decide(_ approval: Approval, _ decision: Decision) {
        guard let idx = approvals.firstIndex(of: approval) else { return }
        DiagLog.log("decided \(decision) for \(approval.toolName)\(approval.risky ? " (risky)" : "")")
        approvals.remove(at: idx)
        switch decision {
        case .allow, .always, .trust:
            sendReply?(approval.clientID, ["behavior": "allow"])
            ledger.approval(allowed: true)
            if let c = approval.candidate {
                if decision == .always {
                    rules.add(agent: c.agent, project: c.project, tool: c.tool, pattern: c.pattern)
                } else {
                    rules.recordAllow(agent: c.agent, project: c.project, tool: c.tool, pattern: c.pattern)
                }
            }
            if case let .trust(minutes) = decision, let p = approval.project {
                trust.trust(project: p, minutes: minutes)
                settleTrusted(project: p)
            }
            if var s = sessions[approval.sessionID] {
                s.status = .tool(name: approval.toolName, detail: approval.detail)
                if !hasApproval(for: s.id) { s.waitingSince = nil }
                sessions[approval.sessionID] = s
            }
        case .deny:
            sendReply?(approval.clientID, ["behavior": "deny", "message": "The user denied this from NotchBar."])
            ledger.approval(allowed: false)
            restoreStatusAfterApproval(sessionID: approval.sessionID)
        case .terminal:
            sendReply?(approval.clientID, ["behavior": "ask"])
            if var s = sessions[approval.sessionID] {
                s.status = .waitingForInput
                sessions[approval.sessionID] = s
            }
        }
    }

    /// Allow every pending non-risky request from one session at once.
    func allowAll(sessionID: String) {
        for a in approvals where a.sessionID == sessionID && !a.risky { decide(a, .allow) }
    }

    /// Other pending requests a new trust window now covers get allowed too.
    private func settleTrusted(project: String) {
        for a in approvals where a.project == project && a.trustable && !a.risky { decide(a, .allow) }
    }

    // MARK: - Turn bookkeeping

    private func finishTurn(_ s: inout Session, agent: Agent, e: [String: Any], now: Date) {
        let failed = (e["status"] as? String).map { $0 == "error" || $0 == "aborted" } ?? false
        s.status = failed ? .idle : .done
        s.turnEndedAt = now
        s.lastTask = receipt(for: s, endedAt: now)
        s.alert = nil
        if let m = e["last_assistant_message"] as? String, !m.isEmpty { s.lastMessage = m }
        s.waitingSince = now; s.attended = false
        clearApprovals(for: s.id)
        if !failed { flashDone() }
        onTurnDone?()

        let hasDraft = drafts[s.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasDraft {
            showBanner(Banner(kind: .draft, sessionID: s.id, agent: agent,
                              title: "\(s.projectName) is done and your next prompt is ready",
                              subtitle: ToolInfo.clip(ToolInfo.firstLine(drafts[s.id] ?? ""), 60),
                              action: .sendDraft, important: true))
        } else {
            let subject = s.lastMessage.map { ToolInfo.firstLine(Self.plain($0)) }
                ?? (s.lastPrompt.isEmpty ? agent.name : ToolInfo.firstLine(s.lastPrompt))
            showBanner(Banner(kind: failed ? .failed : .done, sessionID: s.id, agent: agent,
                              title: failed ? "\(s.projectName) stopped" : "\(s.projectName) is done",
                              subtitle: ToolInfo.clip(subject, 70)))
        }
    }

    /// Work that reads files after a turn ends.
    private func afterTurn(_ sid: String) {
        fillTokens(sid: sid)
        guard let s = sessions[sid], s.agent == .claude, s.lastMessage == nil, let tp = s.transcriptPath else { return }
        io.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let msg = UsageReader.claudeLastMessage(transcript: tp)
            DispatchQueue.main.async {
                guard let self, let msg, var cur = self.sessions[sid], cur.lastMessage == nil else { return }
                cur.lastMessage = msg
                self.sessions[sid] = cur
            }
        }
    }

    /// Markdown-ish text → one readable line.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Live activity

    private static let planTools: Set<String> = ["TodoWrite", "TaskCreate", "TaskUpdate", "update_plan"]

    /// A step started: remember it (for the trail and past-tense status) and read plan updates.
    private func recordStep(_ s: inout Session, tool: String, input: [String: Any], now: Date) {
        s.steps += 1
        if Self.planTools.contains(tool) {
            PlanParser.apply(tool: tool, input: input, to: &s.plan)
            return
        }
        guard !["ToolSearch", "AskUserQuestion", "ExitPlanMode"].contains(tool) else { return }
        let phase = Phase.of(tool: tool, input: input)
        s.actions.append(ActionRecord(tool: tool, detail: ToolInfo.detail(tool: tool, input: input),
                                      phase: phase, at: now))
        if tool == "Bash" { ledger.command() }
        if s.actions.count > 8 { s.actions.removeFirst(s.actions.count - 8) }
    }

    private func finishStep(_ s: inout Session, tool: String, ok: Bool) {
        guard let i = s.actions.lastIndex(where: { $0.tool == tool && $0.ok == nil }) else { return }
        s.actions[i].ok = ok
    }

    /// Picks up the agent's own words about what it's doing (throttled, off-main).
    private func refreshNarration(_ sid: String, delay: TimeInterval) {
        guard let s = sessions[sid] else { return }
        // Sessions already running when NotchBar started have no known turn start:
        // look back 10 minutes instead.
        let since = s.turnStartedAt ?? Date().addingTimeInterval(-600)
        if s.agent == .codex { refreshCodex(sid: sid, setBaseline: false); return }
        guard s.agent == .claude, let tp = s.transcriptPath else { return }
        let now = Date()
        if let last = narrationAt[sid], now.timeIntervalSince(last) < 2 { return }
        narrationAt[sid] = now
        io.asyncAfter(deadline: .now() + delay) { [weak self] in
            let n = UsageReader.claudeNarration(transcript: tp, since: since)
            DispatchQueue.main.async {
                // Ignore results from an older turn or ones that change nothing.
                guard let self, let n, var cur = self.sessions[sid], cur.turnStartedAt == since,
                      cur.intent != n.text || cur.intentAt != n.at else { return }
                cur.intent = n.text
                cur.intentAt = n.at
                self.sessions[sid] = cur
            }
        }
    }

    private func noteEdits(_ s: inout Session, tool: String, input: [String: Any]) {
        let files = EditedFiles.paths(tool: tool, input: input, cwd: s.cwd)
        guard !files.isEmpty else { return }
        let live = Set(sessions.keys).union([s.id])
        for f in files {
            ledger.file(f)
            if !s.editedFiles.contains(f) { s.editedFiles.append(f) }
            if let c = conflicts.record(file: f, session: s.id, liveSessions: live),
               let other = sessions[c.otherSession] {
                let name = (f as NSString).lastPathComponent
                showBanner(Banner(kind: .attention, sessionID: s.id, agent: s.agent,
                                  title: "Two agents are editing \(name)",
                                  subtitle: "\(s.agent.shortName) in \(s.projectName) · \(other.agent.shortName) in \(other.projectName)",
                                  important: true))
            }
        }
        if s.editedFiles.count > 200 { s.editedFiles.removeFirst(s.editedFiles.count - 200) }
    }

    private func noteOutput(_ s: inout Session, tool: String, _ e: [String: Any]) {
        guard tool == "Bash", let tail = e["_output_tail"] as? String, let r = TestParser.parse(tail) else { return }
        s.testResult = r
        ledger.tests(passed: r.passed, failed: r.failed)
        if let i = s.actions.lastIndex(where: { $0.tool == "Bash" }) {
            s.actions[i].note = r.short
            s.actions[i].ok = r.failed == 0
        }
    }

    // MARK: - Attention queue

    /// Mark a session as looked at (it leaves the queue until it needs you again).
    func attend(_ sid: String) {
        guard var s = sessions[sid], !s.attended else { return }
        s.attended = true
        if s.status == .done { s.waitingSince = nil }
        sessions[sid] = s
    }

    func jump(to sid: String) {
        guard let s = sessions[sid] else { return }
        TerminalJump.jump(to: s)
        attend(sid)
    }

    // MARK: - Drafts

    /// What a blocked tool is asking (AskUserQuestion's question, or a plan to review).
    static func question(tool: String, input: [String: Any]) -> String? {
        switch tool {
        case "AskUserQuestion":
            let qs = input["questions"] as? [[String: Any]] ?? []
            return (qs.first?["question"] as? String).map { ToolInfo.clip($0, 110) }
        case "ExitPlanMode":
            return "Plan ready for your review"
        default:
            return nil
        }
    }

    /// The question an agent ended its reply with, if any ("Should I also update the docs?").
    static func openQuestion(in message: String) -> String? {
        let text = plain(message)
        guard let q = text.range(of: "?", options: .backwards) else { return nil }
        // Walk back to the start of that sentence.
        let head = text[..<q.lowerBound]
        let start = head.lastIndex(where: { ".!?\n".contains($0) }).map { head.index(after: $0) } ?? head.startIndex
        var sentence = String(text[start..<q.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Ignore questions buried far back in a long answer.
        guard text.distance(from: q.upperBound, to: text.endIndex) < 220, sentence.count >= 8 else { return nil }
        while sentence.hasPrefix("-") || sentence.hasPrefix("*") { sentence = String(sentence.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return ToolInfo.clip(sentence, 110)
    }

    /// Starts a fresh turn (from a typed prompt or a delivered follow-up).
    private func beginTurn(_ s: inout Session, _ t: inout Tracking, prompt: String, agent: Agent, now: Date) {
        s.status = .thinking
        s.lastPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        s.turnStartedAt = now
        s.turnEndedAt = nil
        clearApprovals(for: s.id) // a new turn means any old request is stale
        // Fresh turn: reset per-turn state and take usage baselines.
        s.lastTask = nil; s.lastMessage = nil; s.editedFiles = []; s.testResult = nil; s.question = nil
        s.alert = nil; s.autoAllowed = 0
        s.intent = nil; s.intentAt = nil; s.actions = []; s.steps = 0
        if s.plan.allSatisfy({ $0.status == .done }) { s.plan = [] } // finished plans don't carry over
        s.waitingSince = nil; s.attended = false
        t.recentCalls = []; t.failStreak = [:]
        s.costAtTurnStart = s.costTotal
        s.linesAddedAtTurnStart = s.linesAddedTotal
        s.linesRemovedAtTurnStart = s.linesRemovedTotal
        s.tokensAtTurnStart = nil
        if agent == .claude, let tp = s.transcriptPath { s.transcriptOffsetAtTurnStart = UsageReader.fileSize(tp) }
    }

    /// Is the agent mid-turn (so a follow-up should wait for it to finish)?
    func isBusy(_ s: Session) -> Bool {
        if s.status.isWorking { return true }
        if case .needsApproval = s.status { return true }
        return false
    }

    /// Queue a follow-up: the agent receives it the moment it finishes this turn.
    func queue(_ sid: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queued[sid] = t
        drafts[sid] = nil
    }

    func cancelQueued(_ sid: String) {
        guard let t = queued.removeValue(forKey: sid) else { return }
        drafts[sid] = t // back into the box, nothing lost
    }

    /// Send your draft: queue it if the agent is busy, otherwise deliver it now.
    func sendDraft(_ sid: String) {
        guard let s = sessions[sid], let text = drafts[sid]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        if isBusy(s) { queue(sid, text); return }
        drafts[sid] = nil
        attend(sid)
        TerminalJump.submit(text, to: s, pasteAllowed: autoPaste()) { [weak self] outcome in
            guard let self else { return }
            let title: String, sub: String
            switch outcome {
            case .typed:
                title = "Sent to \(s.projectName)"; sub = ToolInfo.clip(ToolInfo.firstLine(text), 70)
            case .pasted:
                title = "Pasted into \(s.projectName). Press Return to send"; sub = "This terminal can't be typed into directly"
            case .copied:
                title = "Copied. Paste it into \(s.projectName)"; sub = "Grant Accessibility in Settings to paste automatically"
            }
            self.showBanner(Banner(kind: .draft, sessionID: s.id, agent: s.agent, title: title, subtitle: sub,
                                   action: .jump, important: outcome != .typed))
        }
    }

    func copyAndJump(_ text: String, sid: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        jump(to: sid)
    }

    // MARK: - Day ledger

    /// Finished turns (and their late-arriving tokens and cost) go to today's receipt.
    private func syncLedger(_ old: [String: Session]) {
        for (sid, s) in sessions where s.status == .done {
            guard let r = s.lastTask, let ended = s.turnEndedAt else { continue }
            if let o = old[sid], o.status == .done, o.lastTask == r, o.turnEndedAt == ended { continue }
            ledger.turn(key: "\(sid)#\(Int(ended.timeIntervalSince1970))", agent: s.agent,
                        project: s.projectName, receipt: r, endedAt: ended)
        }
    }

    // MARK: - Usage

    private func receipt(for s: Session, endedAt: Date) -> TaskReceipt {
        var r = TaskReceipt(duration: endedAt.timeIntervalSince(s.turnStartedAt ?? endedAt))
        if let total = s.costTotal { r.costUSD = max(0, total - (s.costAtTurnStart ?? 0)) }
        if let a = s.linesAddedTotal { r.linesAdded = max(0, a - (s.linesAddedAtTurnStart ?? 0)) }
        if let d = s.linesRemovedTotal { r.linesRemoved = max(0, d - (s.linesRemovedAtTurnStart ?? 0)) }
        return r
    }

    /// Token count for the finished turn, read from the agent's log off-main.
    private func fillTokens(sid: String) {
        guard let s = sessions[sid] else { return }
        if s.agent == .codex { refreshCodex(sid: sid, setBaseline: false, force: true); return }
        guard s.agent == .claude, let tp = s.transcriptPath, let offset = s.transcriptOffsetAtTurnStart else { return }
        io.async { [weak self] in
            let tokens = UsageReader.claudeTokens(transcript: tp, from: offset)
            DispatchQueue.main.async {
                guard let self, var cur = self.sessions[sid], cur.status == .done, let tokens else { return }
                cur.lastTask?.tokens = tokens
                self.sessions[sid] = cur
            }
        }
    }

    /// Claude Code's statusline payload: model, context, running cost, plan limits.
    private func applyStatusLine(_ e: [String: Any], sid: String) {
        // Claude reruns the statusline several times a second while working;
        // most runs carry identical numbers, so drop them before they touch the UI.
        // The statusline also ticks while Claude writes a long reply — a good moment
        // to pick up its latest narration (throttled inside).
        if sessions[sid]?.status.isWorking == true { refreshNarration(sid, delay: 0.2) }
        let sig = Self.statusSignature(e)
        if lastStatusSig[sid] == sig, sessions[sid] != nil { return }
        lastStatusSig[sid] = sig
        let before = sessions[sid]
        var s = sessions[sid] ?? newSession(sid, e)
        updateIdentity(&s, e)
        s.model = (e["model"] as? [String: Any])?["display_name"] as? String ?? s.model
        if let ctx = (e["context_window"] as? [String: Any])?["used_percentage"] as? Double {
            s.contextPercent = ctx
            checkContext(s)
        }
        if let cost = e["cost"] as? [String: Any] {
            if let c = cost["total_cost_usd"] as? Double { s.costTotal = c }
            if let a = cost["total_lines_added"] as? Int { s.linesAddedTotal = a }
            if let d = cost["total_lines_removed"] as? Int { s.linesRemovedTotal = d }
        }
        // A statusline refresh can land just after Stop: fold it into the receipt.
        if s.status == .done, let ended = s.turnEndedAt, Date().timeIntervalSince(ended) < 30, var r = s.lastTask {
            let fresh = receipt(for: s, endedAt: ended)
            r.costUSD = fresh.costUSD; r.linesAdded = fresh.linesAdded; r.linesRemoved = fresh.linesRemoved
            s.lastTask = r
        }
        if s != before { sessions[sid] = s }
        ensureLivenessTimer()

        if let rl = e["rate_limits"] as? [String: Any] {
            var windows: [UsageWindow] = []
            for (key, label) in [("five_hour", "5h"), ("seven_day", "Week")] {
                guard let w = rl[key] as? [String: Any], let used = w["used_percentage"] as? Double else { continue }
                let reset = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                windows.append(UsageWindow(label: label, usedPercent: used, resetsAt: reset))
            }
            if !windows.isEmpty { updateLimits(.claude, windows) }
        }
    }

    private static func statusSignature(_ e: [String: Any]) -> String {
        var parts: [String] = []
        for k in ["model", "context_window", "cost", "rate_limits", "transcript_path", "cwd"] {
            if let v = e[k], let d = try? JSONSerialization.data(withJSONObject: ["v": v], options: .sortedKeys) {
                parts.append(String(decoding: d, as: UTF8.self))
            }
        }
        return parts.joined(separator: "|")
    }

    /// Reads the Codex rollout tail (throttled) for tokens, context and limits.
    private func refreshCodex(sid: String, setBaseline: Bool, force: Bool = false) {
        guard let tp = sessions[sid]?.transcriptPath else { return }
        let since = sessions[sid]?.turnStartedAt
        let now = Date()
        if !force && !setBaseline, let last = codexRefreshAt[sid], now.timeIntervalSince(last) < 3 { return }
        codexRefreshAt[sid] = now
        // Codex appends its token_count shortly after the hook fires.
        io.asyncAfter(deadline: .now() + (setBaseline ? 0 : 0.8)) { [weak self] in
            let snap = UsageReader.codex(rollout: tp, since: since)
            DispatchQueue.main.async {
                guard let self, let snap, var s = self.sessions[sid] else { return }
                if let n = snap.narration, s.status.isWorking { s.intent = n.text; s.intentAt = n.at }
                if let plan = snap.plan, !plan.isEmpty { s.plan = plan }
                if let ctx = snap.contextPercent { s.contextPercent = ctx; self.checkContext(s) }
                if setBaseline, snap.hasUsage { s.tokensAtTurnStart = snap.totalTokens }
                if s.status == .done, snap.hasUsage, let base = s.tokensAtTurnStart {
                    s.lastTask?.tokens = max(0, snap.totalTokens - base)
                }
                self.sessions[sid] = s
                if snap.hasUsage, !snap.windows.isEmpty { self.updateLimits(.codex, snap.windows) }
            }
        }
    }

    private func updateLimits(_ agent: Agent, _ windows: [UsageWindow]) {
        let previous = limits[agent] ?? []
        forecast.record(agent, windows)
        guard windows != previous else { return }
        limits[agent] = windows
        Self.saveLimits(limits)
        for w in windows {
            // Warn once per window when it crosses 80% and again at 95%.
            let before = previous.first { $0.label == w.label }?.usedPercent ?? w.usedPercent
            for threshold in [80.0, 95.0] where w.usedPercent >= threshold && before < threshold {
                guard once("limit-\(agent.rawValue)-\(w.label)-\(resetKey(w))-\(Int(threshold))") else { continue }
                showBanner(Banner(kind: .limit(critical: threshold >= 95), sessionID: "", agent: agent,
                                  title: "\(agent.shortName) \(Self.windowName(w)) limit at \(Int(w.usedPercent))%",
                                  subtitle: alternativeHint(for: agent) ?? w.resetsAt.map { "Resets \(Fmt.reset($0))" } ?? "",
                                  action: .expand, important: threshold >= 95))
            }
            // Forecast: at this pace you'll run out within the hour.
            if nudgesEnabled(), let eta = forecast.fullAt(agent, w), eta.timeIntervalSinceNow < 60 * 60,
               once("forecast-\(agent.rawValue)-\(w.label)-\(resetKey(w))") {
                showBanner(Banner(kind: .limit(critical: false), sessionID: "", agent: agent,
                                  title: "\(agent.shortName) \(Self.windowName(w)) limit full by \(Fmt.clock(eta)) at this pace",
                                  subtitle: alternativeHint(for: agent) ?? "Resets \(Fmt.reset(w.resetsAt))",
                                  action: .expand))
            }
        }
    }

    static func windowName(_ w: UsageWindow) -> String { w.label == "5h" ? "5-hour" : w.label.lowercased() }
    private func resetKey(_ w: UsageWindow) -> Int { Int(w.resetsAt?.timeIntervalSince1970 ?? 0) }

    /// "Codex has 89% left" — another connected agent with room to spare.
    func alternativeHint(for agent: Agent) -> String? {
        let candidates = activeLimits.filter { $0.0 != agent }.compactMap { (a, ws) -> (Agent, Double)? in
            guard let worst = ws.map(\.usedPercent).max(), worst < 60 else { return nil }
            return (a, 100 - worst)
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        return "\(best.0.shortName) still has \(Int(best.1))% left, so send the next task there"
    }

    /// Limits that are still valid (drops windows whose reset time has passed).
    var activeLimits: [(Agent, [UsageWindow])] {
        Agent.allCases.compactMap { a in
            let w = (limits[a] ?? []).filter { !$0.isExpired }
            return w.isEmpty ? nil : (a, w)
        }
    }

    /// Context nearly full: suggest a fresh start before quality drops.
    private func checkContext(_ s: Session) {
        guard let pct = s.contextPercent else { return }
        var t = tracking[s.id] ?? Tracking()
        if pct < 75 { t.contextWarned = false; tracking[s.id] = t; return }
        guard pct >= 85, !t.contextWarned, nudgesEnabled() else { return }
        t.contextWarned = true
        tracking[s.id] = t
        let compact = s.agent == .claude ? "/compact" : (s.agent == .codex ? "/compact" : "")
        showBanner(Banner(kind: .info, sessionID: s.id, agent: s.agent,
                          title: "\(s.projectName) context is \(Int(pct))% full",
                          subtitle: compact.isEmpty ? "Consider starting a fresh chat" : "Tap to copy \(compact), or start a fresh session",
                          action: compact.isEmpty ? .jump : .copyAndJump(compact)))
    }

    /// Unused plan capacity that's about to reset.
    private func checkUseItOrLoseIt() {
        guard nudgesEnabled() else { return }
        for (agent, windows) in activeLimits {
            guard !sessions.values.contains(where: { $0.agent == agent && $0.status.isWorking }) else { continue }
            for w in windows {
                guard let reset = w.resetsAt else { continue }
                let left = reset.timeIntervalSinceNow
                guard left > 5 * 60, left <= 45 * 60, w.usedPercent < 60,
                      once("useit-\(agent.rawValue)-\(w.label)-\(resetKey(w))") else { continue }
                showBanner(Banner(kind: .info, sessionID: "", agent: agent,
                                  title: "\(100 - Int(w.usedPercent))% of \(agent.shortName)'s \(Self.windowName(w)) window unused",
                                  subtitle: "Resets \(Fmt.reset(reset)). A good moment for tests, refactors or docs",
                                  action: .expand))
            }
        }
    }

    private static func loadLimits() -> [Agent: [UsageWindow]] {
        guard let data = UserDefaults.standard.data(forKey: "limits"),
              let raw = try? JSONDecoder().decode([String: [UsageWindow]].self, from: data) else { return [:] }
        var out: [Agent: [UsageWindow]] = [:]
        for (k, v) in raw { if let a = Agent(rawValue: k) { out[a] = v } }
        return out
    }

    private static func saveLimits(_ l: [Agent: [UsageWindow]]) {
        let raw = Dictionary(uniqueKeysWithValues: l.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { UserDefaults.standard.set(data, forKey: "limits") }
    }

    /// True the first time a key is seen (bounded memory).
    private func once(_ key: String) -> Bool {
        if alertedKeys.count > 1000 { alertedKeys.removeAll() }
        return alertedKeys.insert(key).inserted
    }

    // MARK: - Session list maintenance

    /// Hook went away while waiting (timeout, or answered in the terminal).
    func clientDisconnected(_ id: SocketServer.ClientID) {
        guard let idx = approvals.firstIndex(where: { $0.clientID == id }) else { return }
        let a = approvals.remove(at: idx)
        restoreStatusAfterApproval(sessionID: a.sessionID)
    }

    /// Pick up sessions that were already running before NotchBar launched.
    func seedFromClaudeSessionFiles() {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = j["sessionId"] as? String,
                  let pid = j["pid"] as? Int, pid > 1, kill(pid_t(pid), 0) == 0,
                  (j["kind"] as? String ?? "interactive") == "interactive",
                  sessions[sid] == nil
            else { continue }
            let cwd = j["cwd"] as? String ?? ""
            var s = Session(id: sid, cwd: cwd, pid: Int32(pid), termProgram: "", bundleID: "")
            s.branch = Git.branch(at: cwd)
            s.projectRoot = Git.root(at: cwd) ?? cwd
            onProjectSeen?(s.projectRoot)
            if let ms = j["updatedAt"] as? Double { s.lastEventAt = Date(timeIntervalSince1970: ms / 1000) }
            // Only trust "busy" if it's fresh; otherwise we'd spin forever on a stale file.
            let fresh = Date().timeIntervalSince(s.lastEventAt) < 120
            s.status = (j["status"] as? String) == "busy" && fresh ? .thinking : .idle
            sessions[sid] = s
        }
        ensureLivenessTimer()
    }

    func remove(sessionID: String) {
        lastStatusSig[sessionID] = nil
        narrationAt[sessionID] = nil
        queued[sessionID] = nil
        tracking[sessionID] = nil
        codexRefreshAt[sessionID] = nil
        conflicts.forget(session: sessionID)
        clearApprovals(for: sessionID)
        sessions[sessionID] = nil
        ensureLivenessTimer()
    }

    private func hasApproval(for sid: String) -> Bool { approvals.contains { $0.sessionID == sid } }

    private func clearApprovals(for sid: String) {
        let stale = approvals.filter { $0.sessionID == sid }
        guard !stale.isEmpty else { return }
        for a in stale { sendReply?(a.clientID, ["behavior": "ask"]) }
        approvals.removeAll { $0.sessionID == sid }
    }

    private func restoreStatusAfterApproval(sessionID: String) {
        guard var s = sessions[sessionID] else { return }
        if let next = approvals.first(where: { $0.sessionID == sessionID }) {
            s.status = .needsApproval(tool: next.toolName)
        } else if case .needsApproval = s.status {
            s.status = .thinking
            s.waitingSince = nil
        }
        sessions[sessionID] = s
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    // MARK: - Banners

    func dismissBanner() {
        bannerWork?.cancel()
        banner = nil
        showNextBanner()
    }

    /// Banners queue up instead of overwriting each other. In quiet mode
    /// (a meeting) only important ones show; the rest go into a digest.
    func showBanner(_ b: Banner) {
        if isQuiet() && !b.important {
            digest.append(b.title)
            if digest.count > 50 { digest.removeFirst() }
            return
        }
        if banner == nil {
            present(b)
        } else {
            bannerQueue.removeAll { $0.sessionID == b.sessionID && !b.sessionID.isEmpty && $0.kind == b.kind }
            bannerQueue.append(b)
            if bannerQueue.count > 5 { bannerQueue.removeFirst() }
        }
    }

    private func present(_ b: Banner) {
        DiagLog.log("banner \(b.kind)")
        bannerWork?.cancel()
        banner = b
        let work = DispatchWorkItem { [weak self] in
            self?.banner = nil
            self?.showNextBanner()
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (b.action == .sendDraft ? 8 : 3.6), execute: work)
    }

    private func showNextBanner() {
        guard banner == nil, !bannerQueue.isEmpty else { return }
        let next = bannerQueue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.banner == nil else { self?.bannerQueue.insert(next, at: 0); return }
            self.present(next)
        }
    }

    /// Called when a meeting ends: one banner summarising what happened.
    func flushDigest(context: String) {
        guard !digest.isEmpty else { return }
        let count = digest.count
        let first = digest.first ?? ""
        digest.removeAll()
        showBanner(Banner(kind: .info, sessionID: "", agent: .claude,
                          title: "While you were in \(context): \(count) update\(count == 1 ? "" : "s")",
                          subtitle: first, action: .expand, important: true))
    }

    private func flashDone() {
        doneFlashWork?.cancel()
        doneFlash = true
        let work = DispatchWorkItem { [weak self] in self?.doneFlash = false }
        doneFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: - Timers

    /// Liveness/stuck checks every 30s — only while sessions exist.
    private func ensureLivenessTimer() {
        if sessions.isEmpty {
            livenessTimer?.invalidate()
            livenessTimer = nil
            return
        }
        guard livenessTimer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.pruneDead() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        livenessTimer = t
    }

    /// Once a minute (with generous tolerance so macOS can batch it): nudges and housekeeping.
    private func startSlowTimer() {
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkUseItOrLoseIt()
            self.conflicts.prune()
        }
        t.tolerance = 20
        RunLoop.main.add(t, forMode: .common)
        slowTimer = t
    }

    // MARK: - Health (stuck / looping)

    static func callSignature(_ tool: String, _ input: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys)) ?? Data()
        return tool + ":" + String(d.hashValue)
    }

    static func callLabel(_ tool: String, _ input: [String: Any]) -> String {
        let detail = ToolInfo.detail(tool: tool, input: input)
        return detail.isEmpty ? ToolInfo.displayName(tool) : detail
    }

    /// Same call ≥4 times within 10 minutes looks like a loop.
    private func trackCall(_ t: inout Tracking, _ s: inout Session, tool: String, input: [String: Any],
                           now: Date) -> SessionAlert? {
        let sig = Self.callSignature(tool, input)
        t.recentCalls.append((sig, now))
        t.recentCalls.removeAll { now.timeIntervalSince($0.at) > 600 }
        if t.recentCalls.count > 40 { t.recentCalls.removeFirst(t.recentCalls.count - 40) }
        let n = t.recentCalls.filter { $0.sig == sig }.count
        if n >= 4 { return .looping(what: Self.callLabel(tool, input), count: n) }
        if case .looping = s.alert { s.alert = nil } // moved on to something else
        return nil
    }

    private func raise(_ alert: SessionAlert, for s: Session) {
        let title: String
        switch alert {
        case .stuck: title = "\(s.projectName) may be stuck"
        case .looping: title = "\(s.projectName) is going in circles"
        case .failing: title = "\(s.projectName) keeps failing"
        }
        showBanner(Banner(kind: .attention, sessionID: s.id, agent: s.agent, title: title,
                          subtitle: alert.detail, important: true))
    }

    /// Working sessions with no hook events and no log growth for a while.
    private func checkStuck() {
        let now = Date()
        for var s in sessions.values where s.status.isWorking && !hasApproval(for: s.id) {
            var last = s.lastEventAt
            if let tp = s.transcriptPath,
               let m = (try? FileManager.default.attributesOfItem(atPath: tp))?[.modificationDate] as? Date {
                last = max(last, m)
            }
            var limit: TimeInterval = 6 * 60
            if case let .tool(name, _) = s.status, ["Bash", "Task", "Agent"].contains(name) { limit = 15 * 60 }
            let quiet = now.timeIntervalSince(last)
            if quiet > limit {
                let alert = SessionAlert.stuck(minutes: Int(quiet / 60))
                let isNew: Bool = { if case .stuck = s.alert { return false }; return true }()
                if s.alert != alert {
                    s.alert = alert
                    if isNew { s.waitingSince = now; s.attended = false }
                    sessions[s.id] = s
                    if isNew { raise(alert, for: s) }
                }
            } else if case .stuck = s.alert {
                s.alert = nil
                sessions[s.id] = s
            }
        }
    }

    #if DEBUG
    /// Test hook: pretend a session has been silent for `minutes`, then run the stuck check.
    func debugAge(_ sid: String, minutes: Double) {
        guard var s = sessions[sid] else { return }
        s.lastEventAt = Date().addingTimeInterval(-minutes * 60)
        s.transcriptPath = nil
        sessions[sid] = s
        checkStuck()
    }
    #endif

    private func pruneDead() {
        checkStuck()
        for s in sessions.values where s.pid > 1 && kill(s.pid, 0) != 0 && errno == ESRCH {
            remove(sessionID: s.id)
        }
        // Sessions we can't track by pid (Cursor, or pid unknown): forget them
        // after a quiet spell — 30 min when idle, 3 h if they looked busy.
        let now = Date()
        for s in sessions.values where s.pid <= 1 && !hasApproval(for: s.id) && drafts[s.id] == nil {
            let quiet = now.timeIntervalSince(s.lastEventAt)
            if quiet > (s.status.isWorking ? 3 * 3600 : 30 * 60) { remove(sessionID: s.id) }
        }
    }
}

enum Git {
    /// Folder containing `.git` (the project root), walking up from `path`.
    static func root(at path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var dir = URL(fileURLWithPath: path)
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir.path }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Reads the current branch straight from .git/HEAD (no `git` process).
    static func branch(at path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var dir = URL(fileURLWithPath: path)
        let fm = FileManager.default
        for _ in 0..<12 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue,
                   let txt = try? String(contentsOf: dotGit, encoding: .utf8),
                   let line = txt.split(separator: "\n").first, line.hasPrefix("gitdir:") {
                    let p = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    gitDir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                else { return nil }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.hasPrefix("ref: refs/heads/") { return String(h.dropFirst(16)) }
                return String(h.prefix(7))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
