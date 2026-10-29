import Foundation

/// Codex skips every hook until it's trusted, so a fresh install stays silent until you run
/// /hooks. NotchBar trusts its own entries, and only those, with the same two app server
/// calls Codex's /hooks screen makes (hooks/list, then config/batchWrite). Codex does the
/// hashing and writes its own config, so this keeps working when Codex changes either.
enum CodexTrust {
    /// How many of our hooks were trusted (0 when all already were), or nil if Codex couldn't be reached.
    @discardableResult
    static func trustOurHooks(hookPath: String, timeout: TimeInterval = 20) -> Int? {
        signal(SIGPIPE, SIG_IGN)   // Codex may exit early; a broken pipe must not kill us
        let deadline = Date().addingTimeInterval(timeout)
        for launch in launches() {
            let rpc = RPC(launch)
            guard rpc.start() else { continue }
            defer { rpc.stop() }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
            guard rpc.call("initialize", ["clientInfo": ["name": "notchbar", "title": "NotchBar", "version": version]],
                           until: deadline) != nil else { continue }
            rpc.notify("initialized")
            guard let list = rpc.call("hooks/list", ["cwds": [NSHomeDirectory()]], until: deadline),
                  let entries = list["data"] as? [[String: Any]] else { return nil }
            let picks = pending(in: entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] },
                                command: Installer.command(hookPath: hookPath, agent: .codex),
                                source: Installer.configURL(.codex).path)
            if picks.isEmpty { return 0 }
            let state = Dictionary(picks.map { ($0.key, ["trusted_hash": $0.hash]) }, uniquingKeysWith: { a, _ in a })
            let edit: [String: Any] = ["keyPath": "hooks.state", "value": state, "mergeStrategy": "upsert"]
            guard rpc.call("config/batchWrite", ["edits": [edit], "reloadUserConfig": true], until: deadline) != nil
            else { return nil }
            return picks.count
        }
        return nil
    }

    /// Our hooks that Codex hasn't trusted yet. Only exact NotchBar commands from
    /// ~/.codex/hooks.json qualify, so nothing else ever gets trusted on your behalf.
    static func pending(in hooks: [[String: Any]], command: String, source: String) -> [(key: String, hash: String)] {
        hooks.compactMap { h in
            guard let key = h["key"] as? String, key.hasPrefix(source + ":"),
                  let hash = h["currentHash"] as? String, !hash.isEmpty,
                  h["command"] as? String == command,
                  ["untrusted", "modified"].contains(h["trustStatus"] as? String ?? "") else { return nil }
            return (key, hash)
        }
    }

    /// Where Codex might live: the ChatGPT and Codex apps bundle it, the CLI installs it
    /// elsewhere. Last resort: your login shell, which knows your PATH (npm, Homebrew, …).
    private static func launches() -> [(String, [String])] {
        let home = NSHomeDirectory()
        let paths = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                     "/Applications/Codex.app/Contents/Resources/codex",
                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex",
                     home + "/.npm-global/bin/codex", home + "/.bun/bin/codex", home + "/.volta/bin/codex"]
        var out = paths.filter { FileManager.default.isExecutableFile(atPath: $0) }.map { ($0, ["app-server"]) }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        out.append((shell, ["-lc", "command -v codex >/dev/null && exec codex app-server"]))
        return out
    }
}

/// A tiny JSON-RPC client over the app server's stdio (one JSON object per line).
private final class RPC {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSCondition()
    private var buffer = Data(), messages: [[String: Any]] = [], closed = false, nextID = 1

    init(_ launch: (String, [String])) {
        process.executableURL = URL(fileURLWithPath: launch.0)
        process.arguments = launch.1
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func start() -> Bool {
        output.fileHandleForReading.readabilityHandler = { [weak self] h in self?.take(h.availableData) }
        do { try process.run(); return true } catch { return false }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func notify(_ method: String) { send(["method": method]) }

    /// The result of one request, or nil on an error, a closed pipe or the deadline.
    func call(_ method: String, _ params: [String: Any], until deadline: Date) -> [String: Any]? {
        let id = nextID
        nextID += 1
        send(["id": id, "method": method, "params": params])
        lock.lock()
        defer { lock.unlock() }
        while true {
            if let i = messages.firstIndex(where: { $0["method"] == nil && ($0["id"] as? Int) == id }) {
                return messages.remove(at: i)["result"] as? [String: Any]
            }
            if closed || !lock.wait(until: deadline) { return nil }
        }
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    private func take(_ data: Data) {
        lock.lock()
        defer { lock.broadcast(); lock.unlock() }
        guard !data.isEmpty else { closed = true; output.fileHandleForReading.readabilityHandler = nil; return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let m = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { messages.append(m) }
        }
    }
}
