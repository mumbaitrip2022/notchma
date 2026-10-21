import XCTest
@testable import NotchBar

final class SystemMonitorTests: XCTestCase {
    private func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// Live sampling must be cheap and produce sane values.
    func testLiveSamplingIsCheapAndSane() {
        // Baseline: what the test harness costs while just waiting.
        let b0 = cpuSeconds()
        let idle = expectation(description: "idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { idle.fulfill() }
        wait(for: [idle], timeout: 10)
        let baseline = cpuSeconds() - b0

        let m = SystemMonitor()
        m.agentRoots = { [getpid()] }
        let before = cpuSeconds()
        m.setLive(true)
        let exp = expectation(description: "samples")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exp.fulfill() }
        wait(for: [exp], timeout: 10)
        m.setLive(false)
        let used = max(0, cpuSeconds() - before - baseline)
        let percent = used / 6 * 100
        print("SystemMonitor live sampling: \(String(format: "%.2f", percent))% of one core (harness baseline removed)")
        // Intel cores are slower, and shared CI Intel machines run other tests at the same time.
        #if arch(x86_64)
        let budget = 5.0
        #else
        let budget = 2.0
        #endif
        XCTAssertLessThan(percent, budget, "live sampling should stay under \(budget)% of a core")
        XCTAssertTrue(m.cpuReady)
        XCTAssert((0...100).contains(m.cpu))
        XCTAssertGreaterThan(m.memUsed, 0)
        XCTAssertLessThanOrEqual(m.memUsed, m.memTotal)
        XCTAssertGreaterThan(m.diskTotal, m.diskFree)
        XCTAssertGreaterThan(m.diskFree, 0)
    }
}
