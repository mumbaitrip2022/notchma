import AppKit

/// "What did it do?" — open the diff, or copy a ready-made summary.
enum Review {
    private static let queue = DispatchQueue(label: "notchbar.review", qos: .userInitiated)

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBar/diffs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum Outcome { case opened, noChanges, notGit, failed(String) }

    /// Writes the project's uncommitted changes (including new files) to a .diff and opens it.
    static func openDiff(for s: Session, completion: @escaping (Outcome) -> Void) {
        let root = s.projectRoot.isEmpty ? s.cwd : s.projectRoot
        let name = s.projectName
        queue.async {
            let outcome = makeAndOpenDiff(root: root, name: name)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private static func makeAndOpenDiff(root: String, name: String) -> Outcome {
        guard Git.root(at: root) != nil else { return .notGit }
        guard let text = diffText(root: root) else { return .failed("git diff timed out") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noChanges }
        return write(text, name: name)
    }

    /// Uncommitted changes vs HEAD plus new (untracked, not ignored) files. Nil if git fails.
    static func diffText(root: String) -> String? {
        let git = Shell.which("git") ?? "/usr/bin/git"
        guard let tracked = Shell.run(git, ["-C", root, "diff", "HEAD", "--no-color", "--no-ext-diff"], timeout: 15)
        else { return nil }
        // A repo with no commits yet has no HEAD; fall back to the plain working-tree diff.
        var text = tracked.ok ? tracked.stdout
            : (Shell.run(git, ["-C", root, "diff", "--no-color", "--no-ext-diff"], timeout: 15)?.stdout ?? "")
        if let untracked = Shell.run(git, ["-C", root, "ls-files", "--others", "--exclude-standard"], timeout: 10)?.stdout {
            let files = untracked.split(separator: "\n").map(String.init).prefix(30)
            for f in files {
                // --no-index exits 1 when files differ; that's expected.
                if let r = Shell.run(git, ["-C", root, "diff", "--no-color", "--no-index", "--", "/dev/null", f], timeout: 5) {
                    text += r.stdout
                }
            }
        }
        return text
    }

    private static func write(_ text: String, name: String) -> Outcome {
        cleanOldDiffs()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = cacheDir.appendingPathComponent("\(safeName)-\(stamp).diff")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return .failed(error.localizedDescription) }

        let sem = DispatchSemaphore(value: 0)
        var ok = false
        DispatchQueue.main.async {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let editor = [TerminalJump.cursorBundle, TerminalJump.vscodeBundle]
                .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            if let editor {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: config) { _, e in
                    ok = e == nil; sem.signal()
                }
            } else {
                ok = NSWorkspace.shared.open(url); sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 5)
        return ok ? .opened : .failed("Couldn't open the diff")
    }

    private static func cleanOldDiffs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: f) }
        }
    }

    /// Commit-style summary: what the agent said it did, files touched, tests.
    static func summary(for s: Session) -> String {
        let headline: String = {
            if let m = s.lastMessage {
                let line = SessionStore.plain(m).split(separator: "\n").first.map(String.init) ?? ""
                if !line.isEmpty { return ToolInfo.clip(line, 72) }
            }
            return ToolInfo.clip(ToolInfo.firstLine(s.lastPrompt.isEmpty ? "Update \(s.projectName)" : s.lastPrompt), 72)
        }()
        var out = headline
        let root = s.projectRoot.isEmpty ? s.cwd : s.projectRoot
        if !s.editedFiles.isEmpty {
            out += "\n\n"
            out += s.editedFiles.prefix(30).map { f -> String in
                let rel = f.hasPrefix(root + "/") ? String(f.dropFirst(root.count + 1)) : f
                return "- \(rel)"
            }.joined(separator: "\n")
        }
        if let t = s.testResult { out += "\n\n" + t.summary.replacingOccurrences(of: "tests ✓", with: "Tests:")
                                                            .replacingOccurrences(of: "tests ✗", with: "Tests:") }
        return out
    }
}
