import AppKit

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
    var branch: String?
    /// The pipeline: jobs grouped by name ("Test (macOS 14)" and "Test (macOS 15)" are one "Test" stage).
    var stages: [CIStage] = []
    /// What's running right now, e.g. "Package: Build DMG and zip".
    var step: String?
    /// The step that broke, e.g. "Test".
    var failedStep: String?

    var isFinished: Bool {
        switch state { case .passed, .failed: return true; default: return false }
    }

    /// Worth showing: running, or finished in the last 15 minutes.
    func isFresh(at now: Date = Date()) -> Bool {
        guard let f = finishedAt else { return true }
        return now.timeIntervalSince(f) < 15 * 60
    }

    var elapsed: TimeInterval { elapsed(at: Date()) }
    /// Time since the push, frozen once the run finishes.
    func elapsed(at now: Date) -> TimeInterval { max(0, (finishedAt ?? now).timeIntervalSince(startedAt)) }

    var short: String {
        switch state {
        case .waiting: return "CI queued"
        case let .running(done, total): return total > 0 ? "CI \(done)/\(total)" : "CI running"
        case .passed: return "CI passed"
        case .failed: return "CI failed"
        }
    }
}

/// One step of the pipeline: a job, or several jobs of a matrix.
struct CIStage: Equatable, Identifiable {
    enum State: Equatable { case queued, running, passed, failed, skipped }
    var name: String
    var jobs = 1
    var done = 0
    var state: State
    var id: String { name }

    /// "Test 2/3" while a matrix runs, "Test ×3" otherwise.
    var label: String {
        guard jobs > 1 else { return name }
        return state == .running ? "\(name) \(done)/\(jobs)" : "\(name) ×\(jobs)"
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
        jobs(fromJSON: data).first(where: \.failed)?.name
    }

    struct Job: Equatable {
        var name: String
        var status: String
        var conclusion: String?
        var startedAt: Date?
        var step: String?         // the step in progress
        var failedStep: String?

        var failed: Bool { ["failure", "timed_out", "startup_failure"].contains(conclusion ?? "") }
        var finished: Bool { status == "completed" }
        /// "Test (macOS 14 · Apple silicon)" → "Test".
        var stage: String {
            guard let r = name.range(of: " ("), name.hasSuffix(")"), r.lowerBound > name.startIndex else { return name }
            return String(name[..<r.lowerBound])
        }
    }

    static func jobs(fromJSON data: Data) -> [Job] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["jobs"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return list.map { j in
            let steps = j["steps"] as? [[String: Any]] ?? []
            return Job(name: j["name"] as? String ?? "Job", status: j["status"] as? String ?? "queued",
                       conclusion: j["conclusion"] as? String,
                       startedAt: (j["started_at"] as? String).flatMap(iso.date(from:)),
                       step: steps.first { ($0["status"] as? String) == "in_progress" }?["name"] as? String,
                       failedStep: steps.first { ($0["conclusion"] as? String) == "failure" }?["name"] as? String)
        }
    }

    /// Jobs → pipeline stages, in the order they started. Matrix jobs share a stage.
    static func stages(_ jobs: [Job]) -> [CIStage] {
        let far = Date.distantFuture
        let ordered = jobs.enumerated().sorted {
            let a = $0.element.startedAt ?? far, b = $1.element.startedAt ?? far
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        var names: [String] = []
        var groups: [String: [Job]] = [:]
        for j in ordered {
            if groups[j.stage] == nil { names.append(j.stage) }
            groups[j.stage, default: []].append(j)
        }
        return names.map { name in
            let g = groups[name]!
            let done = g.filter(\.finished).count
            let state: CIStage.State
            if g.contains(where: \.failed) { state = .failed }
            else if done == g.count {
                state = g.allSatisfy { ["skipped", "cancelled", "neutral"].contains($0.conclusion ?? "") } ? .skipped : .passed
            } else if done > 0 || g.contains(where: { $0.status == "in_progress" }) { state = .running }
            else { state = .queued }
            return CIStage(name: name, jobs: g.count, done: done, state: state)
        }
    }

    /// Without job details (no token), each workflow run is one stage.
    static func stages(runs all: [Run]) -> [CIStage] {
        relevant(all).map { r in
            let state: CIStage.State
            if r.failed { state = .failed }
            else if r.status == "completed" { state = ["skipped", "cancelled"].contains(r.conclusion ?? "") ? .skipped : .passed }
            else if r.status == "in_progress" { state = .running }
            else { state = .queued }
            return CIStage(name: r.name, state: state)
        }
    }

    /// Stage names in a workflow file, in order (GitHub only lists a job once the jobs it needs
    /// are done; this lets the whole pipeline show from the start). Light YAML reading: job keys
    /// two spaces in under `jobs:`, and their `name:`.
    static func plannedStages(workflow yaml: String) -> [String] {
        var out: [String] = []
        var inJobs = false
        var key: String?
        var name: String?
        func flush() {
            guard let k = key else { return }
            var n = name ?? k
            if n.hasPrefix("${{") { n = k }   // the whole name is an expression
            let stage = Job(name: n, status: "", conclusion: nil).stage
            if !out.contains(stage) { out.append(stage) }
            key = nil; name = nil
        }
        for raw in yaml.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 { flush(); inJobs = trimmed == "jobs:"; continue }
            guard inJobs else { continue }
            if indent == 2, trimmed.hasSuffix(":"), !trimmed.contains(" ") {
                flush(); key = String(trimmed.dropLast())
            } else if indent == 4, trimmed.hasPrefix("name:"), key != nil {
                name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        flush()
        return out
    }

    /// Live stages in the workflow's order, with the ones GitHub hasn't listed yet as queued.
    static func merge(_ stages: [CIStage], planned: [String]) -> [CIStage] {
        guard !planned.isEmpty, !stages.isEmpty else { return stages }
        let known = Set(planned)
        var out = planned.map { name in stages.first { $0.name == name } ?? CIStage(name: name, state: .queued) }
        out += stages.filter { !known.contains($0.name) }
        return out
    }

    /// "Test (macOS 14 · Apple silicon)" → "Test (macOS 14)": short enough for a banner.
    static func shortJob(_ name: String) -> String {
        guard let open = name.range(of: " ("), let dot = name.range(of: " · ", range: open.upperBound..<name.endIndex),
              name.hasSuffix(")") else { return name }
        return String(name[..<dot.lowerBound]) + ")"
    }

    /// "Package: Build DMG and zip" for the first job that's running.
    static func liveStep(_ jobs: [Job]) -> String? {
        guard let j = jobs.first(where: { $0.status == "in_progress" && $0.step != nil }), var step = j.step else { return nil }
        if step.hasPrefix("Run ") { step.removeFirst(4) }
        return "\(j.stage): \(step)"
    }
}

/// Watches GitHub Actions for commits your agents push. Uses your `gh` login when
/// there is one (so private repos work); public repos work without it.
final class CIWatcher {
    /// Status changed for a session (nil: nothing to show, e.g. the repo has no workflows).
    var onUpdate: ((String, CIStatus?) -> Void)?
    /// All runs finished.
    var onFinish: ((String, CIStatus) -> Void)?
    /// GitHub picked up the push and the pipeline is known.
    var onStart: ((String, CIStatus) -> Void)?
    /// The repo looks private and there's no GitHub login (fires once per app run).
    var onNeedsLogin: (() -> Void)?
    private var askedForLogin = false

    private struct Watch { var sid: String; var status: CIStatus; var token = 0; var started = false; var root = "" }
    private var watches: [String: Watch] = [:]   // by session id (main thread)
    private let io = DispatchQueue(label: "notchbar.ci", qos: .utility)
    /// ETag → body per URL (io queue). A 304 is free: it doesn't count against GitHub's rate limit.
    private var etags: [URL: (tag: String, body: Data)] = [:]

    /// Start (or restart) watching after a push from `root`.
    func pushed(sessionID sid: String, root folder: String) {
        // The agent may be in a subfolder (e.g. docs/): use the repo it belongs to.
        let root = Git.root(at: folder) ?? folder
        guard let repo = GitHub.repo(atRoot: root) else { DiagLog.log("ci: push, not a GitHub repo"); return }
        let token = (watches[sid]?.token ?? 0) + 1
        io.async { [weak self] in
            guard let self, let sha = Self.headSHA(root) else { DiagLog.log("ci: push, no commit found"); return }
            DiagLog.log("ci: watching s\(sid.prefix(4))")
            let branch = Git.branch(at: root)
            _ = GitHubAuth.shared.token()   // warm the login off the main thread
            DispatchQueue.main.async {
                var st = CIStatus(state: .waiting, repo: repo, sha: sha, url: URL(string: "https://github.com/\(repo)/actions"))
                st.branch = branch
                self.watches[sid] = Watch(sid: sid, status: st, token: token, root: root)
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
        let authed = GitHubAuth.shared.hasToken
        let url = URL(string: "https://api.github.com/repos/\(w.status.repo)/actions/runs?head_sha=\(w.status.sha)&per_page=30")!
        fetch(url) { [weak self] data, code in
            guard let self, let cur = self.watches[sid], cur.token == token else { return }
            guard let data else {
                // A private repo answers 404 without a login: say how to fix it, once.
                if code == 404, !authed {
                    if !self.askedForLogin { self.askedForLogin = true; self.onNeedsLogin?() }
                    self.drop(sid); return
                }
                // Offline or no access: give up quietly after a while.
                if age > 300 { self.drop(sid) } else { self.schedule(sid, token: token, after: 20) }
                return
            }
            let runs = GitHub.runs(fromJSON: data)
            DiagLog.log("ci: \(runs.count) runs, \(GitHub.summarize(runs))")
            if runs.isEmpty {
                // No workflows for this commit (or none in this repo): stop after two minutes.
                if age > 120 { self.drop(sid) } else { self.schedule(sid, token: token, after: 8) }
                return
            }
            var st = cur.status
            st.state = GitHub.summarize(runs)
            st.url = GitHub.focus(runs)?.url ?? st.url
            // Job details make the pipeline. Without a login, save the rate limit for the end.
            let wantJobs = authed || st.isFinished
            let ids = GitHub.relevant(runs).prefix(3).map(\.id)
            self.fetchJobs(repo: st.repo, runs: wantJobs ? ids : []) { [weak self] jobs in
                guard let self, self.watches[sid]?.token == token else { return }
                st.stages = jobs.isEmpty ? GitHub.stages(runs: runs) : GitHub.stages(jobs)
                if !jobs.isEmpty, !st.isFinished, let root = self.watches[sid]?.root {
                    st.stages = GitHub.merge(st.stages, planned: Self.planned(root: root, runs: runs))
                }
                st.step = GitHub.liveStep(jobs)
                if case .failed = st.state, let bad = jobs.first(where: \.failed) {
                    st.state = .failed(job: GitHub.shortJob(bad.name))   // the exact job, e.g. "Test (macOS 14)"
                    st.failedStep = bad.failedStep
                }
                if !(self.watches[sid]?.started ?? true) {
                    self.watches[sid]?.started = true
                    if !st.isFinished { self.onStart?(sid, st) }
                }
                if st.isFinished { self.finish(sid, st); return }
                self.watches[sid]?.status = st
                self.onUpdate?(sid, st)
                if age > 90 * 60 { self.drop(sid); return }
                self.schedule(sid, token: token, after: authed ? (age < 120 ? 5 : 8) : 15)
            }
        }
    }

    /// Jobs of several runs, in order (empty if none were asked for or all failed to load).
    private func fetchJobs(repo: String, runs ids: [Int], _ done: @escaping ([GitHub.Job]) -> Void) {
        guard let id = ids.first else { return done([]) }
        let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs/\(id)/jobs?per_page=100")!
        fetch(url) { [weak self] data, _ in
            let jobs = data.map(GitHub.jobs(fromJSON:)) ?? []
            guard let self else { return done(jobs) }
            self.fetchJobs(repo: repo, runs: Array(ids.dropFirst())) { rest in done(jobs + rest) }
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

    /// GET with your gh token when there is one. Calls back on the main thread
    /// with the body (nil on any failure) and the HTTP status.
    private func fetch(_ url: URL, _ done: @escaping (Data?, Int) -> Void) {
        io.async { [weak self] in
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("NotchBar", forHTTPHeaderField: "User-Agent")
            if let t = GitHubAuth.shared.token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
            if let tag = self?.etags[url]?.tag { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
            URLSession.shared.dataTask(with: req) { data, resp, err in
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                self?.io.async {
                    var body: Data?
                    if code == 304 {
                        body = self?.etags[url]?.body
                    } else if (200..<300).contains(code), let data {
                        body = data
                        if let tag = http?.value(forHTTPHeaderField: "ETag") { self?.etags[url] = (tag, data) }
                        if (self?.etags.count ?? 0) > 200 { self?.etags.removeAll() }
                    } else {
                        DiagLog.log("ci: http \(code)\(err != nil ? " offline" : "")")
                    }
                    DispatchQueue.main.async { done(body, code) }
                }
            }.resume()
        }
    }

    /// Stage names from the workflow files of the runs that matter (read from your checkout).
    private static func planned(root: String, runs: [GitHub.Run]) -> [String] {
        GitHub.relevant(runs).prefix(3).flatMap { r -> [String] in
            guard r.path.hasPrefix(".github/workflows/"), !r.path.contains(".."),
                  let yaml = try? String(contentsOfFile: root + "/" + r.path, encoding: .utf8) else { return [] }
            return GitHub.plannedStages(workflow: yaml)
        }
    }

    private static func headSHA(_ root: String) -> String? {
        guard let sha = run("/usr/bin/git", ["-C", root, "rev-parse", "HEAD"]), sha.count == 40 else { return nil }
        return sha
    }

    static func run(_ path: String, _ args: [String]) -> String? {
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

/// Your GitHub login, borrowed from the GitHub CLI (`gh`). NotchBar never stores a token itself.
final class GitHubAuth: ObservableObject {
    static let shared = GitHubAuth()

    enum Status: Equatable {
        case checking
        case connected(user: String)
        case signedOut      // gh is installed, not logged in
        case noCLI          // gh isn't installed
    }
    @Published private(set) var status: Status = .checking

    private let lock = NSLock()
    private var cachedToken: String?
    private var checkedAt: Date?
    private var waitTimer: Timer?

    static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `gh auth token`, cached for 10 minutes so a later login is picked up. Any thread.
    func token() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let at = checkedAt, Date().timeIntervalSince(at) < 600 { return cachedToken }
        checkedAt = Date()
        cachedToken = Self.ghPath.flatMap { CIWatcher.run($0, ["auth", "token", "--hostname", "github.com"]) }
        return cachedToken
    }

    /// The last known login, without asking gh again (safe on the main thread).
    var hasToken: Bool { lock.lock(); defer { lock.unlock() }; return cachedToken != nil }

    /// Re-read the login (e.g. when Settings opens).
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.checkedAt = nil; self.lock.unlock()
            let st: Status
            if let gh = Self.ghPath {
                st = self.token() != nil
                    ? .connected(user: CIWatcher.run(gh, ["api", "user", "--jq", ".login"]) ?? "GitHub")
                    : .signedOut
            } else {
                st = .noCLI
            }
            DispatchQueue.main.async {
                self.status = st
                if case .connected = st { self.waitTimer?.invalidate(); self.waitTimer = nil }
            }
        }
    }

    /// Opens Terminal to install gh if needed and sign in through the browser,
    /// then watches for the login to land.
    func connect() {
        let script = """
        #!/bin/zsh -l
        clear
        echo "Connecting NotchBar to GitHub"
        echo
        GH=$(command -v gh || ls /opt/homebrew/bin/gh 2>/dev/null)
        if [ -z "$GH" ]; then
          if command -v brew >/dev/null 2>&1; then
            echo "Installing the GitHub CLI first..."
            brew install gh || exit 1
            GH=$(command -v gh)
          else
            echo "Get the GitHub CLI from https://cli.github.com, then press Connect again."
            open "https://cli.github.com"
            exit 1
          fi
        fi
        "$GH" auth login --hostname github.com --web --git-protocol https
        echo
        echo "All set. NotchBar will pick it up in a few seconds. You can close this window."
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Connect NotchBar to GitHub.command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        } catch { return }
        NSWorkspace.shared.open(file)
        // Notice the login without making you come back and click anything.
        waitTimer?.invalidate()
        var tries = 0
        waitTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            tries += 1
            if tries > 100 { t.invalidate(); return }
            self?.refresh()
        }
    }
}
