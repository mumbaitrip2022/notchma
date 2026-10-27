import Foundation

/// CI status for the commit a session last pushed.
struct CIStatus: Equatable {
    enum State: Equatable {
        case waiting                       // pushed, no runs yet
        case running(done: Int, total: Int)
        case passed
        case failed(job: String?)
    }
    var state: State
    var repo: String      // owner/name
    var sha: String
    var url: URL?         // the run to open (failed one first)
    var startedAt = Date()
    var finishedAt: Date?

    var isFinished: Bool {
        switch state { case .passed, .failed: return true; default: return false }
    }

    var short: String {
        switch state {
        case .waiting: return "CI queued"
        case let .running(done, total): return total > 0 ? "CI \(done)/\(total)" : "CI running"
        case .passed: return "CI passed"
        case .failed: return "CI failed"
        }
    }
}

/// GitHub pieces that don't touch the network: remotes, push detection, run summaries.
enum GitHub {
    /// `owner/name` of the repo's GitHub `origin`, read from `.git/config` (no `git` process).
    static func repo(atRoot root: String) -> String? {
        guard let config = try? String(contentsOfFile: gitDir(root) + "/config", encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]"; continue }
            guard inOrigin, line.hasPrefix("url") else { continue }
            let url = line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return repo(fromRemote: url)
        }
        return nil
    }

    /// git@github.com:o/r.git, ssh://git@github.com/o/r, https://github.com/o/r(.git) → "o/r".
    static func repo(fromRemote url: String) -> String? {
        var s = url
        for prefix in ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/", "git://github.com/"]
        where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        guard s != url else {
            // https://user@github.com/o/r
            guard let r = url.range(of: "@github.com/") else { return nil }
            s = String(url[r.upperBound...])
            return clean(s)
        }
        return clean(s)
    }

    private static func clean(_ s: String) -> String? {
        var s = s
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// The real git dir (worktrees keep a `.git` file pointing elsewhere).
    static func gitDir(_ root: String) -> String {
        let dotGit = root + "/.git"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir), !isDir.boolValue,
           let txt = try? String(contentsOfFile: dotGit, encoding: .utf8),
           let line = txt.split(separator: "\n").first, line.hasPrefix("gitdir:") {
            let p = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            return p.hasPrefix("/") ? p : root + "/" + p
        }
        return dotGit
    }

    /// A shell command that pushes commits (not a dry run, not deleting a branch).
    static func isPush(_ command: String) -> Bool {
        let cmd = ToolInfo.unwrapShell(command)
        guard cmd.range(of: #"\bgit\s+(-C\s+\S+\s+)?push\b"#, options: .regularExpression) != nil else { return false }
        return cmd.range(of: #"\s(--dry-run|-n|--delete|-d)\b"#, options: .regularExpression) == nil
    }

    struct Run: Equatable {
        var id: Int
        var name: String
        var status: String        // queued, in_progress, completed…
        var conclusion: String?   // success, failure, cancelled, skipped, neutral…
        var url: URL?
        var event = "push"
        var path = ""

        var failed: Bool { ["failure", "timed_out", "startup_failure", "action_required"].contains(conclusion ?? "") }
        /// Security scans and Pages deploys: slow and not what "did CI pass" means.
        var isExtra: Bool { event == "dynamic" || path.lowercased().contains("codeql") || name.lowercased().contains("codeql") }
    }

    /// The runs that decide pass or fail (extras only count when they're all there is).
    static func relevant(_ runs: [Run]) -> [Run] {
        let core = runs.filter { !$0.isExtra }
        return core.isEmpty ? runs : core
    }

    static func runs(fromJSON data: Data) -> [Run] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["workflow_runs"] as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            return Run(id: id, name: r["name"] as? String ?? "CI", status: r["status"] as? String ?? "queued",
                       conclusion: r["conclusion"] as? String, url: (r["html_url"] as? String).flatMap(URL.init(string:)),
                       event: r["event"] as? String ?? "push", path: r["path"] as? String ?? "")
        }
    }

    /// One state for a commit's workflow runs. A failure counts right away;
    /// passing waits for every run that matters.
    static func summarize(_ all: [Run]) -> CIStatus.State {
        let runs = relevant(all)
        guard !runs.isEmpty else { return .waiting }
        if let bad = runs.first(where: \.failed) { return .failed(job: bad.name) }
        let done = runs.filter { $0.status == "completed" }
        if done.count < runs.count { return .running(done: done.count, total: runs.count) }
        return .passed
    }

    /// The run worth opening: a failed one, else a running one, else the first.
    static func focus(_ all: [Run]) -> Run? {
        let runs = relevant(all)
        return runs.first(where: \.failed) ?? runs.first { $0.status != "completed" } ?? runs.first
    }

    static func failedJob(fromJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = obj["jobs"] as? [[String: Any]] else { return nil }
        return jobs.first { ($0["conclusion"] as? String) == "failure" }?["name"] as? String
    }
}

/// Watches GitHub Actions for commits your agents push. Uses your `gh` login when
/// there is one (so private repos work); public repos work without it.
final class CIWatcher {
    /// Status changed for a session (nil: nothing to show, e.g. the repo has no workflows).
    var onUpdate: ((String, CIStatus?) -> Void)?
    /// All runs finished.
    var onFinish: ((String, CIStatus) -> Void)?

    private struct Watch { var sid: String; var status: CIStatus; var token = 0 }
    private var watches: [String: Watch] = [:]   // by session id (main thread)
    private let io = DispatchQueue(label: "notchbar.ci", qos: .utility)
    private var cachedToken: String?
    private var tokenCheckedAt: Date?

    /// Start (or restart) watching after a push from `root`.
    func pushed(sessionID sid: String, root: String) {
        guard let repo = GitHub.repo(atRoot: root) else { return }
        let token = (watches[sid]?.token ?? 0) + 1
        io.async { [weak self] in
            guard let self, let sha = Self.headSHA(root) else { return }
            DispatchQueue.main.async {
                let st = CIStatus(state: .waiting, repo: repo, sha: sha, url: URL(string: "https://github.com/\(repo)/actions"))
                self.watches[sid] = Watch(sid: sid, status: st, token: token)
                self.onUpdate?(sid, st)
                // GitHub needs a few seconds to register the push.
                self.schedule(sid, token: token, after: 6)
            }
        }
    }

    func forget(_ sid: String) { watches[sid] = nil }

    private func schedule(_ sid: String, token: Int, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.poll(sid, token: token) }
    }

    private func poll(_ sid: String, token: Int) {
        guard let w = watches[sid], w.token == token else { return }
        let age = Date().timeIntervalSince(w.status.startedAt)
        let url = URL(string: "https://api.github.com/repos/\(w.status.repo)/actions/runs?head_sha=\(w.status.sha)&per_page=30")!
        fetch(url) { [weak self] data in
            guard let self, let cur = self.watches[sid], cur.token == token else { return }
            guard let data else {
                // Offline or no access: give up quietly after a while.
                if age > 300 { self.drop(sid) } else { self.schedule(sid, token: token, after: 20) }
                return
            }
            let runs = GitHub.runs(fromJSON: data)
            if runs.isEmpty {
                // No workflows for this commit (or none in this repo): stop after two minutes.
                if age > 120 { self.drop(sid) } else { self.schedule(sid, token: token, after: 8) }
                return
            }
            var st = cur.status
            st.state = GitHub.summarize(runs)
            st.url = GitHub.focus(runs)?.url ?? st.url
            if case .failed = st.state, let run = GitHub.focus(runs) {
                // Name the exact job that broke, e.g. "Test (macOS 14)".
                let jobsURL = URL(string: "https://api.github.com/repos/\(st.repo)/actions/runs/\(run.id)/jobs?per_page=50")!
                self.fetch(jobsURL) { [weak self] jobs in
                    guard let self, self.watches[sid]?.token == token else { return }
                    if let job = jobs.flatMap(GitHub.failedJob(fromJSON:)) { st.state = .failed(job: job) }
                    self.finish(sid, st)
                }
                return
            }
            if st.isFinished { self.finish(sid, st); return }
            self.watches[sid]?.status = st
            self.onUpdate?(sid, st)
            if age > 90 * 60 { self.drop(sid); return }
            self.schedule(sid, token: token, after: age < 120 ? 8 : 15)
        }
    }

    private func finish(_ sid: String, _ status: CIStatus) {
        var st = status
        st.finishedAt = Date()
        watches[sid] = nil
        onUpdate?(sid, st)
        onFinish?(sid, st)
    }

    private func drop(_ sid: String) {
        watches[sid] = nil
        onUpdate?(sid, nil)
    }

    /// GET with your gh token when there is one. Calls back on the main thread (nil on any failure).
    private func fetch(_ url: URL, _ done: @escaping (Data?) -> Void) {
        io.async { [weak self] in
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("NotchBar", forHTTPHeaderField: "User-Agent")
            if let t = self?.token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                DispatchQueue.main.async { done(ok ? data : nil) }
            }.resume()
        }
    }

    /// `gh auth token`, cached; re-checked every 10 minutes so a later `gh auth login` is picked up.
    private func token() -> String? {
        if let at = tokenCheckedAt, Date().timeIntervalSince(at) < 600 { return cachedToken }
        tokenCheckedAt = Date()
        let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
        cachedToken = gh.flatMap { Self.run($0, ["auth", "token", "--hostname", "github.com"]) }
        return cachedToken
    }

    private static func headSHA(_ root: String) -> String? {
        guard let sha = run("/usr/bin/git", ["-C", root, "rev-parse", "HEAD"]), sha.count == 40 else { return nil }
        return sha
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
