import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while agents work, or for a while on request.
///
/// Uses the same macOS power request as `caffeinate -i`: the display can still
/// turn off, and closing the lid or choosing Sleep still sleeps the Mac. macOS
/// drops the request by itself if NotchBar quits or crashes, so nothing can stick.
final class KeepAwake: ObservableObject {
    enum Reason: Equatable { case agents, manual }

    /// End of a manual session. `.distantFuture` means until you stop it.
    @Published private(set) var until: Date?
    /// Why the Mac is being kept awake right now (nil: it isn't).
    @Published private(set) var reason: Reason?
    /// Agents are working, but the battery is below the floor, so sleep is allowed.
    @Published private(set) var pausedForBattery = false
    /// Also holding through a closed lid right now.
    @Published private(set) var lidHeld = false

    // Injected by the controller.
    var autoEnabled: () -> Bool = { true }
    /// Lowest battery percentage to keep going at. 100 means only while plugged in.
    var batteryFloor: () -> Int = { 20 }
    var agentsWorking: () -> Bool = { false }
    /// Is there enough power to keep going at this battery floor? Swappable for tests.
    var powerAllows: (Int) -> Bool = KeepAwake.powerAllows(floor:)
    /// Should the Mac also stay awake with the lid closed (set up, switched on, not too hot)?
    var lidMode: () -> Bool = { false }
    /// Tell the closed-lid helper to hold (true) or let go (false). Called on every refresh.
    var setLid: (Bool) -> Void = { _ in }
    /// A manual session ended early because of the battery floor.
    var onBatteryStop: (() -> Void)?

    static let presets = [30, 60, 120, 240]
    static let maxSession: TimeInterval = 24 * 3600

    private var assertion = IOPMAssertionID(0)
    private var heldFor: Reason?
    private var timer: Timer?

    var isManual: Bool { until != nil }
    var isUnlimited: Bool { until == .distantFuture }

    /// Start a manual session. nil minutes means until you stop it.
    func start(minutes: Int?) {
        until = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
        refresh()
    }

    /// Add time to a timed manual session, never past 24 hours from now.
    func extend(minutes: Int) {
        guard let u = until, u != .distantFuture else { return }
        until = min(max(u, Date()).addingTimeInterval(Double(minutes) * 60), Date().addingTimeInterval(Self.maxSession))
        refresh()
    }

    func stop() {
        until = nil
        refresh()
    }

    /// Re-evaluate everything. Cheap; call it whenever sessions or settings change.
    func refresh() {
        if let u = until, u <= Date() { until = nil }
        let want: Reason? = until != nil ? .manual : (autoEnabled() && agentsWorking() ? .agents : nil)
        let powerOK = want == nil || powerAllows(batteryFloor())

        if want == .manual && !powerOK {
            until = nil
            onBatteryStop?()
            return refresh()
        }
        pausedForBattery = want == .agents && !powerOK
        hold(powerOK ? want : nil)
        if reason != heldFor { reason = heldFor }
        let lid = heldFor != nil && lidMode()
        if lidHeld != lid { lidHeld = lid }
        setLid(lid)
        // While something wants the Mac awake, keep checking the clock and the battery.
        setTimer(want != nil)
    }

    // MARK: power request

    private func hold(_ r: Reason?) {
        guard r != heldFor else { return }
        release()
        guard let r else { return }
        let name = r == .agents ? "NotchBar: agents are working" : "NotchBar: keep awake"
        var id = IOPMAssertionID(0)
        let ok = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        if ok == kIOReturnSuccess {
            assertion = id
            heldFor = r
        } else {
            NSLog("NotchBar: keep awake request failed (\(ok))")
        }
    }

    private func release() {
        if heldFor != nil { IOPMAssertionRelease(assertion) }
        assertion = IOPMAssertionID(0)
        heldFor = nil
    }

    private func setTimer(_ on: Bool) {
        if !on {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: battery

    /// On a charger, or a Mac without a battery: always fine. On battery: above the floor.
    static func powerAllows(floor: Int) -> Bool {
        guard let level = batteryLevel() else { return true }
        if level.pluggedIn { return true }
        return floor < 100 && level.percent > floor
    }

    /// Battery percentage and whether it is plugged in, or nil on a Mac without a battery.
    static func batteryLevel() -> (percent: Int, pluggedIn: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (cur * 100 / max, onAC)
        }
        return nil
    }

    // MARK: labels

    /// "1:42 left", "12 min left" or "until you stop it".
    static func remaining(until: Date, now: Date = Date()) -> String {
        if until == .distantFuture { return "until you stop it" }
        let mins = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        if mins < 60 { return "\(mins) min left" }
        return String(format: "%d:%02d left", mins / 60, mins % 60)
    }

    static func presetTitle(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) Minutes" : minutes == 60 ? "1 Hour" : "\(minutes / 60) Hours"
    }
}
