import XCTest
@testable import NotchBar

final class UpdaterTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(Updater.isNewer("1.0.6", than: "1.0.5"))
        XCTAssertTrue(Updater.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertTrue(Updater.isNewer("1.1", than: "1.0.9"))
        XCTAssertTrue(Updater.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertFalse(Updater.isNewer("1.0.5", than: "1.0.5"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0.4", than: "1.0.5"))
    }

    private func json(_ extra: [String: Any] = [:], assets: [[String: Any]]? = nil) -> Data {
        var j: [String: Any] = [
            "tag_name": "v1.2.3", "name": "NotchBar 1.2.3", "draft": false, "prerelease": false,
            "html_url": "https://github.com/mumbaitrip2022/notchma/releases/tag/v1.2.3",
            "body": "## Big one 🎁\n\n**Stuff**\n- First **thing**\n- Second `thing`\n\n### Update\nnot a bullet",
            "assets": assets ?? [
                ["name": "NotchBar-1.2.3.dmg", "size": 10, "browser_download_url": "https://github.com/a/b.dmg"],
                ["name": "NotchBar-1.2.3.zip", "size": 2_000_000, "digest": "sha256:abc123",
                 "browser_download_url": "https://github.com/mumbaitrip2022/notchma/releases/download/v1.2.3/NotchBar-1.2.3.zip"],
            ],
        ]
        for (k, v) in extra { j[k] = v }
        return try! JSONSerialization.data(withJSONObject: j)
    }

    func testParseRelease() throws {
        let r = try XCTUnwrap(Updater.parse(json()))
        XCTAssertEqual(r.version, "1.2.3")
        XCTAssertEqual(r.sha256, "abc123")
        XCTAssertTrue(r.zipURL.absoluteString.hasSuffix(".zip"))
        XCTAssertEqual(r.headline, "Big one 🎁")
        XCTAssertEqual(r.highlights, ["First thing", "Second thing"])
    }

    func testRejectsDraftsPrereleasesAndForeignHosts() {
        XCTAssertNil(Updater.parse(json(["draft": true])))
        XCTAssertNil(Updater.parse(json(["prerelease": true])))
        XCTAssertNil(Updater.parse(json(assets: [["name": "NotchBar.zip", "size": 1,
                                                 "browser_download_url": "https://evil.example.com/NotchBar.zip"]])))
        XCTAssertNil(Updater.parse(json(assets: [["name": "NotchBar.zip", "size": 1,
                                                 "browser_download_url": "http://github.com/NotchBar.zip"]])))
        XCTAssertNil(Updater.parse(json(assets: [])))
    }
}
