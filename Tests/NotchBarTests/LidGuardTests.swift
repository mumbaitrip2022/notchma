import XCTest
@testable import NotchBar

/// Runs the real root helper script against a fake pmset in a temp folder.
final class LidGuardTests: XCTestCase {
    private var dir: URL!
    private var hb: String { dir.appendingPathComponent("it's here/lid-awake").path }
    private var log: String { dir.appendingPathComponent("pmset.log").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidguard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("it's here"), withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("pmset")
        try "#!/bin/sh\necho \"$@\" >> '\(log)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Run the helper once; returns the pmset calls it made.
    private func runGuard() throws -> [String] {
        try? FileManager.default.removeItem(atPath: log)
        let script = LidGuard.guardScript(heartbeat: hb)
            .replacingOccurrences(of: "/usr/bin/pmset", with: dir.appendingPathComponent("pmset").path)
            .replacingOccurrences(of: LidGuard.supportDir, with: dir.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let out = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return out.split(separator: "\n").map(String.init)
    }

    private func beat(ageSeconds: TimeInterval = 0) {
        FileManager.default.createFile(atPath: hb, contents: Data())
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: hb)
    }

    func testHoldsOnlyWhileHeartbeatIsFresh() throws {
        XCTAssertEqual(try runGuard(), [], "no heartbeat, nothing ours: never touch sleep")
        beat()
        XCTAssertEqual(try runGuard(), ["-a disablesleep 1"])
        XCTAssertEqual(try runGuard(), [], "already on: no repeat calls")
        try FileManager.default.removeItem(atPath: hb)
        XCTAssertEqual(try runGuard(), ["-a disablesleep 0"])
        XCTAssertEqual(try runGuard(), [])
    }

    func testStaleHeartbeatGivesSleepBack() throws {
        beat()
        _ = try runGuard()
        beat(ageSeconds: Double(LidGuard.staleAfter) + 30)   // NotchBar crashed or hung
        XCTAssertEqual(try runGuard(), ["-a disablesleep 0"])
    }

    func testStaleHeartbeatAloneDoesNothing() throws {
        beat(ageSeconds: 600)
        XCTAssertEqual(try runGuard(), [])
    }

    func testScriptsAreValidShellAndPlist() throws {
        for script in [LidGuard.installScript(heartbeat: hb), LidGuard.removeScript, LidGuard.guardScript(heartbeat: hb)] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-n", "-c", script]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let plist = try PropertyListSerialization.propertyList(from: Data(LidGuard.plist(heartbeat: hb).utf8), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["Label"] as? String, LidGuard.label)
        XCTAssertEqual(plist?["WatchPaths"] as? [String], [(hb as NSString).deletingLastPathComponent])
        XCTAssertTrue(LidGuard.guardScript(heartbeat: hb).contains("# version \(LidGuard.version)\n"))
    }

    func testParsesPmset() {
        XCTAssertTrue(LidGuard.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"))
        XCTAssertFalse(LidGuard.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t0\n"))
        XCTAssertFalse(LidGuard.parseSleepDisabled("Currently in use:\n sleep 1 (sleep prevented by powerd)\n"))
    }
}
