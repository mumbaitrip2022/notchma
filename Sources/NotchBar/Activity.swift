import Foundation

/// One step of the agent's own to-do list (Claude TodoWrite/TaskCreate, Codex plan).
struct PlanItem: Equatable, Identifiable {
    enum Status: Equatable { case pending, active, done }
    var id: String
    var text: String           // imperative: "Run the tests"
    var activeText: String?    // present continuous: "Running the tests"
    var status: Status
}

/// Something the agent did this turn.
struct ActionRecord: Equatable, Identifiable {
    let id = UUID()
    let tool: String
    let detail: String
    let phase: Phase
    let at: Date
    var ok: Bool?
    var note: String?          // e.g. "✓ 24 passed"

    static func == (a: ActionRecord, b: ActionRecord) -> Bool {
        a.id == b.id && a.ok == b.ok && a.note == b.note
    }

    /// "Edited cart.ts", "Ran npm test · ✓ 24 passed".
    var pastTense: String {
        let base = phase.pastVerb(tool: tool) + (detail.isEmpty ? "" : " " + detail)
        if let note { return base + " · " + note }
        if ok == false { return base + " · failed" }
        return base
    }
}

/// What kind of work a step is — drives the verb and the icon.
enum Phase: Equatable {
    case explore, edit, test, build, install, git, run, web, delegate, plan, tool

    static func of(tool: String, input: [String: Any]) -> Phase {
        switch tool {
        case "Read", "Grep", "Glob", "LS", "NotebookRead": return .explore
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": return .edit
        case "WebFetch", "WebSearch": return .web
        case "Task", "Agent": return .delegate
        case "TodoWrite", "TaskCreate", "TaskUpdate", "update_plan": return .plan
        case "Bash":
            let cmd = ToolInfo.unwrapShell(input["command"] as? String ?? "").lowercased()
            return Phase.ofCommand(cmd)
        default: return .tool
        }
    }

    static func ofCommand(_ cmd: String) -> Phase {
        let first = cmd.split(separator: " ").first.map(String.init) ?? ""
        let testWords = ["test", "jest", "vitest", "pytest", "rspec", "phpunit", "mocha", "playwright", "cypress"]
        if testWords.contains(where: { cmd.contains($0) }) && !cmd.contains("install") { return .test }
        if first == "git" || first == "gh" { return .git }
        if cmd.contains(" install") || cmd.hasPrefix("brew ") || cmd.contains(" add ") && ["npm", "pnpm", "yarn", "bun"].contains(first) {
            return .install
        }
        if ["build", "compile", "tsc", "make", "xcodebuild", "webpack", "vite build"].contains(where: { cmd.contains($0) }) {
            return .build
        }
        return .run
    }

    var symbol: String {
        switch self {
        case .explore: return "doc.text.magnifyingglass"
        case .edit: return "pencil"
        case .test: return "checkmark.seal"
        case .build: return "hammer"
        case .install: return "shippingbox"
        case .git: return "arrow.triangle.branch"
        case .run: return "terminal"
        case .web: return "globe"
        case .delegate: return "person.2"
        case .plan: return "list.bullet"
        case .tool: return "wrench.and.screwdriver"
        }
    }

    func pastVerb(tool: String) -> String {
        switch self {
        case .explore: return tool == "Read" ? "Read" : "Searched"
        case .edit: return tool == "Write" ? "Created" : "Edited"
        case .test: return "Ran"
        case .build: return "Built"
        case .install: return "Installed"
        case .git, .run: return "Ran"
        case .web: return tool == "WebSearch" ? "Searched the web for" : "Read"
        case .delegate: return "Sub-agent finished"
        case .plan: return "Updated the plan"
        case .tool: return "Used " + ToolInfo.displayName(tool)
        }
    }
}

/// Reads the agent's plan out of its plan-tool calls.
enum PlanParser {
    /// TodoWrite replaces the whole list; TaskCreate appends; TaskUpdate edits one item.
    static func apply(tool: String, input: [String: Any], to plan: inout [PlanItem]) {
        switch tool {
        case "TodoWrite":
            let todos = input["todos"] as? [[String: Any]] ?? []
            plan = todos.enumerated().map { i, t in
                PlanItem(id: (t["id"] as? String) ?? String(i + 1),
                         text: t["content"] as? String ?? t["subject"] as? String ?? "",
                         activeText: t["activeForm"] as? String,
                         status: status(t["status"] as? String))
            }.filter { !$0.text.isEmpty }
        case "TaskCreate":
            let text = input["subject"] as? String ?? input["content"] as? String ?? input["description"] as? String ?? ""
            guard !text.isEmpty else { return }
            plan.append(PlanItem(id: String(plan.count + 1), text: firstLine(text),
                                 activeText: input["activeForm"] as? String, status: .pending))
        case "TaskUpdate":
            let id = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init) ?? (input["id"] as? String) ?? ""
            guard let i = plan.firstIndex(where: { $0.id == id }) else { return }
            if let s = input["status"] as? String { plan[i].status = status(s) }
            if let subj = input["subject"] as? String, !subj.isEmpty { plan[i].text = firstLine(subj) }
            if let a = input["activeForm"] as? String, !a.isEmpty { plan[i].activeText = a }
            // Only one step is "the current one".
            if plan[i].status == .active {
                for j in plan.indices where j != i && plan[j].status == .active { plan[j].status = .pending }
            }
        case "update_plan": // Codex
            let steps = input["plan"] as? [[String: Any]] ?? []
            plan = steps.enumerated().map { i, t in
                PlanItem(id: String(i + 1), text: t["step"] as? String ?? "", activeText: nil,
                         status: status(t["status"] as? String))
            }.filter { !$0.text.isEmpty }
        default:
            break
        }
    }

    private static func status(_ s: String?) -> PlanItem.Status {
        switch s {
        case "in_progress", "active", "doing": return .active
        case "completed", "done", "deleted": return .done
        default: return .pending
        }
    }

    private static func firstLine(_ s: String) -> String {
        ToolInfo.clip(ToolInfo.firstLine(s), 80)
    }
}

/// Turns an agent's narration ("I'll update the tests next, then…") into a short status line.
enum Narration {
    static func headline(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("```") else { return nil }
        // A markdown bold title (Codex reasoning style) is the best headline.
        if t.hasPrefix("**"), let end = t.dropFirst(2).range(of: "**") {
            let title = String(t[t.index(t.startIndex, offsetBy: 2)..<end.lowerBound])
            if !title.isEmpty { return clean(title) }
        }
        t = ToolInfo.firstLine(t)
        // First sentence.
        for sep in [". ", "! ", "? ", ": "] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]); break }
        }
        let c = clean(t)
        return c.count >= 4 ? c : nil
    }

    private static func clean(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(".") || out.hasSuffix(":") || out.hasSuffix("…") { out.removeLast() }
        return ToolInfo.clip(out, 90)
    }
}

extension Session {
    var planProgress: (done: Int, total: Int)? {
        guard !plan.isEmpty else { return nil }
        return (plan.filter { $0.status == .done }.count, plan.count)
    }

    var currentPlanItem: PlanItem? { plan.first { $0.status == .active } }

    /// The most meaningful one-liner for a working session. "Thinking…" only as a last resort.
    var liveLine: String {
        if case let .tool(name, detail) = status {
            return ToolInfo.verb(for: name) + (detail.isEmpty ? "" : " " + detail)
        }
        if let intent, let at = intentAt, Date().timeIntervalSince(at) < 180 { return intent }
        if let item = currentPlanItem { return item.activeText ?? item.text }
        if let last = actions.last, Date().timeIntervalSince(last.at) < 600 { return last.pastTense }
        return "Thinking…"
    }

    /// Headline for the compact island: the plan step when there is one (it's what the
    /// agent itself says it's doing), otherwise the live line.
    var compactLine: String {
        if status.isWorking, let item = currentPlanItem { return item.activeText ?? item.text }
        return liveLine
    }

    /// Phase of what's happening right now (for the icon).
    var livePhase: Phase? {
        if case let .tool(name, _) = status { return actions.last.map(\.phase) ?? Phase.of(tool: name, input: [:]) }
        return nil
    }
}
