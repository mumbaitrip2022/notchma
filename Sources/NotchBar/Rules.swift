import Foundation

/// A command (or domain) the user chose to always allow in one project.
struct AllowRule: Codable, Identifiable, Equatable {
    var id = UUID()
    let agent: String       // Agent.rawValue
    let project: String     // project root path
    let tool: String        // "Bash" or "WebFetch"
    let pattern: String     // "npm test" or a domain
    var native: Bool        // also written as a Claude Code permission rule
    var created = Date()
    var uses = 0

    var projectName: String { (project as NSString).lastPathComponent }
    var display: String { tool == "WebFetch" ? "fetch \(pattern)" : pattern }

    /// Claude Code permission-rule strings for this rule.
    var claudeRules: [String] {
        tool == "WebFetch" ? ["WebFetch(domain:\(pattern))"] : ["Bash(\(pattern))", "Bash(\(pattern) *)"]
    }
}

/// Learns which simple commands you keep approving, and remembers the ones you
/// chose to always allow. Persisted in Application Support. Main thread only.
final class RuleStore: ObservableObject {
    @Published private(set) var rules: [AllowRule] = []
    private var counts: [String: Int] = [:]
    private let url: URL

    /// After this many manual approvals, the next request offers "Always allow".
    static let suggestAfter = 2

    init() {
        url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/NotchBar/rules.json")
        load()
    }

    // MARK: patterns

    /// Interpreters and wrappers: allowing these would allow arbitrary code.
    private static let neverPrefix: Set<String> = [
        "python", "python3", "node", "bash", "sh", "zsh", "fish", "ruby", "perl", "php", "eval", "exec",
        "sudo", "su", "xargs", "env", "nohup", "osascript", "curl", "wget", "ssh", "scp", "rm", "mv", "dd",
        "chmod", "chown", "kill", "killall", "open", "source", ".",
    ]
    /// Single-word commands that are safe to allow as a whole.
    private static let safeSingle: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "which", "echo", "grep", "rg", "tree", "du", "df",
        "diff", "file", "stat", "date", "whoami", "uname",
    ]
    /// Tools whose subcommand is part of the rule ("npm test", "git status", "swift build").
    private static let twoWord: Set<String> = [
        "npm", "pnpm", "yarn", "bun", "npx", "git", "swift", "cargo", "go", "make", "docker", "kubectl",
        "pip", "pip3", "brew", "gh", "xcodebuild", "uv", "poetry", "bundle", "rails", "composer", "dotnet",
        "mvn", "gradle", "./gradlew", "flutter", "dart", "deno", "turbo", "nx", "vercel", "supabase",
        "pytest", "jest", "vitest", "tsc", "eslint", "prettier", "terraform", "artisan",
    ]

    /// The rule pattern a request would get, or nil if it should never be suggested.
    static func candidate(tool: String, input: [String: Any]) -> (tool: String, pattern: String)? {
        switch tool {
        case "Bash":
            let cmd = ToolInfo.unwrapShell(input["command"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tokens = simpleTokens(cmd), let first = tokens.first else { return nil }
            if neverPrefix.contains(first) || first.contains("=") || first.hasPrefix("-") { return nil }
            if ToolInfo.isRisky(tool: "Bash", input: ["command": cmd]) { return nil }
            var n = 1
            if twoWord.contains(first) {
                n = 2
                if ["run", "exec", "x"].contains(tokens.count > 1 ? tokens[1] : "") { n = 3 } // npm run test
            } else if !safeSingle.contains(first) {
                return nil
            }
            guard tokens.count >= n else { return n == 1 ? (tool, first) : nil }
            let picked = Array(tokens.prefix(n))
            if picked.dropFirst().contains(where: { $0.hasPrefix("-") }) { return nil }
            return ("Bash", picked.joined(separator: " "))
        case "WebFetch":
            guard let host = URL(string: input["url"] as? String ?? "")?.host, !host.isEmpty else { return nil }
            return ("WebFetch", host)
        default:
            return nil
        }
    }

    /// Tokens of a plain command; nil if it chains, pipes, redirects or substitutes.
    static func simpleTokens(_ cmd: String) -> [String]? {
        guard !cmd.isEmpty else { return nil }
        for bad in ["&&", "||", ";", "|", "`", "$(", ">", "<", "\n", "&"] where cmd.contains(bad) { return nil }
        return cmd.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    // MARK: lookups

    func match(agent: Agent, project: String, tool: String, input: [String: Any]) -> AllowRule? {
        guard let c = Self.candidate(tool: tool, input: input) else { return nil }
        return rules.first { r in
            r.agent == agent.rawValue && r.project == project && r.tool == c.tool && covers(r.pattern, c.pattern, tool: c.tool)
        }
    }

    /// "npm test" covers "npm test" (the candidate is already normalised to the rule's length).
    private func covers(_ rule: String, _ cand: String, tool: String) -> Bool {
        tool == "WebFetch" ? rule == cand : (cand == rule || cand.hasPrefix(rule + " "))
    }

    func timesAllowed(agent: Agent, project: String, tool: String, pattern: String) -> Int {
        counts[key(agent, project, tool, pattern)] ?? 0
    }

    func recordAllow(agent: Agent, project: String, tool: String, pattern: String) {
        counts[key(agent, project, tool, pattern), default: 0] += 1
        save()
    }

    func noteUse(_ rule: AllowRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i].uses += 1
        save()
    }

    @discardableResult
    func add(agent: Agent, project: String, tool: String, pattern: String) -> AllowRule {
        if let existing = rules.first(where: {
            $0.agent == agent.rawValue && $0.project == project && $0.tool == tool && $0.pattern == pattern
        }) { return existing }
        var rule = AllowRule(agent: agent.rawValue, project: project, tool: tool, pattern: pattern, native: false)
        if agent == .claude { rule.native = ClaudePermissions.add(rule.claudeRules, project: project) }
        rules.append(rule)
        save()
        return rule
    }

    func remove(_ rule: AllowRule) {
        if rule.native { ClaudePermissions.remove(rule.claudeRules, project: rule.project) }
        rules.removeAll { $0.id == rule.id }
        counts[key(Agent(rawValue: rule.agent) ?? .claude, rule.project, rule.tool, rule.pattern)] = nil
        save()
    }

    // MARK: persistence

    private func key(_ a: Agent, _ p: String, _ t: String, _ pat: String) -> String { "\(a.rawValue)|\(p)|\(t)|\(pat)" }

    private struct Stored: Codable { var rules: [AllowRule]; var counts: [String: Int] }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        rules = s.rules
        counts = s.counts
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Stored(rules: rules, counts: counts)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Reads/writes `permissions.allow` in a project's `.claude/settings.local.json`
/// (Claude Code's personal, git-ignored project settings).
enum ClaudePermissions {
    private static func url(_ project: String) -> URL {
        URL(fileURLWithPath: project).appendingPathComponent(".claude/settings.local.json")
    }

    @discardableResult
    static func add(_ rules: [String], project: String) -> Bool {
        update(project) { allow in
            for r in rules where !allow.contains(r) { allow.append(r) }
        }
    }

    static func remove(_ rules: [String], project: String) {
        _ = update(project) { allow in allow.removeAll { rules.contains($0) } }
    }

    private static func update(_ project: String, _ change: (inout [String]) -> Void) -> Bool {
        let u = url(project)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: u), !data.isEmpty {
            // Never overwrite a file we can't parse.
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            root = obj
        }
        var perms = root["permissions"] as? [String: Any] ?? [:]
        var allow = perms["allow"] as? [String] ?? []
        change(&allow)
        perms["allow"] = allow
        root["permissions"] = perms
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: u, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
