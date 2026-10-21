import XCTest
@testable import NotchBar

final class DiagnosticsTests: XCTestCase {
    func testParsesCrashReport() throws {
        let header = #"{"app_name":"NotchBar","app_version":"1.0.6","bug_type":"309"}"#
        let body: [String: Any] = [
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x0"],
            "termination": ["indicator": "Segmentation fault: 11"],
            "usedImages": [["name": "NotchBar"], ["name": "SwiftUI"]],
            "threads": [
                ["frames": [["imageIndex": 1, "symbol": "idle"]]],
                ["triggered": true, "frames": [
                    ["imageIndex": 0, "symbol": "NotchController.notchSizeChanged(_:)"],
                    ["imageIndex": 1, "imageOffset": 4096],
                ]],
            ],
        ]
        let text = header + "\n" + String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
        let c = try XCTUnwrap(Diagnostics.parseIPS(text, file: URL(fileURLWithPath: "/tmp/x.ips"), date: Date()))
        XCTAssertTrue(c.summary.contains("EXC_BAD_ACCESS SIGSEGV"))
        XCTAssertTrue(c.summary.contains("Segmentation fault"))
        XCTAssertEqual(c.frames.first, "NotchBar  NotchController.notchSizeChanged(_:)")
        XCTAssertEqual(c.frames.last, "SwiftUI  0x1000")
    }

    func testCleanRemovesHomeFolder() {
        let s = Diagnostics.clean("crash at \(NSHomeDirectory())/Applications/NotchBar.app and /Users/\(NSUserName())/x")
        XCTAssertFalse(s.contains(NSHomeDirectory()))
        XCTAssertTrue(s.contains("~/Applications/NotchBar.app"))
        XCTAssertTrue(s.contains("~/x"))
    }

    func testReportSectionsAndChoices() {
        let prefs = Prefs()
        var parts = Diagnostics.Parts()
        let full = Diagnostics.report(what: "the card didn't open", parts: parts, prefs: prefs, crash: nil)
        XCTAssertTrue(full.hasPrefix("### What happened\nthe card didn't open"))
        XCTAssertTrue(full.contains("### Mac and app"))
        XCTAssertTrue(full.contains("macOS "))
        XCTAssertFalse(full.contains("### Crash"))
        print("SAMPLE REPORT\n" + full)

        parts.includeEnvironment = false
        let bare = Diagnostics.report(what: "", parts: parts, prefs: prefs, crash: nil)
        XCTAssertFalse(bare.contains("### Mac and app"))
        XCTAssertTrue(bare.contains("describe what you saw"))
    }

    func testIssueURLIsTrimmedAndPrefilled() throws {
        let long = String(repeating: "x", count: 20_000)
        let url = try XCTUnwrap(Diagnostics.issueURL(title: "Card stuck", body: long))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/\(Updater.repo)/issues/new?"))
        XCTAssertLessThan(url.absoluteString.count, 8_000)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "Card stuck")
        XCTAssertTrue(items.first { $0.name == "body" }?.value?.contains("trimmed") == true)
    }
}
