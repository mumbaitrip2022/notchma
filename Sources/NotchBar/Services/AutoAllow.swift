import Foundation

/// Why a request was answered without asking you.
enum AutoAllowReason: Equatable {
    case rule(AllowRule)
    case trust
    case readOnly
}

/// Short-lived "trust this project" windows plus the read-only defaults.
/// Both only ever cover requests that are *not* flagged destructive.
final class TrustPolicy: ObservableObject {
    /// project root → when trust ends. In memory only: a restart ends all trust.
    @Published private(set) var windows: [String: Date] = [:]
    private var expiryTimer: Timer?

    var active: [(project: String, until: Date)] {
        windows.filter { $0.value > Date() }.map { ($0.key, $0.value) }.sorted { $0.until < $1.until }
    }

    func trust(project: String, minutes: Int) {
        guard !project.isEmpty, minutes > 0 else { return }
        windows[project] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        scheduleExpiry()
    }

    func end(project: String) {
        windows[project] = nil
        scheduleExpiry()
    }

    func isTrusted(_ project: String) -> Bool {
        guard let until = windows[project] else { return false }
        return until > Date()
    }

    /// Drops expired windows exactly when the next one ends (no polling).
    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        windows = windows.filter { $0.value > Date() }
        guard let next = windows.values.min() else { return }
        let t = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            self?.scheduleExpiry()
        }
        RunLoop.main.add(t, forMode: .common)
        expiryTimer = t
    }

    // MARK: what a trust window covers

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch"]
    private static let readTools: Set<String> = ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch"]

    /// Commands, in-project edits, reads and web lookups — never MCP/unknown tools.
    static func trustCovers(tool: String, input: [String: Any], project: String) -> Bool {
        if ToolInfo.isRisky(tool: tool, input: input) { return false }
        if tool == "Bash" { return true }
        if readTools.contains(tool) { return true }
        if editTools.contains(tool) {
            let paths = EditedFiles.paths(tool: tool, input: input, cwd: project)
            return !paths.isEmpty && paths.allSatisfy { isInside($0, project) }
        }
        return false
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let r = URL(fileURLWithPath: root).standardizedFileURL.path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    // MARK: read-only defaults

    private static let readOnlyCommands: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "which", "whoami", "uname", "date", "echo", "grep", "rg",
        "tree", "du", "df", "stat", "file", "diff", "jq", "basename", "dirname", "realpath", "find",
    ]
    private static let readOnlyGit: Set<String> = [
        "status", "diff", "log", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog",
    ]
    private static let findWriters: Set<String> = ["-exec", "-execdir", "-delete", "-ok", "-okdir", "-fprint", "-fprintf", "-fls"]

    /// Plain commands that only read (no chaining, pipes, redirects or writes).
    static func isReadOnly(tool: String, input: [String: Any]) -> Bool {
        guard tool == "Bash" else { return false }
        let cmd = ToolInfo.unwrapShell(input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tokens = RuleStore.simpleTokens(cmd), let first = tokens.first else { return false }
        if ToolInfo.isRisky(tool: "Bash", input: ["command": cmd]) { return false }
        if first == "git" {
            guard tokens.count >= 2 else { return false }
            let sub = tokens[1]
            if readOnlyGit.contains(sub) {
                // `--output[=file]` / `-o` make diff/log write files.
                return !tokens.contains { $0 == "-o" || $0.hasPrefix("--output") || $0.hasPrefix("--ext-diff") }
            }
            if sub == "branch" { return tokens.dropFirst(2).allSatisfy { ["-a", "-r", "-v", "-vv", "--list", "--show-current"].contains($0) } }
            if sub == "remote" { return tokens.dropFirst(2).allSatisfy { $0 == "-v" } }
            if sub == "stash" { return tokens.count >= 3 && tokens[2] == "list" }
            return false
        }
        guard readOnlyCommands.contains(first) else { return false }
        if first == "find" { return !tokens.contains(where: { findWriters.contains($0) }) }
        return true
    }
}

/// Files a tool call writes to, as absolute paths.
enum EditedFiles {
    static func paths(tool: String, input: [String: Any], cwd: String) -> [String] {
        var raw: [String] = []
        switch tool {
        case "Edit", "MultiEdit", "Write":
            if let p = input["file_path"] as? String { raw.append(p) }
        case "NotebookEdit":
            if let p = input["notebook_path"] as? String { raw.append(p) }
        case "apply_patch":
            let patch = input["command"] as? String ?? input["patch"] as? String ?? ""
            for line in patch.components(separatedBy: "\n") {
                for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "]
                where line.hasPrefix(prefix) {
                    raw.append(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
                }
            }
        default:
            break
        }
        return raw.filter { !$0.isEmpty }.map { p in
            let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : URL(fileURLWithPath: cwd).appendingPathComponent(p)
            return url.standardizedFileURL.path
        }
    }
}
