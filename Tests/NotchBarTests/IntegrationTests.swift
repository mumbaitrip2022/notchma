import XCTest
@testable import NotchBar

/// Exercises real git in a throwaway repository.
final class GitIntegrationTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("nb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = Shell.which("git") ?? "/usr/bin/git"
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            XCTAssertTrue(Shell.run(git, ["-C", repo.path] + args)?.ok ?? false)
        }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(Shell.run(git, ["-C", repo.path, "add", "."])?.ok ?? false)
        XCTAssertTrue(Shell.run(git, ["-C", repo.path, "commit", "-qm", "init"])?.ok ?? false)
    }

    override func tearDownWithError() throws {
        let worktrees = repo.deletingLastPathComponent().appendingPathComponent(repo.lastPathComponent + ".worktrees")
        try? FileManager.default.removeItem(at: worktrees)
        try? FileManager.default.removeItem(at: repo)
    }

    func testDiffIncludesModifiedAndNewFiles() throws {
        XCTAssertEqual(Review.diffText(root: repo.path)?.isEmpty, true)
        try "two\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let diff = try XCTUnwrap(Review.diffText(root: repo.path))
        XCTAssertTrue(diff.contains("-one") && diff.contains("+two"))
        XCTAssertTrue(diff.contains("b.txt") && diff.contains("+new"))
    }

    func testWorktreeCreatesBranchAndFolder() throws {
        guard case let .success(dir) = Launcher.makeWorktree(project: repo.path, prompt: "Fix the login bug!") else {
            return XCTFail("worktree failed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/a.txt"))
        XCTAssertTrue((dir as NSString).lastPathComponent.hasPrefix("fix-the-login-bug-"))
        XCTAssertEqual(Git.branch(at: dir)?.hasPrefix("notchbar/fix-the-login-bug-"), true)
    }

    func testWorktreeRejectsNonRepo() {
        guard case .failure = Launcher.makeWorktree(project: NSTemporaryDirectory(), prompt: "x") else {
            return XCTFail("should fail outside a repo")
        }
    }

    func testLaunchCommandQuotesEverything() {
        let cmd = Launcher.command(cliPath: "/usr/local/bin/claude", dir: "/tmp/it's here", prompt: "say \"hi\" && rm -rf /")
        XCTAssertEqual(cmd, #"cd '/tmp/it'\''s here' && '/usr/local/bin/claude' 'say "hi" && rm -rf /'"#)
    }

    func testShellHandlesLargeOutputWithoutDeadlock() {
        let r = Shell.run("/bin/sh", ["-c", "yes 0123456789 | head -c 3000000"], timeout: 10)
        XCTAssertEqual(r?.stdout.count, 3_000_000)
    }

    func testShellTimeout() {
        let start = Date()
        XCTAssertNil(Shell.run("/bin/sleep", ["5"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
