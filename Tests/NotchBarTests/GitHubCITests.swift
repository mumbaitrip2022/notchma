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
        // An agent working in a subfolder still finds the repo.
        let sub = dir.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(Git.root(at: sub.path).map { URL(fileURLWithPath: $0).standardizedFileURL.path },
                       dir.standardizedFileURL.path)
        XCTAssertNil(GitHub.repo(atRoot: sub.path), "the subfolder alone has no git config")
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

    func testJobsBecomePipelineStages() {
        let data = Data("""
        {"jobs":[
          {"name":"Lint","status":"completed","conclusion":"success","started_at":"2026-10-27T10:28:58Z","steps":[]},
          {"name":"Test (macOS 15 · Apple silicon)","status":"completed","conclusion":"success","started_at":"2026-10-27T10:28:58Z","steps":[]},
          {"name":"Test (macOS 14 · Apple silicon)","status":"in_progress","conclusion":null,"started_at":"2026-10-27T10:28:58Z",
           "steps":[{"name":"Build","status":"completed","conclusion":"success"},{"name":"Run swift test","status":"in_progress","conclusion":null}]},
          {"name":"Package (Apple silicon app)","status":"queued","conclusion":null,"started_at":null,"steps":[]}]}
        """.utf8)
        let jobs = GitHub.jobs(fromJSON: data)
        XCTAssertEqual(jobs.count, 4)
        let stages = GitHub.stages(jobs)
        XCTAssertEqual(stages.map(\.name), ["Lint", "Test", "Package"])
        XCTAssertEqual(stages.map(\.state), [.passed, .running, .queued])
        XCTAssertEqual(stages[1].label, "Test 1/2")
        XCTAssertEqual(GitHub.liveStep(jobs), "Test: swift test")
    }

    func testFailedStageAndStep() {
        let jobs = [GitHub.Job(name: "Lint", status: "completed", conclusion: "success"),
                    GitHub.Job(name: "Test (a)", status: "completed", conclusion: "failure", failedStep: "Test"),
                    GitHub.Job(name: "Test (b)", status: "in_progress", conclusion: nil),
                    GitHub.Job(name: "Deploy", status: "completed", conclusion: "skipped")]
        let stages = GitHub.stages(jobs)
        XCTAssertEqual(stages.map(\.state), [.passed, .failed, .skipped])
        XCTAssertEqual(jobs.first(where: \.failed)?.failedStep, "Test")
    }

    func testRunsFallBackToStages() {
        let runs = [GitHub.Run(id: 1, name: "CI", status: "in_progress", conclusion: nil, url: nil),
                    GitHub.Run(id: 2, name: "CodeQL", status: "queued", conclusion: nil, url: nil, path: "codeql.yml")]
        XCTAssertEqual(GitHub.stages(runs: runs), [CIStage(name: "CI", state: .running)])
    }

    func testGitHubMarkPathFillsItsBox() {
        let b = GitHubMark().path(in: CGRect(x: 0, y: 0, width: 32, height: 32)).boundingRect
        XCTAssertEqual(b.minX, 0, accuracy: 0.6)
        XCTAssertEqual(b.maxX, 32, accuracy: 0.6)
        XCTAssertEqual(b.minY, 0, accuracy: 0.6)
        XCTAssertGreaterThan(b.maxY, 30)
        // The arc command lands where it should.
        let arc = SVGPath.parse("M0 8A8 8 0 0 1 16 8").boundingRect
        XCTAssertEqual(arc.minY, 0, accuracy: 0.05)
        XCTAssertEqual(arc.width, 16, accuracy: 0.05)
    }

    func testWorkflowFileGivesTheWholePipeline() {
        let yaml = """
        name: CI
        on:
          push:
        jobs:
          # Stage 1
          lint:
            name: Lint
            steps:
              - name: not a job
          test:
            name: Test (${{ matrix.name }})
            strategy:
              matrix:
                include:
                  - name: macOS 14
          package:
            needs: [lint, test]
            name: "Package (Apple silicon app)"
          gate:
            name: ${{ github.event_name }}
        """
        let planned = GitHub.plannedStages(workflow: yaml)
        XCTAssertEqual(planned, ["Lint", "Test", "Package", "gate"])
        let live = [CIStage(name: "Test", jobs: 3, done: 1, state: .running), CIStage(name: "Lint", state: .passed)]
        XCTAssertEqual(GitHub.merge(live, planned: planned).map(\.name), ["Lint", "Test", "Package", "gate"])
        XCTAssertEqual(GitHub.merge(live, planned: planned).map(\.state), [.passed, .running, .queued, .queued])
        // The real workflow in this repo.
        let ci = try? String(contentsOfFile: #filePath.components(separatedBy: "/Tests/")[0] + "/.github/workflows/ci.yml", encoding: .utf8)
        XCTAssertEqual(ci.map(GitHub.plannedStages(workflow:)), ["Lint", "Test", "Package", "Smoke test", "All checks passed"])
    }

    func testShortJobNames() {
        XCTAssertEqual(GitHub.shortJob("Test (macOS 14 · Apple silicon)"), "Test (macOS 14)")
        XCTAssertEqual(GitHub.shortJob("Test (macOS 14)"), "Test (macOS 14)")
        XCTAssertEqual(GitHub.shortJob("Lint · fast"), "Lint · fast")
    }
}
