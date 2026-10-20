import EventKit
import Foundation

/// Knows when you're in (or about to start) a meeting, so the notch can stay
/// quiet during it and remind you about waiting agents beforehand. Opt-in.
final class CalendarWatcher: ObservableObject {
    @Published private(set) var meeting: String?          // title of the meeting you're in
    @Published private(set) var access: Access = .unknown

    enum Access { case unknown, granted, denied }

    var enabled: () -> Bool = { false }
    var onUpcoming: ((_ title: String, _ minutes: Int) -> Void)?
    var onMeetingEnded: ((_ title: String) -> Void)?

    private let eventStore = EKEventStore()
    private var timer: Timer?
    private var warned = Set<String>()

    init() {
        refreshAccess()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 20
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) {
            [weak self] _ in self?.check()
        }
    }

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .denied, .restricted, .writeOnly: access = .denied
        default: access = .unknown
        }
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        eventStore.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                self.refreshAccess()
                self.check()
                done(granted)
            }
        }
    }

    func check() {
        guard enabled(), access == .granted else {
            if meeting != nil { meeting = nil }
            return
        }
        let now = Date()
        let predicate = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                      end: now.addingTimeInterval(15 * 60), calendars: nil)
        let events = eventStore.events(matching: predicate).filter(isRealMeeting)

        let current = events.first { $0.startDate <= now && $0.endDate > now }
        let title = current.map { $0.title?.isEmpty == false ? $0.title! : "a meeting" }
        if meeting != title {
            if let ended = meeting, title == nil { onMeetingEnded?(ended) }
            meeting = title
        }
        for e in events where e.startDate > now && e.startDate.timeIntervalSince(now) <= 10 * 60 {
            let id = (e.eventIdentifier ?? e.title ?? "") + "\(e.startDate.timeIntervalSince1970)"
            guard warned.insert(id).inserted else { continue }
            onUpcoming?(e.title?.isEmpty == false ? e.title! : "Meeting", max(1, Int(e.startDate.timeIntervalSince(now) / 60)))
        }
        if warned.count > 200 { warned.removeAll() }
    }

    /// Timed, busy, not cancelled, not declined.
    private func isRealMeeting(_ e: EKEvent) -> Bool {
        guard !e.isAllDay, e.availability != .free, e.status != .canceled else { return false }
        if let me = e.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return false }
        return true
    }
}
