import Foundation

/// Notices when two live sessions edit the same file within a short window —
/// the moment parallel agents start overwriting each other.
final class ConflictTracker {
    struct Conflict: Equatable {
        let file: String
        let otherSession: String
    }

    private var edits: [String: [String: Date]] = [:] // file → session → last edit
    private var reported = Set<String>()
    private let window: TimeInterval = 30 * 60

    /// Record an edit; returns a conflict the first time another session touched the same file recently.
    func record(file: String, session: String, liveSessions: Set<String>, now: Date = Date()) -> Conflict? {
        var bySession = edits[file] ?? [:]
        bySession[session] = now
        bySession = bySession.filter { now.timeIntervalSince($0.value) < window && liveSessions.contains($0.key) }
        edits[file] = bySession
        guard let other = bySession.keys.filter({ $0 != session }).sorted().first else { return nil }
        let key = [file, min(session, other), max(session, other)].joined(separator: "|")
        guard reported.insert(key).inserted else { return nil }
        return Conflict(file: file, otherSession: other)
    }

    func forget(session: String) {
        for (file, var bySession) in edits {
            bySession[session] = nil
            edits[file] = bySession.isEmpty ? nil : bySession
        }
    }

    /// Bounded memory for long-running apps.
    func prune(now: Date = Date()) {
        edits = edits.compactMapValues { m in
            let kept = m.filter { now.timeIntervalSince($0.value) < window }
            return kept.isEmpty ? nil : kept
        }
        if reported.count > 500 { reported.removeAll() }
    }
}
