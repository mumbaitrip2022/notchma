import Foundation

/// One plan-limit window (e.g. Claude's 5-hour or weekly limit).
struct UsageWindow: Equatable, Codable, Identifiable {
    var id: String { label }
    let label: String          // "5h", "Week", "Month"…
    let usedPercent: Double    // 0–100
    let resetsAt: Date?

    var isExpired: Bool { resetsAt.map { $0 < Date() } ?? false }

    static func label(forMinutes m: Int) -> String {
        switch m {
        case ..<90: return "\(m)m"
        case ..<(24 * 60): return "\(Int((Double(m) / 60).rounded()))h"
        case ..<(8 * 24 * 60): return "Week"
        default: return "Month"
        }
    }
}

/// What one prompt→done turn cost.
struct TaskReceipt: Equatable {
    var duration: TimeInterval
    var tokens: Int?
    var costUSD: Double?
    var linesAdded: Int?
    var linesRemoved: Int?
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: n < 10_000 ? "%.1fk" : "%.0fk", Double(n) / 1000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    /// API-equivalent cost; on Pro/Max this is not money actually billed.
    static func cost(_ usd: Double) -> String {
        if usd < 0.01 { return "<$0.01" }
        if usd < 10 { return String(format: "≈$%.2f", usd) }
        return String(format: "≈$%.0f", usd)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }

    static func reset(_ date: Date?) -> String {
        guard let date else { return "" }
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "now" }
        if secs < 3600 { return "in \(Int(secs / 60))m" }
        if secs < 24 * 3600 {
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            return f.string(from: date)
        }
        let f = DateFormatter(); f.dateFormat = "EEE h a"
        return f.string(from: date)
    }

    static func receipt(_ r: TaskReceipt, includeDuration: Bool = true) -> String {
        var parts: [String] = []
        if includeDuration { parts.append(SessionStore.duration(r.duration)) }
        if let t = r.tokens, t > 0 { parts.append("\(tokens(t)) tokens") }
        if let c = r.costUSD, c > 0 { parts.append(cost(c)) }
        if let a = r.linesAdded, let d = r.linesRemoved, a + d > 0 { parts.append("+\(a) −\(d)") }
        return parts.joined(separator: "  ·  ")
    }
}

/// Reads usage straight from the agents' own logs. All file IO here is meant to
/// run off the main thread.
enum UsageReader {
    /// Sum of tokens in a Claude Code transcript from `offset` to the end.
    /// Claude writes one line per content block, repeating the usage, so we
    /// count each message id once.
    static func claudeTokens(transcript path: String, from offset: UInt64) -> Int? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return 0 }
        var seen = Set<String>()
        var total = 0
        for line in data.split(separator: 0x0A) {
            guard line.count > 20,
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any]
            else { continue }
            let id = (msg["id"] as? String) ?? UUID().uuidString
            guard seen.insert(id).inserted else { continue }
            for k in ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"] {
                total += usage[k] as? Int ?? 0
            }
        }
        return total
    }

    /// Text of the last assistant message in a Claude transcript (reads the tail only).
    static func claudeLastMessage(transcript path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = fileSize(path)
        let window: UInt64 = 512 * 1024
        try? h.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? h.readToEnd() else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            guard line.count > 30, line.range(of: Data("\"assistant\"".utf8)) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { continue }
            let text = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text.count > 8000 ? String(text.prefix(8000)) + "…" : text }
        }
        return nil
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// The agent's latest narration in this turn ("Now I'll update the tests") from a
    /// Claude transcript. Stops at the turn boundary so it never shows stale text.
    static func claudeNarration(transcript path: String, since: Date) -> (text: String, at: Date)? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = fileSize(path)
        let window: UInt64 = 128 * 1024
        try? h.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? h.readToEnd() else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            guard line.count > 30, let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let at = date(obj["timestamp"]) ?? .distantPast
            if at < since.addingTimeInterval(-2) { return nil } // previous turn
            guard (obj["type"] as? String) == "assistant",
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            if let h = Narration.headline(text) { return (h, at) }
        }
        return nil
    }

    static func fileSize(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    struct CodexSnapshot {
        var totalTokens: Int = 0
        var contextPercent: Double?
        var windows: [UsageWindow] = []
        var hasUsage = false
        var narration: (text: String, at: Date)?
        var plan: [PlanItem]?
    }

    /// Latest usage (`token_count`), narration and plan from a Codex rollout (reads only the tail).
    static func codex(rollout path: String, since: Date? = nil) -> CodexSnapshot? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = fileSize(path)
        let window: UInt64 = 512 * 1024
        try? h.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? h.readToEnd() else { return nil }
        var snap = CodexSnapshot()
        var gotNarration = false, gotPlan = false
        for line in data.split(separator: 0x0A).reversed() {
            if snap.hasUsage && gotNarration && gotPlan { break }
            guard line.count > 40, let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let at = date(obj["timestamp"])
            let inTurn = since.map { (at ?? .distantPast) >= $0.addingTimeInterval(-2) } ?? true
            switch payload["type"] as? String {
            case "token_count" where !snap.hasUsage:
                guard let info = payload["info"] as? [String: Any] else { continue }
                snap.hasUsage = true
                snap.totalTokens = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int ?? 0
                if let last = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Double,
                   let size = info["model_context_window"] as? Double, size > 0 {
                    snap.contextPercent = min(100, last / size * 100)
                }
                if let rl = payload["rate_limits"] as? [String: Any] {
                    for key in ["primary", "secondary"] {
                        guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
                        let mins = w["window_minutes"] as? Int ?? 0
                        let reset = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                        snap.windows.append(UsageWindow(label: UsageWindow.label(forMinutes: mins), usedPercent: used, resetsAt: reset))
                    }
                }
            case "message" where !gotNarration:
                guard (payload["role"] as? String) == "assistant" else { continue }
                gotNarration = true
                guard inTurn, let content = payload["content"] as? [[String: Any]] else { continue }
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if let h = Narration.headline(text) { snap.narration = (h, at ?? Date()) }
            case "reasoning" where !gotNarration:
                // Reasoning summaries carry a bold title like "**Inspecting auth middleware**".
                let summary = (payload["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.last
                guard inTurn, let summary, let h = Narration.headline(summary) else { continue }
                gotNarration = true
                snap.narration = (h, at ?? Date())
            case "function_call" where !gotPlan:
                guard (payload["name"] as? String) == "update_plan" else { continue }
                gotPlan = true
                guard inTurn, let args = payload["arguments"] as? String, let d = args.data(using: .utf8),
                      let input = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                var plan: [PlanItem] = []
                PlanParser.apply(tool: "update_plan", input: input, to: &plan)
                snap.plan = plan
            default:
                continue
            }
        }
        return snap
    }
}
