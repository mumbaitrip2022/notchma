import AppKit
import Foundation

/// A small private log of what NotchBar did (event names, sizes, errors). Never prompts,
/// commands, file paths or session text. Kept in memory, saved next to the app's
/// support files so it survives a crash, and only leaves the Mac if you file a report.
final class DiagLog {
    static let shared = DiagLog()

    private var lines: [String] = []
    private(set) var previous: [String] = []   // the last run's tail, for "it crashed" reports
    private let limit = 150
    private let queue = DispatchQueue(label: "notchbar.diag", qos: .utility)
    private var dirty = false
    private var timer: DispatchSourceTimer?
    private let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/NotchBar/diag.log")
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss"; return f
    }()

    private init() {
        guard !DayLedger.isTesting else { return }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            previous = text.split(separator: "\n").suffix(60).map(String.init)
        }
        // Save at most every 20s, and only when something new was logged.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }

    static func log(_ message: String) { shared.add(message) }

    func add(_ message: String) {
        let line = Self.clock.string(from: Date()) + "  " + message
        queue.async {
            self.lines.append(line)
            if self.lines.count > self.limit { self.lines.removeFirst(self.lines.count - self.limit) }
            self.dirty = true
        }
    }

    var recent: [String] { queue.sync { lines } }

    /// Synchronous save, for quitting.
    func flushNow() {
        queue.sync {
            guard !DayLedger.isTesting else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            dirty = false
        }
    }

    func flush() {
        queue.async {
            guard self.dirty, !DayLedger.isTesting else { return }
            self.dirty = false
            try? FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? self.lines.joined(separator: "\n").write(to: self.url, atomically: true, encoding: .utf8)
        }
    }
}

/// Everything that goes into "Report a problem", built so you can read it before it's shared.
enum Diagnostics {
    struct Crash: Equatable {
        let date: Date
        let summary: String   // exception type and reason
        let frames: [String]  // the crashed thread's top frames, symbols only
        let file: URL
    }

    // MARK: environment

    static func environment(prefs: Prefs, screens: [NSScreen] = NSScreen.screens) -> [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osBuild = sysctlString("kern.osversion") ?? ""
        let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown chip"
        let model = sysctlString("hw.model") ?? ""
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var out = [
            "NotchBar \(v) (build \(build))\(AppLocation.isInApplications ? "" : ", not in Applications")",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(osBuild)) on \(model), \(chip), \(Int(ram.rounded())) GB",
        ]
        let shown = screens.enumerated().map { i, s -> String in
            let f = s.frame
            let notch = s.safeAreaInsets.top > 0 ? ", notch" : ""
            let kind = s.isBuiltIn ? "built in" : "external"
            return "\(Int(f.width))×\(Int(f.height)) \(kind)\(i == 0 ? " (main)" : "")\(notch), \(Int(s.backingScaleFactor))x"
        }
        out.append("Screens: " + shown.joined(separator: " · "))
        let agents = Agent.allCases.map { a -> String in
            let state = prefs.installed.contains(a) ? "connected" : (NotchController.agentDetected(a) ? "not connected" : "not installed")
            return "\(a.name) \(state)"
        }
        out.append("Agents: " + agents.joined(separator: " · "))
        let flags: [(String, Bool)] = [("Cursor approvals", prefs.cursorApprovals), ("read-only auto allow", prefs.readOnlyDefaults),
                                       ("pet", prefs.showPet), ("vitals", prefs.showVitals), ("sounds", prefs.sounds),
                                       ("auto paste", prefs.autoPaste), ("meetings", prefs.calendarAware), ("voice", prefs.voice),
                                       ("auto update", prefs.autoUpdate)]
        out.append("Settings: " + flags.map { "\($0.0) \($0.1 ? "on" : "off")" }.joined(separator: " · ")
                   + " · screen \(prefs.screenMode.rawValue)")
        out.append("Accessibility: \(Paster.canPaste ? "granted" : "not granted")")
        return out
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespaces)
    }

    // MARK: crashes

    /// The newest NotchBar crash report, if macOS wrote one after `since`.
    static func latestCrash(since: Date?) -> Crash? {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = files.filter {
            let n = $0.lastPathComponent
            return n.hasPrefix("NotchBar") && (n.hasSuffix(".ips") || n.hasSuffix(".crash"))
        }.compactMap { u -> (URL, Date)? in
            guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (u, d)
        }.filter { since == nil || $0.1 > since! }
        guard let (file, date) = candidates.max(by: { $0.1 < $1.1 }),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parseIPS(text, file: file, date: date)
    }

    /// .ips files are a JSON header line followed by a JSON body.
    static func parseIPS(_ text: String, file: URL, date: Date) -> Crash? {
        guard let nl = text.firstIndex(of: "\n"),
              let body = text[text.index(after: nl)...].data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Crash(date: date, summary: "crash report (unreadable format)", frames: [], file: file)
        }
        var summary: [String] = []
        if let e = j["exception"] as? [String: Any] {
            summary.append([e["type"] as? String, e["signal"] as? String, e["subtype"] as? String].compactMap { $0 }.joined(separator: " "))
        }
        if let t = j["termination"] as? [String: Any], let r = t["indicator"] as? String { summary.append(r) }
        if let a = j["asi"] as? [String: Any], let msgs = a.values.first as? [String], let m = msgs.first {
            summary.append(clean(m))
        }
        var frames: [String] = []
        let images = (j["usedImages"] as? [[String: Any]]) ?? []
        if let threads = j["threads"] as? [[String: Any]],
           let crashed = threads.first(where: { ($0["triggered"] as? Bool) == true }),
           let fs = crashed["frames"] as? [[String: Any]] {
            for f in fs.prefix(18) {
                let idx = f["imageIndex"] as? Int ?? -1
                let image = idx >= 0 && idx < images.count ? (images[idx]["name"] as? String ?? "?") : "?"
                let symbol = f["symbol"] as? String ?? "0x" + String(f["imageOffset"] as? Int ?? 0, radix: 16)
                frames.append("\(image)  \(clean(symbol))")
            }
        }
        return Crash(date: date, summary: summary.filter { !$0.isEmpty }.joined(separator: " · "), frames: frames, file: file)
    }

    /// Strip your home folder (and so your user name) from anything shared.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: "/Users/" + NSUserName(), with: "~")
    }

    // MARK: the report

    struct Parts {
        var includeEnvironment = true
        var includeActivity = true
        var includeCrash = true
    }

    static func report(what: String, parts: Parts, prefs: Prefs, crash: Crash?) -> String {
        var s = "### What happened\n"
        let w = what.trimmingCharacters(in: .whitespacesAndNewlines)
        s += (w.isEmpty ? "_(describe what you saw and what you expected)_" : w) + "\n"
        if parts.includeEnvironment {
            s += "\n### Mac and app\n" + environment(prefs: prefs).map { "- " + $0 }.joined(separator: "\n") + "\n"
        }
        if parts.includeCrash, let c = crash {
            let when = DateFormatter.localizedString(from: c.date, dateStyle: .medium, timeStyle: .short)
            s += "\n### Crash (\(when))\n```\n" + c.summary + "\n" + c.frames.joined(separator: "\n") + "\n```\n"
        }
        if parts.includeActivity {
            let now = DiagLog.shared.recent.suffix(60)
            if !now.isEmpty {
                s += "\n<details><summary>Recent activity (no prompts, commands or paths)</summary>\n\n```\n"
                    + now.joined(separator: "\n") + "\n```\n</details>\n"
            }
            if crash != nil, parts.includeCrash, !DiagLog.shared.previous.isEmpty {
                s += "\n<details><summary>Before the crash</summary>\n\n```\n"
                    + DiagLog.shared.previous.suffix(40).joined(separator: "\n") + "\n```\n</details>\n"
            }
        }
        return clean(s)
    }

    /// A prefilled "new issue" page. Long reports are trimmed to fit a URL; Copy gives the full text.
    static func issueURL(title: String, body: String) -> URL? {
        var b = body
        let maxBody = 6000
        if b.count > maxBody {
            b = String(b.prefix(maxBody)) + "\n\n_(trimmed. use Copy report in NotchBar for the full text)_"
        }
        var c = URLComponents(string: "https://github.com/\(Updater.repo)/issues/new")!
        c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: b),
                        URLQueryItem(name: "labels", value: "bug")]
        return c.url
    }
}
