import XCTest
@testable import NotchBar

final class KeepAwakeTests: XCTestCase {
    private var working = false
    private var auto = true
    private var power = true
    private var batteryStops = 0

    private func make() -> KeepAwake {
        let k = KeepAwake()
        k.autoEnabled = { [unowned self] in self.auto }
        k.agentsWorking = { [unowned self] in self.working }
        k.powerAllows = { [unowned self] _ in self.power }
        k.onBatteryStop = { [unowned self] in self.batteryStops += 1 }
        return k
    }

    func testHoldsOnlyWhileAgentsWork() {
        let k = make()
        k.refresh()
        XCTAssertNil(k.reason)
        working = true; k.refresh()
        XCTAssertEqual(k.reason, .agents)
        working = false; k.refresh()
        XCTAssertNil(k.reason)
    }

    func testAutoOffIgnoresAgents() {
        auto = false; working = true
        let k = make()
        k.refresh()
        XCTAssertNil(k.reason)
    }

    func testManualWinsAndStops() {
        let k = make()
        working = true
        k.start(minutes: 30)
        XCTAssertEqual(k.reason, .manual)
        k.stop()
        XCTAssertEqual(k.reason, .agents)
        working = false; k.refresh()
        XCTAssertNil(k.reason)
    }

    func testExtendIsCappedAtADay() {
        let k = make()
        k.start(minutes: 23 * 60 + 50)
        k.extend(minutes: 15)
        k.extend(minutes: 15)
        XCTAssertLessThanOrEqual(k.until!.timeIntervalSinceNow, KeepAwake.maxSession + 1)
        k.stop()
    }

    func testUnlimitedCannotBeExtended() {
        let k = make()
        k.start(minutes: nil)
        k.extend(minutes: 15)
        XCTAssertTrue(k.isUnlimited)
        k.stop()
    }

    func testLowBatteryEndsManualAndPausesAuto() {
        let k = make()
        k.start(minutes: 60)
        power = false; k.refresh()
        XCTAssertFalse(k.isManual)
        XCTAssertEqual(batteryStops, 1)
        XCTAssertNil(k.reason)

        working = true; k.refresh()
        XCTAssertNil(k.reason)
        XCTAssertTrue(k.pausedForBattery)
        power = true; k.refresh()
        XCTAssertEqual(k.reason, .agents)
        XCTAssertFalse(k.pausedForBattery)
        working = false; k.refresh()
    }

    func testLabels() {
        let now = Date()
        XCTAssertEqual(KeepAwake.remaining(until: now.addingTimeInterval(12 * 60 - 5), now: now), "12 min left")
        XCTAssertEqual(KeepAwake.remaining(until: now.addingTimeInterval(102 * 60), now: now), "1:42 left")
        XCTAssertEqual(KeepAwake.remaining(until: .distantFuture, now: now), "until you stop it")
        XCTAssertEqual(KeepAwake.presets.map(KeepAwake.presetTitle), ["30 Minutes", "1 Hour", "2 Hours", "4 Hours"])
    }
}
