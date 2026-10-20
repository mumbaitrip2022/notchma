import AppKit

/// A task to start: which agent, where, with what prompt — now or later.
struct LaunchRequest: Codable, Identifiable, Equatable {
    var id = UUID()
    let agent: String          // Agent.rawValue
    let project: String
    let prompt: String
    let worktree: Bool
    var startAt: Date?

    var agentValue: Agent { Agent(rawValue: agent) ?? .claude }
    var projectName: String { (project as NSString).lastPathComponent }
}

/// Starts agents in your terminal (optionally in a fresh git worktree) and
/// runs scheduled starts. Everything slow happens off the main thread.
final class Launcher: ObservableObject {
    /// CLI path per agent, nil = not installed. Empty until the first lookup finishes.
    @Published private(set) var cli: [Agent: String] = [:]
    @Published private(set) var cliChecked = false
    @Published private(set) var scheduled: [LaunchRequest] = []

    /// Reports results to the UI (banner text).
    var onMessage: ((String, Bool) -> Void)?
    var terminalPreference: () -> String = { "auto" }

    private let queue = DispatchQueue(label: "notchbar.launcher", qos: .userInitiated)
    private var timer: Timer?
    private let defaultsKey = "scheduledLaunches"

    static let commands: [Agent: String] = [.claude: "claude", .codex: "codex", .cursor: "cursor-agent"]

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let list = try? JSONDecoder().decode([LaunchRequest].self, from: data) {
            scheduled = list
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.runDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.runDue() }
    }

    func refreshCLIs() {
        queue.async {
            var found: [Agent: String] = [:]
            for (agent, cmd) in Self.commands { if let p = Shell.which(cmd) { found[agent] = p } }
            DispatchQueue.main.async {
                self.cli = found
                self.cliChecked = true
            }
        }
    }

    // MARK: launching

    func submit(_ r: LaunchRequest) {
        if let at = r.startAt, at.timeIntervalSinceNow > 30 {
            scheduled.append(r)
            scheduled.sort { ($0.startAt ?? .distantPast) < ($1.startAt ?? .distantPast) }
            persist()
            onMessage?("Scheduled \(r.agentValue.shortName) in \(r.projectName) for \(Fmt.clock(at))", false)
        } else {
            launch(r)
        }
    }

    func cancel(_ id: UUID) {
        scheduled.removeAll { $0.id == id }
        persist()
    }

    private func launch(_ r: LaunchRequest) {
        guard let cliPath = cli[r.agentValue] else {
            onMessage?("\(r.agentValue.shortName) CLI not found — install it or pick another agent", true)
            return
        }
        let terminal = resolveTerminal(terminalPreference())
        queue.async {
            var dir = r.project
            if r.worktree {
                switch Self.makeWorktree(project: r.project, prompt: r.prompt) {
                case let .success(path): dir = path
                case let .failure(msg):
                    DispatchQueue.main.async { self.onMessage?("Worktree failed: \(msg)", true) }
                    return
                }
            }
            let command = Self.command(cliPath: cliPath, dir: dir, prompt: r.prompt)
            let ok = Self.open(command: command, title: r.projectName, cwd: dir, terminal: terminal)
            DispatchQueue.main.async {
                self.onMessage?(ok ? "Started \(r.agentValue.shortName) in \((dir as NSString).lastPathComponent)"
                                   : "Couldn't open a terminal for the new task", !ok)
            }
        }
    }

    /// `cd '<dir>' && '<cli>' '<prompt>'` — everything quoted for the shell.
    static func command(cliPath: String, dir: String, prompt: String) -> String {
        var command = "cd \(Shell.quote(dir)) && \(Shell.quote(cliPath))"
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { command += " " + Shell.quote(p) }
        return command
    }

    // MARK: scheduling

    private func persist() {
        if let data = try? JSONEncoder().encode(scheduled) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        armTimer()
    }

    private func armTimer() {
        timer?.invalidate()
        guard let next = scheduled.compactMap(\.startAt).min() else { return }
        let t = Timer(fire: max(next, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            self?.runDue()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Starts everything that's due. Starts missed by more than 2 hours (Mac asleep/off) are dropped.
    func runDue() {
        let now = Date()
        let due = scheduled.filter { ($0.startAt ?? now) <= now }
        guard !due.isEmpty else { armTimer(); return }
        scheduled.removeAll { r in due.contains { $0.id == r.id } }
        persist()
        if cli.isEmpty && !cliChecked { refreshCLIsThen { self.start(due, now: now) } } else { start(due, now: now) }
    }

    private func start(_ due: [LaunchRequest], now: Date) {
        for r in due {
            if let at = r.startAt, now.timeIntervalSince(at) > 2 * 3600 {
                onMessage?("Skipped a scheduled \(r.agentValue.shortName) task in \(r.projectName) (missed while away)", true)
            } else {
                launch(r)
            }
        }
    }

    private func refreshCLIsThen(_ then: @escaping () -> Void) {
        queue.async {
            var found: [Agent: String] = [:]
            for (agent, cmd) in Self.commands { if let p = Shell.which(cmd) { found[agent] = p } }
            DispatchQueue.main.async { self.cli = found; self.cliChecked = true; then() }
        }
    }

    // MARK: worktrees

    enum WorktreeResult { case success(String), failure(String) }

    static func makeWorktree(project: String, prompt: String) -> WorktreeResult {
        guard let root = Git.root(at: project) else { return .failure("\((project as NSString).lastPathComponent) isn't a git repository") }
        let git = Shell.which("git") ?? "/usr/bin/git"
        let words = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(4).joined(separator: "-")
        let base = words.isEmpty ? "task" : String(words.prefix(30))
        let slug = base + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        let repoURL = URL(fileURLWithPath: root)
        let dir = repoURL.deletingLastPathComponent()
            .appendingPathComponent(repoURL.lastPathComponent + ".worktrees", isDirectory: true)
            .appendingPathComponent(slug).path
        try? FileManager.default.createDirectory(atPath: (dir as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        guard let r = Shell.run(git, ["-C", root, "worktree", "add", "-b", "notchbar/\(slug)", dir], timeout: 30) else {
            return .failure("git timed out")
        }
        if !r.ok {
            let msg = r.stderr.split(separator: "\n").last.map(String.init) ?? "git worktree add failed"
            return .failure(msg.replacingOccurrences(of: "fatal: ", with: ""))
        }
        return .success(dir)
    }

    // MARK: terminals

    static let warpBundles = ["dev.warp.Warp-Stable", "dev.warp.Warp"]
    static let itermBundle = "com.googlecode.iterm2"
    static let terminalBundle = "com.apple.Terminal"

    static func installed(_ bundle: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
    }

    /// Terminals we can start tasks in, for the settings picker.
    static var availableTerminals: [(id: String, name: String)] {
        var list: [(String, String)] = [("auto", "Automatic")]
        if warpBundles.contains(where: installed) { list.append(("warp", "Warp")) }
        if installed(itermBundle) { list.append((itermBundle, "iTerm2")) }
        list.append((terminalBundle, "Terminal"))
        return list
    }

    private func resolveTerminal(_ pref: String) -> String {
        if pref == "warp" || (pref == "auto" && Self.warpBundles.contains(where: Self.installed)) { return "warp" }
        if pref == Self.itermBundle || (pref == "auto" && Self.installed(Self.itermBundle)) { return Self.itermBundle }
        return Self.terminalBundle
    }

    private static func open(command: String, title: String, cwd: String, terminal: String) -> Bool {
        switch terminal {
        case "warp":
            if openWarp(command: command, title: title, cwd: cwd) { return true }
            return openTerminalApp(command: command)
        case itermBundle:
            return openITerm(command: command) || openTerminalApp(command: command)
        default:
            return openTerminalApp(command: command)
        }
    }

    /// Warp runs commands through a launch configuration file + its URL scheme.
    private static func openWarp(command: String, title: String, cwd: String) -> Bool {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".warp/launch_configurations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "notchbar-\(UUID().uuidString.prefix(8).lowercased())"
        /// A JSON string literal is a valid YAML double-quoted scalar.
        func json(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data()
            let array = String(decoding: data, as: UTF8.self)
            return array.count >= 2 ? String(array.dropFirst().dropLast()) : "\"\""
        }
        let yaml = """
        ---
        name: \(json(name))
        windows:
          - tabs:
              - title: \(json(title))
                layout:
                  cwd: \(json(cwd))
                  commands:
                    - exec: \(json(command))
        """
        let file = dir.appendingPathComponent(name + ".yaml")
        guard (try? yaml.write(to: file, atomically: true, encoding: .utf8)) != nil,
              let url = URL(string: "warp://launch/\(name).yaml") else { return false }
        var ok = false
        DispatchQueue.main.sync { ok = NSWorkspace.shared.open(url) }
        // Warp reads the file on open; tidy up afterwards.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { try? FileManager.default.removeItem(at: file) }
        return ok
    }

    private static func openITerm(command: String) -> Bool {
        let script = """
        tell application id "com.googlecode.iterm2"
          activate
          if (count of windows) = 0 then
            create window with default profile
          else
            tell current window to create tab with default profile
          end if
          tell current session of current window to write text "\(appleScriptEscape(command))"
        end tell
        return "ok"
        """
        return Shell.run("/usr/bin/osascript", ["-e", script], timeout: 8)?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    private static func openTerminalApp(command: String) -> Bool {
        let script = """
        tell application id "com.apple.Terminal"
          activate
          do script "\(appleScriptEscape(command))"
        end tell
        return "ok"
        """
        return Shell.run("/usr/bin/osascript", ["-e", script], timeout: 8)?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
