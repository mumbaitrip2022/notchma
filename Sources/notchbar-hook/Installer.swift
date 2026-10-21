import Foundation

/// Adds / removes NotchBar's hook entries in each agent's config file,
/// leaving every other key untouched.
///   Claude Code → ~/.claude/settings.json   (key "hooks")
///   Codex       → ~/.codex/hooks.json       (key "hooks", same schema as Claude)
///   Cursor      → ~/.cursor/hooks.json      ({"version":1,"hooks":{event:[{command}]}})
enum Installer {
    static let marker = "notchbar-hook"

    static func configURL(_ agent: Agent) -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch agent {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        }
    }

    /// (event, matcher, timeout seconds)
    private static func events(_ agent: Agent, cursorApprovals: Bool) -> [(String, String?, Int)] {
        switch agent {
        case .claude:
            return [("PermissionRequest", "*", 600), ("PreToolUse", "*", 5), ("PostToolUse", "*", 5),
                    ("PostToolUseFailure", "*", 5),
                    ("UserPromptSubmit", nil, 5), ("Stop", nil, 5), ("Notification", nil, 5),
                    ("SessionStart", nil, 5), ("SessionEnd", nil, 5)]
        case .codex:
            return [("PermissionRequest", nil, 600), ("PreToolUse", nil, 5), ("PostToolUse", nil, 5),
                    ("UserPromptSubmit", nil, 5), ("Stop", nil, 5), ("Interrupt", nil, 2),
                    ("SessionStart", nil, 5), ("SessionEnd", nil, 2)]
        case .cursor:
            var list: [(String, String?, Int)] = [
                ("sessionStart", nil, 5), ("sessionEnd", nil, 5), ("beforeSubmitPrompt", nil, 5),
                ("afterShellExecution", nil, 5), ("afterMCPExecution", nil, 5), ("afterFileEdit", nil, 5),
                ("postToolUseFailure", nil, 5), ("afterAgentResponse", nil, 5),
                ("afterAgentThought", nil, 5),
                ("stop", nil, 5),
            ]
            // Cursor fires these for *every* command, so they're opt-in.
            if cursorApprovals {
                list += [("beforeShellExecution", nil, 600), ("beforeMCPExecution", nil, 600)]
            }
            return list
        }
    }

    static func selfPath() -> String {
        let p = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }

    static func isInstalled(agent: Agent) -> Bool {
        guard let data = try? Data(contentsOf: configURL(agent)),
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains(marker)
    }

    static func install(agent: Agent, hookPath: String, cursorApprovals: Bool = false) -> Bool {
        let url = configURL(agent)
        guard var root = load(url) else { return false }
        backupOnce(url)
        let quoted = "'" + hookPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // If the app is ever deleted without uninstalling, `test -x` keeps the agent quiet.
        let command = "test -x \(quoted) && \(quoted) --agent \(agent.rawValue) || true"

        var hooks = stripAll(root["hooks"] as? [String: Any] ?? [:], agent: agent)
        for (event, matcher, timeout) in events(agent, cursorApprovals: cursorApprovals) {
            var list = hooks[event] as? [[String: Any]] ?? []
            if agent == .cursor {
                // Cursor blocks on empty output for these events, so answer even if the app is gone.
                var cmd = command
                if event == "beforeSubmitPrompt" { cmd = cmd.replacingOccurrences(of: "|| true", with: "|| echo '{\"continue\":true}'") }
                if event.hasPrefix("before") && event.hasSuffix("Execution") {
                    cmd = cmd.replacingOccurrences(of: "|| true", with: "|| echo '{\"permission\":\"ask\"}'")
                }
                list.append(["command": cmd, "timeout": timeout])
            } else {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
                if let matcher { group["matcher"] = matcher }
                list.append(group)
            }
            hooks[event] = list
        }
        root["hooks"] = hooks
        if agent == .cursor, root["version"] == nil { root["version"] = 1 }
        // Claude's statusline carries cost, context and plan limits. Only claim the
        // slot if it's free (or already ours) — never replace someone's statusline.
        if agent == .claude {
            let existing = (root["statusLine"] as? [String: Any])?["command"] as? String
            if existing == nil || isOurs(existing) {
                root["statusLine"] = ["type": "command", "padding": 0,
                                      "command": "test -x \(quoted) && \(quoted) --agent claude --statusline || true"]
            } else {
                print("Kept your existing statusLine; NotchBar won't show Claude cost/limits.")
            }
        }
        return save(root, to: url, message: "NotchBar hooks installed for \(agent.rawValue) → \(url.path)")
    }

    static func uninstall(agent: Agent) -> Bool {
        let url = configURL(agent)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard var root = load(url) else { return false }
        let hooks = stripAll(root["hooks"] as? [String: Any] ?? [:], agent: agent)
        root["hooks"] = hooks.isEmpty ? nil : hooks
        if agent == .claude, isOurs((root["statusLine"] as? [String: Any])?["command"]) { root["statusLine"] = nil }
        if agent == .cursor, root["hooks"] == nil { root["hooks"] = [String: Any]() }
        return save(root, to: url, message: "NotchBar hooks removed for \(agent.rawValue).")
    }

    // MARK: private

    private static func load(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else {
            fputs("Could not read \(url.path)\n", stderr); return nil
        }
        if data.isEmpty { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fputs("\(url.path) is not valid JSON, so NotchBar left it untouched.\n", stderr); return nil
        }
        return obj
    }

    private static func backupOnce(_ url: URL) {
        let backup = url.appendingPathExtension("notchbar-backup")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: url, to: backup)
        }
    }

    private static func isOurs(_ cmd: Any?) -> Bool { ((cmd as? String) ?? "").contains(marker) }

    /// Removes every NotchBar entry; drops events that end up empty.
    private static func stripAll(_ hooks: [String: Any], agent: Agent) -> [String: Any] {
        var out = hooks
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]]
            if agent == .cursor {
                cleaned = list.filter { !isOurs($0["command"]) }
            } else {
                cleaned = list.compactMap { group in
                    guard let inner = group["hooks"] as? [[String: Any]] else { return group }
                    let kept = inner.filter { !isOurs($0["command"]) }
                    if kept.isEmpty { return nil }
                    var g = group
                    g["hooks"] = kept
                    return g
                }
            }
            out[event] = cleaned.isEmpty ? nil : cleaned
        }
        return out
    }

    private static func save(_ root: [String: Any], to url: URL, message: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            print(message)
            return true
        } catch {
            fputs("Failed to write \(url.path): \(error)\n", stderr)
            return false
        }
    }
}
