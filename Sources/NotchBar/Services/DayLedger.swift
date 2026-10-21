import Foundation

/// What your agents did today, plus a small lifetime history. Feeds the idle
/// receipt and the pet's XP. Everything here comes from real hook events.
/// Main thread only; writes are debounced and happen off-main.
final class DayLedger: ObservableObject {
    struct Turn: Codable, Equatable {
        var key: String
        var agent: String
        var project: String
        var duration: Double
        var tokens: Int?
        var cost: Double?
        var added: Int?
        var removed: Int?
        var endedAt: Date
    }

    struct Day: Codable, Equatable {
        var key: String
        var turns: [Turn] = []
        var files: Set<String> = []
        var commands = 0
        var testsPassed = 0
        var testsFailed = 0
        var allowed = 0
        var denied = 0
        var autoAllowed = 0
        var firstAt: Date?
        var lastAt: Date?

        var tasks: Int { turns.count }
        var tokens: Int { turns.compactMap(\.tokens).reduce(0, +) }
        var cost: Double? {
            let c = turns.compactMap(\.cost)
            return c.isEmpty ? nil : c.reduce(0, +)
        }
        var added: Int { turns.compactMap(\.added).reduce(0, +) }
        var removed: Int { turns.compactMap(\.removed).reduce(0, +) }
        var longest: Double { turns.map(\.duration).max() ?? 0 }
        var isEmpty: Bool { turns.isEmpty && commands == 0 && files.isEmpty && allowed + denied == 0 }

        /// Time spent working, per agent, longest first.
        var agentTime: [(agent: Agent, seconds: Double)] {
            var t: [Agent: Double] = [:]
            for turn in turns { t[Agent(rawValue: turn.agent) ?? .claude, default: 0] += turn.duration }
            return t.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
        }

        var topProject: String? {
            var t: [String: Double] = [:]
            for turn in turns where !turn.project.isEmpty { t[turn.project, default: 0] += max(turn.duration, 1) }
            return t.max { $0.value < $1.value }?.key
        }

        /// Changes whenever the receipt would print differently.
        var signature: String {
            "\(key)|\(tasks)|\(files.count)|\(commands)|\(testsPassed)|\(testsFailed)|\(allowed)|\(denied)|\(tokens)|\(added)|\(removed)"
        }
    }

    struct Lifetime: Codable, Equatable {
        var tasks = 0
        var files = 0
        var tests = 0
        var approvals = 0
    }

    private struct Stored: Codable {
        var today: Day
        var history: [String: Int]  // day key → tasks finished (for streaks)
        var lifetime: Lifetime
        var firstDay: String
        var petName: String?
    }

    @Published private(set) var today: Day
    @Published private(set) var lifetime = Lifetime()
    private(set) var history: [String: Int] = [:]
    private(set) var firstDay: String
    @Published var petName: String { didSet { if petName != oldValue { scheduleSave() } } }

    /// Fired when lifetime XP crosses a level (old, new). Level 0 → 1 is the hatch.
    var onLevelChange: ((Int, Int) -> Void)?

    private let url: URL
    private let io = DispatchQueue(label: "notchbar.ledger", qos: .utility)
    private var saveWork: DispatchWorkItem?
    private let persists: Bool
    private var demo = false

    /// Unit tests never read or write your real stats.
    static let isTesting = NSClassFromString("XCTestCase") != nil

    init(url: URL = DayLedger.defaultURL, persists: Bool = !DayLedger.isTesting) {
        self.url = url
        self.persists = persists
        let key = Self.dayKey(Date())
        if persists, let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder.ledger.decode(Stored.self, from: data) {
            today = s.today
            history = s.history
            lifetime = s.lifetime
            firstDay = s.firstDay
            petName = s.petName ?? Self.randomName()
        } else {
            today = Day(key: key)
            firstDay = key
            petName = Self.randomName()
        }
        rollIfNeeded()
    }

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/NotchBar/ledger.json")
    }

    // MARK: derived

    /// XP: finished tasks matter most, then files touched, tests and approvals.
    var xp: Int { lifetime.tasks * 10 + lifetime.files * 2 + lifetime.tests / 5 + lifetime.approvals }

    /// 0 while still an egg (no task finished yet), then 1, 2, 3… each level needs 100 more XP than the last.
    var level: Int { lifetime.tasks == 0 ? 0 : Self.level(xp: xp) }

    static func level(xp: Int) -> Int {
        Int((1 + (1 + 8 * Double(xp) / 100).squareRoot()) / 2)
    }
    static func xpFor(level: Int) -> Int { 50 * level * (level - 1) }

    /// Progress through the current level, 0…1.
    var levelProgress: Double {
        guard level > 0 else { return 0 }
        let lo = Self.xpFor(level: level), hi = Self.xpFor(level: level + 1)
        return Double(xp - lo) / Double(max(hi - lo, 1))
    }

    /// Consecutive days with at least one finished task, ending today (or yesterday, if today is still empty).
    var streak: Int {
        var counts = history
        counts[today.key] = today.tasks
        var day = Date()
        if (counts[Self.dayKey(day)] ?? 0) == 0 { day = day.addingTimeInterval(-86_400) }
        var n = 0
        while (counts[Self.dayKey(day)] ?? 0) > 0 {
            n += 1
            day = day.addingTimeInterval(-86_400)
        }
        return n
    }

    /// Receipt number: days since NotchBar first ran, starting at 1.
    var receiptNumber: Int {
        guard let a = Self.keyFormatter.date(from: firstDay), let b = Self.keyFormatter.date(from: today.key) else { return 1 }
        return max(1, Int((b.timeIntervalSince(a) / 86_400).rounded()) + 1)
    }

    /// When the last task finished, today or before (nil if never).
    var lastTaskAt: Date? { today.turns.map(\.endedAt).max() ?? lastFinishedBefore }
    private var lastFinishedBefore: Date?

    // MARK: recording

    /// Insert or update a finished turn (tokens and cost often arrive a moment later).
    func turn(key: String, agent: Agent, project: String, receipt: TaskReceipt, endedAt: Date) {
        rollIfNeeded()
        let t = Turn(key: key, agent: agent.rawValue, project: project, duration: receipt.duration,
                     tokens: receipt.tokens, cost: receipt.costUSD, added: receipt.linesAdded,
                     removed: receipt.linesRemoved, endedAt: endedAt)
        if let i = today.turns.firstIndex(where: { $0.key == key }) {
            guard today.turns[i] != t else { return }
            today.turns[i] = t
        } else {
            // A turn that ended before today's 4am boundary belongs to yesterday: skip.
            guard Self.dayKey(endedAt) == today.key else { return }
            mutateLifetime { $0.tasks += 1 }
            today.turns.append(t)
        }
        touch(endedAt)
    }

    func command() { rollIfNeeded(); today.commands += 1; touch() }

    func file(_ path: String) {
        rollIfNeeded()
        guard !path.isEmpty, today.files.insert(path).inserted else { return }
        mutateLifetime { $0.files += 1 }
        touch()
    }

    func tests(passed: Int?, failed: Int) {
        rollIfNeeded()
        let p = passed ?? 0
        today.testsPassed += p
        today.testsFailed += failed
        if p > 0 { mutateLifetime { $0.tests += p } }
        touch()
    }

    func approval(allowed: Bool) {
        rollIfNeeded()
        if allowed { today.allowed += 1 } else { today.denied += 1 }
        mutateLifetime { $0.approvals += 1 }
        touch()
    }

    func autoAllowed() { rollIfNeeded(); today.autoAllowed += 1; touch() }

    private func mutateLifetime(_ change: (inout Lifetime) -> Void) {
        let before = level
        change(&lifetime)
        let after = level
        if after != before { onLevelChange?(before, after) }
    }

    private func touch(_ at: Date = Date()) {
        if today.firstAt == nil || at < today.firstAt! { today.firstAt = at }
        if today.lastAt == nil || at > today.lastAt! { today.lastAt = at }
        scheduleSave()
    }

    /// Days start at 4am, so a late night still counts as the same day.
    static func dayKey(_ d: Date) -> String { keyFormatter.string(from: d.addingTimeInterval(-4 * 3600)) }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func rollIfNeeded() {
        let key = Self.dayKey(Date())
        guard today.key != key else { return }
        if today.tasks > 0 { history[today.key] = today.tasks }
        lastFinishedBefore = today.turns.map(\.endedAt).max() ?? lastFinishedBefore
        // Keep about three months of streak history.
        if history.count > 100 {
            for k in history.keys.sorted().prefix(history.count - 100) { history[k] = nil }
        }
        today = Day(key: key)
        scheduleSave()
    }

    // MARK: persistence

    private func scheduleSave() {
        guard persists, !demo else { return }
        saveWork?.cancel()
        let stored = Stored(today: today, history: history, lifetime: lifetime, firstDay: firstDay, petName: petName)
        let url = url
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder.ledger.encode(stored) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        saveWork = work
        io.asyncAfter(deadline: .now() + 2, execute: work)
    }

    static func randomName() -> String {
        ["mochi", "bao", "tofu", "nugget", "pixel", "byte", "pebble", "noodle", "boba", "biscuit", "miso", "dumpling"]
            .randomElement() ?? "mochi"
    }

    #if DEBUG
    /// Test hook: replace today's numbers in memory only (never saved).
    func debugFill(_ day: Day, lifetime: Lifetime) {
        demo = true
        today = day
        self.lifetime = lifetime
    }
    #endif
}

private extension JSONEncoder {
    static let ledger: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
}
private extension JSONDecoder {
    static let ledger: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
}
