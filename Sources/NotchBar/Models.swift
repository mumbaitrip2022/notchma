import Foundation
import SwiftUI

enum SessionStatus: Equatable {
    case idle
    case thinking
    case tool(name: String, detail: String)
    case needsApproval(tool: String)
    case waitingForInput
    case done

    var isWorking: Bool {
        switch self {
        case .thinking, .tool: return true
        default: return false
        }
    }
}

enum Agent: String, CaseIterable, Identifiable {
    case claude, codex, cursor
    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// Flat, solid brand-adjacent tint.
    var tint: Color {
        switch self {
        case .claude: return .claude
        case .codex: return Color(red: 0.42, green: 0.80, blue: 0.68)
        case .cursor: return Color(red: 0.62, green: 0.66, blue: 1.0)
        }
    }

    /// Where "hand back" decisions go.
    var handBackLabel: String { self == .cursor ? "In Cursor" : "Terminal" }

    var fallbackBundleIDs: [String] {
        switch self {
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .codex: return ["com.openai.codex"]
        case .claude: return []
        }
    }
}

/// What tapping a banner does.
enum BannerAction: Equatable {
    case jump                 // go to the session's terminal
    case copyAndJump(String)  // copy text (e.g. "/compact"), then go
    case sendDraft            // paste your drafted next prompt
    case expand               // open the notch
    case receipt              // open today's receipt
}

/// A short Dynamic-Island-style alert shown in the notch.
struct Banner: Identifiable, Equatable {
    enum Kind: Equatable { case done, waiting, failed, limit(critical: Bool), attention, info, draft, pet }
    let id = UUID()
    let kind: Kind
    let sessionID: String
    let agent: Agent
    let title: String
    let subtitle: String
    var action: BannerAction = .jump
    var important = false // shown even in quiet (meeting) mode
}

struct Session: Identifiable, Equatable {
    let id: String
    var agent: Agent = .claude
    var cwd: String
    var pid: Int32
    var termProgram: String
    var bundleID: String
    var status: SessionStatus = .idle
    var lastPrompt: String = ""
    var turnStartedAt: Date?
    var turnEndedAt: Date?
    var lastEventAt = Date()
    var branch: String?

    // Usage
    var model: String?
    var contextPercent: Double?
    var transcriptPath: String?
    var costTotal: Double?
    var linesAddedTotal: Int?
    var linesRemovedTotal: Int?
    var costAtTurnStart: Double?
    var linesAddedAtTurnStart: Int?
    var linesRemovedAtTurnStart: Int?
    var transcriptOffsetAtTurnStart: UInt64?
    var tokensAtTurnStart: Int?
    var lastTask: TaskReceipt?

    // Health
    var alert: SessionAlert?
    var autoAllowed = 0

    // Where it runs (for jumping to the exact tab/pane)
    var tty: String?
    var tmuxPane: String?
    var tmuxSocket: String?
    var itermSession: String?

    // Live activity: what it's doing, saying and planning
    var intent: String?          // the agent's own narration ("Updating the tests")
    var intentAt: Date?
    var plan: [PlanItem] = []    // its to-do list for this task
    var actions: [ActionRecord] = [] // last few things it did (newest last)
    var steps = 0                // tool calls this turn

    /// What the agent is asking you, when it's waiting (its question, or "plan ready").
    var question: String?

    // Turn summary
    var lastMessage: String?
    var editedFiles: [String] = []
    var testResult: TestResult?

    // Attention queue: when it started waiting on you, and whether you've looked.
    var waitingSince: Date?
    var attended = false

    /// Folder used for git, rules and trust (repo root when there is one).
    /// Stored (set when `cwd` changes) so views never touch the filesystem.
    var projectRoot: String = ""

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "~" : name
    }

    var statusText: String {
        switch status {
        case .idle: return "Idle"
        case .thinking: return liveLine
        case .tool: return liveLine
        case let .needsApproval(tool): return "Needs approval · \(ToolInfo.displayName(tool))"
        case .waitingForInput: return "Waiting for you"
        case .done: return "Done"
        }
    }
}

/// What the approval card renders for a tool.
enum ApprovalPreview: Equatable {
    case command(String, description: String?)
    case diff(path: String, removed: [String], added: [String])
    case text(title: String?, body: String)
}

/// "You've allowed this before — always allow?" offer on an approval card.
struct AllowCandidate: Equatable {
    let agent: Agent
    let project: String
    let tool: String
    let pattern: String
}

/// Something about a working session that deserves a look.
enum SessionAlert: Equatable {
    case stuck(minutes: Int)
    case looping(what: String, count: Int)
    case failing(what: String, count: Int)

    var text: String {
        switch self {
        case let .stuck(m): return "May be stuck · quiet for \(m)m"
        case let .looping(what, n): return "Looping · \(what) ×\(n)"
        case let .failing(what, n): return "Failing · \(what) ×\(n)"
        }
    }

    /// Plain-language line for the alert banner.
    var detail: String {
        switch self {
        case let .stuck(m): return "No activity for \(m) minutes"
        case let .looping(what, n): return "Ran \(what) \(n) times in 10 minutes"
        case let .failing(what, n): return "\(what) failed \(n) times in a row"
        }
    }
}

struct Approval: Identifiable, Equatable {
    let id = UUID()
    let clientID: SocketServer.ClientID
    let sessionID: String
    let toolName: String
    let detail: String
    let preview: ApprovalPreview
    let risky: Bool
    /// Set when this exact kind of command was approved before (and is safe to always allow).
    var candidate: AllowCandidate? = nil
    var offerAlways = false
    var timesAllowed = 0
    /// Project root the request belongs to (for trust windows).
    var project: String? = nil
    /// Whether a trust window would cover this kind of request.
    var trustable = false
    let createdAt = Date()

    static func == (a: Approval, b: Approval) -> Bool { a.id == b.id }
}

enum ToolInfo {
    static func displayName(_ tool: String) -> String {
        if tool == "apply_patch" { return "Patch" }
        if tool.hasPrefix("mcp__") {
            let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
            return parts.last.map(String.init) ?? tool
        }
        return tool
    }

    static func symbol(for tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput", "KillShell": return "terminal.fill"
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch": return "pencil.line"
        case "Write": return "doc.badge.plus"
        case "Read": return "doc.text.magnifyingglass"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2.fill"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension.fill" : "wrench.and.screwdriver.fill"
        }
    }

    static func approvalVerb(_ tool: String) -> String {
        switch tool {
        case "Bash": return "run a command"
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch": return "edit a file"
        case "Write": return "create a file"
        case "WebFetch": return "fetch a page"
        case "WebSearch": return "search the web"
        default: return "use \(displayName(tool))"
        }
    }

    static func verb(for tool: String) -> String {
        switch tool {
        case "Bash": return "Running"
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch": return "Editing"
        case "Write": return "Writing"
        case "Read": return "Reading"
        case "Grep", "Glob": return "Searching"
        case "WebFetch": return "Fetching"
        case "WebSearch": return "Searching web"
        case "Task", "Agent": return "Running agent"
        case "TodoWrite": return "Planning"
        default: return "Using \(displayName(tool))"
        }
    }

    /// Short one-line detail for the session row.
    static func detail(tool: String, input: [String: Any]) -> String {
        func file(_ key: String) -> String {
            ((input[key] as? String).map { ($0 as NSString).lastPathComponent }) ?? ""
        }
        switch tool {
        case "apply_patch":
            if case let .diff(path, _, _) = patchPreview(input["command"] as? String ?? "") {
                return (path as NSString).lastPathComponent
            }
            return ""
        case "Bash": return clip(firstLine(unwrapShell(input["command"] as? String ?? "")), 48)
        case "Edit", "MultiEdit", "Write", "Read": return file("file_path")
        case "NotebookEdit": return file("notebook_path")
        case "Grep", "Glob": return clip(input["pattern"] as? String ?? "", 40)
        case "WebFetch": return clip(URL(string: input["url"] as? String ?? "")?.host ?? "", 40)
        case "WebSearch": return clip(input["query"] as? String ?? "", 40)
        case "Task", "Agent": return clip(input["description"] as? String ?? "", 40)
        default: return ""
        }
    }

    static func preview(tool: String, input: [String: Any]) -> ApprovalPreview {
        if tool == "apply_patch" || (input["command"] as? String ?? "").hasPrefix("*** Begin Patch") {
            return patchPreview(input["command"] as? String ?? input["patch"] as? String ?? "")
        }
        switch tool {
        case "Bash":
            return .command(unwrapShell(input["command"] as? String ?? ""), description: input["description"] as? String)
        case "Edit":
            return .diff(path: input["file_path"] as? String ?? "",
                         removed: lines(input["old_string"] as? String),
                         added: lines(input["new_string"] as? String))
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return .diff(path: input["file_path"] as? String ?? "",
                         removed: edits.flatMap { lines($0["old_string"] as? String) },
                         added: edits.flatMap { lines($0["new_string"] as? String) })
        case "Write":
            return .diff(path: input["file_path"] as? String ?? "", removed: [],
                         added: lines(input["content"] as? String))
        case "WebFetch":
            return .text(title: input["url"] as? String, body: input["prompt"] as? String ?? "")
        case "WebSearch":
            return .text(title: "Search", body: input["query"] as? String ?? "")
        default:
            let data = (try? JSONSerialization.data(
                withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return .text(title: nil, body: clip(String(decoding: data, as: UTF8.self), 2000))
        }
    }

    /// Codex often wraps commands as `bash -lc '…'`; show the inner command.
    static func unwrapShell(_ cmd: String) -> String {
        for prefix in ["bash -lc ", "/bin/bash -lc ", "zsh -lc ", "/bin/zsh -lc ", "sh -c ", "/bin/sh -c "]
        where cmd.hasPrefix(prefix) {
            var inner = String(cmd.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if inner.count >= 2, let f = inner.first, f == inner.last, f == "'" || f == "\"" {
                inner = String(inner.dropFirst().dropLast())
            }
            return inner
        }
        return cmd
    }

    /// Codex `apply_patch` format → diff preview.
    static func patchPreview(_ patch: String) -> ApprovalPreview {
        var path = "", removed: [String] = [], added: [String] = []
        for line in patch.components(separatedBy: "\n") {
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                if path.isEmpty { path = String(line.dropFirst(prefix.count)) }
            }
            if line.hasPrefix("***") || line.hasPrefix("@@") { continue }
            if line.hasPrefix("-") { removed.append(String(line.dropFirst())) }
            else if line.hasPrefix("+") { added.append(String(line.dropFirst())) }
        }
        return .diff(path: path, removed: removed, added: added)
    }

    /// Flags commands that can destroy data or rewrite history.
    static func isRisky(tool: String, input: [String: Any]) -> Bool {
        guard tool == "Bash", let cmd = input["command"] as? String else { return false }
        let patterns = [
            #"\brm\s+(-\w*\s+)*-\w*[rRf]"#, #"\bsudo\b"#, #"\bgit\s+push\b.*(\s--force|\s-f\b)"#,
            #"\bgit\s+reset\s+--hard"#, #"\bgit\s+clean\s+-\w*f"#, #"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b"#,
            #"\bchmod\s+(-R\s+)?777"#, #"\bmkfs\b"#, #"\bdd\s+if="#, #">\s*/dev/(disk|sd)"#,
            #"(?i)\bdrop\s+(table|database|schema)\b"#, #"(?i)\btruncate\s+table\b"#,
            #"\bkill(all)?\s+-9\b"#, #"\bfind\b.*\s-delete\b"#,
        ]
        return patterns.contains { cmd.range(of: $0, options: .regularExpression) != nil }
    }

    /// Lightweight shell syntax colouring for the approval card.
    static func highlightBash(_ cmd: String) -> AttributedString {
        var out = AttributedString(cmd)
        out.foregroundColor = .white.opacity(0.9)
        let ns = cmd as NSString
        func paint(_ pattern: String, group: Int = 0, _ apply: (inout AttributeContainer) -> Void) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            for m in re.matches(in: cmd, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(at: group)
                guard r.location != NSNotFound, let sr = Range(r, in: cmd),
                      let ar = Range(sr, in: out) else { continue }
                var c = AttributeContainer()
                apply(&c)
                out[ar].mergeAttributes(c)
            }
        }
        // Hierarchy by weight and brightness, not hue: commands bold white, flags and
        // operators dimmer, quoted strings slightly softer.
        paint(#"(^|&&|\|\||\||;|\$\()\s*([A-Za-z0-9_./~+-]+)"#, group: 2) {
            $0.foregroundColor = .white
            $0.inlinePresentationIntent = .stronglyEmphasized
        }
        paint(#"(?<=\s)--?[A-Za-z0-9][\w-]*"#) { $0.foregroundColor = .white.opacity(0.62) }
        paint(#"&&|\|\||\||;|>>?|<"#) { $0.foregroundColor = .white.opacity(0.45) }
        paint(#""(?:[^"\\]|\\.)*"|'[^']*'"#) { $0.foregroundColor = .white.opacity(0.78) }
        return out
    }

    private static func lines(_ s: String?) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        return s.components(separatedBy: "\n")
    }

    static func firstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }
}

/// Result of the last test run in a turn, read from command output.
struct TestResult: Equatable {
    var passed: Int?
    var failed: Int
    var summary: String { "tests " + short }
    var short: String { failed > 0 ? "✗ \(failed) failed" : "✓ \(passed.map { "\($0) passed" } ?? "passed")" }
}
