import Foundation

/// Reads test-runner summaries out of command output. Covers the common
/// runners; returns the *last* summary found, since that's the final result.
enum TestParser {
    private struct Pattern {
        let regex: NSRegularExpression
        let read: ([String]) -> TestResult?
    }

    private static func re(_ p: String) -> NSRegularExpression {
        // Patterns are constants; a failure here is a programming error caught in tests.
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    private static func int(_ s: String) -> Int? { Int(s.trimmingCharacters(in: .whitespaces)) }

    private static let patterns: [Pattern] = [
        // jest: "Tests:       2 failed, 40 passed, 42 total"
        Pattern(regex: re(#"Tests:\s+(?:(\d+) failed,\s*)?(?:\d+ skipped,\s*)?(?:(\d+) passed,\s*)?\d+ total"#)) { g in
            TestResult(passed: int(g[2]), failed: int(g[1]) ?? 0)
        },
        // vitest: "Tests  2 failed | 40 passed (42)"
        Pattern(regex: re(#"Tests\s+(?:(\d+) failed\s*\|\s*)?(\d+) passed"#)) { g in
            TestResult(passed: int(g[2]), failed: int(g[1]) ?? 0)
        },
        // pytest: "== 2 failed, 40 passed in 1.23s ==" / "== 42 passed in"
        Pattern(regex: re(#"=+ (?:(\d+) failed)?(?:, )?(?:(\d+) passed)?(?:, \d+ \w+)* in [\d.]+s"#)) { g in
            guard g[1] != "" || g[2] != "" else { return nil }
            return TestResult(passed: int(g[2]), failed: int(g[1]) ?? 0)
        },
        // XCTest: "Executed 42 tests, with 2 failures"
        Pattern(regex: re(#"Executed (\d+) tests?, with (\d+) failures?"#)) { g in
            guard let total = int(g[1]), let f = int(g[2]) else { return nil }
            return TestResult(passed: total - f, failed: f)
        },
        // swift-testing: "Test run with 42 tests passed" / "with 42 tests failed after … with 2 issues"
        Pattern(regex: re(#"Test run with (\d+) tests? (passed|failed)"#)) { g in
            g[2].lowercased() == "passed" ? TestResult(passed: int(g[1]), failed: 0) : TestResult(passed: nil, failed: 1)
        },
        // cargo: "test result: FAILED. 40 passed; 2 failed"
        Pattern(regex: re(#"test result: \w+\. (\d+) passed; (\d+) failed"#)) { g in
            TestResult(passed: int(g[1]), failed: int(g[2]) ?? 0)
        },
        // rspec: "42 examples, 2 failures"
        Pattern(regex: re(#"(\d+) examples?, (\d+) failures?"#)) { g in
            guard let total = int(g[1]), let f = int(g[2]) else { return nil }
            return TestResult(passed: total - f, failed: f)
        },
        // mocha: "40 passing" … "2 failing"
        Pattern(regex: re(#"(\d+) passing(?:[\s\S]*?(\d+) failing)?"#)) { g in
            TestResult(passed: int(g[1]), failed: int(g[2]) ?? 0)
        },
        // phpunit: "OK (42 tests, 80 assertions)" / "Tests: 42, Assertions: 80, Failures: 2"
        Pattern(regex: re(#"OK \((\d+) tests?"#)) { g in TestResult(passed: int(g[1]), failed: 0) },
        Pattern(regex: re(#"Tests: (\d+), Assertions: \d+, (?:Errors: (\d+), )?Failures: (\d+)"#)) { g in
            guard let total = int(g[1]) else { return nil }
            let f = (int(g[2]) ?? 0) + (int(g[3]) ?? 0)
            return TestResult(passed: total - f, failed: f)
        },
        // dotnet: "Failed!  - Failed:     2, Passed:    40"
        Pattern(regex: re(#"(?:Passed|Failed)!\s+-\s+Failed:\s+(\d+), Passed:\s+(\d+)"#)) { g in
            TestResult(passed: int(g[2]), failed: int(g[1]) ?? 0)
        },
        // go: "--- FAIL:" lines or "ok  	pkg"
        Pattern(regex: re(#"^(?:ok|FAIL)\s+\S+\s+[\d.]+s"#)) { _ in nil }, // handled below
    ]

    static func parse(_ output: String) -> TestResult? {
        let ns = output as NSString
        let range = NSRange(location: 0, length: ns.length)
        var best: (loc: Int, result: TestResult)?
        for p in patterns {
            for m in p.regex.matches(in: output, range: range) {
                var groups: [String] = []
                for i in 0..<m.numberOfRanges {
                    let r = m.range(at: i)
                    groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
                }
                if let res = p.read(groups), best == nil || m.range.location >= best!.loc {
                    best = (m.range.location, res)
                }
            }
        }
        if let best { return best.result }
        // go test: count package results.
        let lines = output.split(separator: "\n")
        let failed = lines.filter { $0.hasPrefix("--- FAIL:") }.count
        let okPkgs = lines.filter { $0.hasPrefix("ok  ") || $0.hasPrefix("ok\t") }.count
        if failed > 0 || lines.contains(where: { $0.hasPrefix("FAIL\t") || $0 == "FAIL" }) {
            return TestResult(passed: nil, failed: max(failed, 1))
        }
        if okPkgs > 0 { return TestResult(passed: nil, failed: 0) }
        return nil
    }
}
