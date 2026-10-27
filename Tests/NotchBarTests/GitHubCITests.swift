import XCTest
@testable import NotchBar

final class GitHubCITests: XCTestCase {
    func testRepoFromRemote() {
        XCTAssertEqual(GitHub.repo(fromRemote: "git@github.com:mumbaitrip2022/notchma.git"), "mumbaitrip2022/notchma")
        XCTAssertEqual(GitHub.repo(fromRemote: "https://github.com/a/b"), "a/b")
        XCTAssertEqual(GitHub.repo(fromRemote: "https://github.com/a/b.git/"), "a/b")
        XCTAssertEqual(GitHub.repo(fromRemote: "ssh://git@github.com/a/b.git"), "a/b")
        XCTAssertEqual(GitHub.repo(fromRemote: "https://token@github.com/a/b.git"), "a/b")
        XCTAssertNil(GitHub.repo(fromRemote: "git@gitlab.com:a/b.git"))
        XCTAssertNil(GitHub.repo(fromRemote: "https://github.com/a"))
    }

    func testRepoFromGitConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ci-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = git@github.com:other/thing.git
        [remote "origin"]
        \turl = git@github.com:me/app.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """.write(to: dir.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHub.repo(atRoot: dir.path), "me/app")
    }

    func testPushDetection() {
        XCTAssertTrue(GitHub.isPush("git push"))
        XCTAssertTrue(GitHub.isPush("git push origin main"))
        XCTAssertTrue(GitHub.isPush("git add -A && git commit -m x && git push -u origin feat"))
        XCTAssertTrue(GitHub.isPush("git -C ~/app push"))
        XCTAssertTrue(GitHub.isPush("bash -lc 'git push origin main'"))
        XCTAssertFalse(GitHub.isPush("git push --dry-run"))
        XCTAssertFalse(GitHub.isPush("git push origin --delete old"))
        XCTAssertFalse(GitHub.isPush("git pull"))
        XCTAssertFalse(GitHub.isPush("echo pushing"))
    }

    func testSummarizeRuns() {
        func run(_ status: String, _ conclusion: String? = nil, _ name: String = "CI") -> GitHub.Run {
            .init(id: Int.random(in: 1...999_999), name: name, status: status, conclusion: conclusion, url: nil)
        }
        XCTAssertEqual(GitHub.summarize([]), .waiting)
        XCTAssertEqual(GitHub.summarize([run("in_progress"), run("completed", "success")]), .running(done: 1, total: 2))
        XCTAssertEqual(GitHub.summarize([run("completed", "success"), run("completed", "skipped")]), .passed)
        XCTAssertEqual(GitHub.summarize([run("completed", "success"), run("completed", "failure", "Lint")]), .failed(job: "Lint"))
        XCTAssertEqual(GitHub.summarize([run("completed", "cancelled")]), .passed, "a cancelled run isn't a failure")
        XCTAssertEqual(GitHub.summarize([run("in_progress"), run("completed", "failure", "Lint")]), .failed(job: "Lint"),
                       "a failure shows right away")
    }

    func testSlowScansDontHoldUpCI() {
        var codeql = GitHub.Run(id: 1, name: "CodeQL", status: "in_progress", conclusion: nil, url: nil, path: ".github/workflows/codeql.yml")
        let pages = GitHub.Run(id: 2, name: "pages build and deployment", status: "in_progress", conclusion: nil, url: nil, event: "dynamic")
        let ci = GitHub.Run(id: 3, name: "CI", status: "completed", conclusion: "success", url: nil)
        XCTAssertEqual(GitHub.summarize([codeql, pages, ci]), .passed)
        XCTAssertEqual(GitHub.summarize([codeql]), .running(done: 0, total: 1), "extras count when they're all there is")
        codeql.status = "completed"; codeql.conclusion = "success"
        XCTAssertEqual(GitHub.summarize([codeql]), .passed)
    }

    func testParsesRunsAndJobs() {
        let runs = Data("""
        {"total_count":2,"workflow_runs":[
          {"id":1,"name":"CI","status":"completed","conclusion":"failure","html_url":"https://github.com/a/b/actions/runs/1"},
          {"id":2,"name":"CodeQL","status":"in_progress","conclusion":null,"html_url":"https://github.com/a/b/actions/runs/2"}]}
        """.utf8)
        let parsed = GitHub.runs(fromJSON: runs)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(GitHub.focus(parsed)?.id, 1, "the failed run is the one to open")
        let jobs = Data("""
        {"jobs":[{"name":"Lint","conclusion":"success"},{"name":"Test (macOS 14)","conclusion":"failure"}]}
        """.utf8)
        XCTAssertEqual(GitHub.failedJob(fromJSON: jobs), "Test (macOS 14)")
        XCTAssertTrue(GitHub.runs(fromJSON: Data("nope".utf8)).isEmpty)
    }
}
