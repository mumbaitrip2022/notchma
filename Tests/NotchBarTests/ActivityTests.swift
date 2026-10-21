import XCTest
@testable import NotchBar

final class ActivityTests: XCTestCase {
    func testTodoWritePlan() {
        var plan: [PlanItem] = []
        PlanParser.apply(tool: "TodoWrite", input: ["todos": [
            ["content": "Add totals", "activeForm": "Adding totals", "status": "completed"],
            ["content": "Write tests", "activeForm": "Writing tests", "status": "in_progress"],
            ["content": "Update docs", "activeForm": "Updating docs", "status": "pending"],
        ]], to: &plan)
        XCTAssertEqual(plan.map(\.status), [.done, .active, .pending])
        XCTAssertEqual(plan[1].activeText, "Writing tests")
    }

    func testTaskCreateAndUpdate() {
        var plan: [PlanItem] = []
        PlanParser.apply(tool: "TaskCreate", input: ["subject": "Fix login", "activeForm": "Fixing login"], to: &plan)
        PlanParser.apply(tool: "TaskCreate", input: ["subject": "Add tests"], to: &plan)
        PlanParser.apply(tool: "TaskUpdate", input: ["taskId": "1", "status": "in_progress"], to: &plan)
        PlanParser.apply(tool: "TaskUpdate", input: ["taskId": "1", "status": "completed"], to: &plan)
        PlanParser.apply(tool: "TaskUpdate", input: ["taskId": "2", "status": "in_progress"], to: &plan)
        XCTAssertEqual(plan.map(\.status), [.done, .active])
        PlanParser.apply(tool: "TaskUpdate", input: ["taskId": "99", "status": "completed"], to: &plan) // unknown id: ignored
        XCTAssertEqual(plan.count, 2)
    }

    func testCodexPlan() {
        var plan: [PlanItem] = []
        PlanParser.apply(tool: "update_plan", input: ["plan": [["step": "Inspect", "status": "completed"],
                                                               ["step": "Patch", "status": "in_progress"]]], to: &plan)
        XCTAssertEqual(plan.map(\.text), ["Inspect", "Patch"])
        XCTAssertEqual(plan[1].status, .active)
    }

    func testNarrationHeadline() {
        XCTAssertEqual(Narration.headline("Now I'll update the tests. Then run them."), "Now I'll update the tests")
        XCTAssertEqual(Narration.headline("**Inspecting auth middleware**\n\nLooking at…"), "Inspecting auth middleware")
        XCTAssertEqual(Narration.headline("Let me check `cart.ts`:"), "Let me check cart.ts")
        XCTAssertNil(Narration.headline("```swift\nlet x = 1\n```"))
        XCTAssertNil(Narration.headline("Ok."))
    }

    func testLiveLinePriority() {
        var s = Session(id: "s", cwd: "/p", pid: 0, termProgram: "", bundleID: "")
        s.status = .thinking
        XCTAssertEqual(s.liveLine, "Thinking…") // last resort only
        s.actions = [ActionRecord(tool: "Edit", detail: "cart.ts", phase: .edit, at: Date(), ok: true)]
        XCTAssertEqual(s.liveLine, "Edited cart.ts")
        s.plan = [PlanItem(id: "1", text: "Write tests", activeText: "Writing tests", status: .active)]
        XCTAssertEqual(s.liveLine, "Writing tests")
        s.intent = "Checking the edge cases"; s.intentAt = Date()
        XCTAssertEqual(s.liveLine, "Checking the edge cases")
        XCTAssertEqual(s.compactLine, "Writing tests") // the island prefers the plan step
        s.status = .tool(name: "Bash", detail: "npm test")
        XCTAssertEqual(s.liveLine, "Running npm test")
        s.intentAt = Date().addingTimeInterval(-600) // stale narration is ignored
        s.status = .thinking
        XCTAssertEqual(s.liveLine, "Writing tests")
    }

    func testPastTenseWithTestNote() {
        var a = ActionRecord(tool: "Bash", detail: "npm test", phase: .test, at: Date(), ok: true)
        a.note = "✓ 24 passed"
        XCTAssertEqual(a.pastTense, "Ran npm test · ✓ 24 passed")
        XCTAssertEqual(ActionRecord(tool: "Bash", detail: "make", phase: .build, at: Date(), ok: false).pastTense, "Built make · failed")
    }

    func testPhases() {
        XCTAssertEqual(Phase.of(tool: "Bash", input: ["command": "npm test"]), .test)
        XCTAssertEqual(Phase.of(tool: "Bash", input: ["command": "git commit -m x"]), .git)
        XCTAssertEqual(Phase.of(tool: "Bash", input: ["command": "pnpm install"]), .install)
        XCTAssertEqual(Phase.of(tool: "Bash", input: ["command": "swift build -c release"]), .build)
        XCTAssertEqual(Phase.of(tool: "Grep", input: [:]), .explore)
        XCTAssertEqual(Phase.of(tool: "apply_patch", input: [:]), .edit)
    }

    func testClaudeNarrationRespectsTurnBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let old = f.string(from: Date().addingTimeInterval(-300)), now = f.string(from: Date())
        func line(_ ts: String, _ text: String) -> String {
            #"{"type":"assistant","timestamp":"\#(ts)","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
        }
        try (line(old, "Old turn narration here.") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let turnStart = Date().addingTimeInterval(-10)
        XCTAssertNil(UsageReader.claudeNarration(transcript: url.path, since: turnStart))
        let h = try FileHandle(forWritingTo: url); h.seekToEndOfFile()
        h.write((line(now, "Now I'll wire the checkout page. Then test.") + "\n").data(using: .utf8)!); try h.close()
        XCTAssertEqual(UsageReader.claudeNarration(transcript: url.path, since: turnStart)?.text, "Now I'll wire the checkout page")
    }
}

final class WaitingTests: XCTestCase {
    func testOpenQuestionFindsTheFinalQuestion() {
        let m = "I added the tax calculation and all 24 tests pass. Want me to update the docs too? Or should I also wire it into checkout?"
        XCTAssertEqual(SessionStore.openQuestion(in: m), "Or should I also wire it into checkout?")
        XCTAssertEqual(SessionStore.openQuestion(in: "Done.\n\nShould I commit this?"), "Should I commit this?")
        XCTAssertNil(SessionStore.openQuestion(in: "All done. Tests pass."))
        let buried = "Why? Because the cache was stale. " + String(repeating: "Details follow here. ", count: 20)
        XCTAssertNil(SessionStore.openQuestion(in: buried)) // a question far back isn't "asking you"
    }

    func testAskUserQuestionAndPlan() {
        XCTAssertEqual(SessionStore.question(tool: "AskUserQuestion",
                                             input: ["questions": [["question": "Which database should we use?"]]]),
                       "Which database should we use?")
        XCTAssertEqual(SessionStore.question(tool: "ExitPlanMode", input: [:]), "Plan ready for your review")
        XCTAssertNil(SessionStore.question(tool: "Bash", input: [:]))
    }

    func testPhrasesLeadWithTheQuestion() {
        var s = Session(id: "s", cwd: "/p", pid: 0, termProgram: "", bundleID: "")
        s.question = "Should I commit this?"
        XCTAssertEqual(WaitingLine.phrases(for: s).first, "“Should I commit this?”")
        XCTAssertEqual(WaitingLine.phrases(for: s)[1], "claude needs your call on this 👀")
        s.question = nil
        s.lastMessage = "Fixed the login bug and added tests."
        XCTAssertEqual(WaitingLine.phrases(for: s).first, "done cooking 🍳 fixed the login bug and added tests.")
        s.lastMessage = nil
        // Only casual lines left, all drawn from the pool.
        let pool = Set(WaitingLine.vibes("claude"))
        XCTAssertTrue(WaitingLine.phrases(for: s).allSatisfy(pool.contains))
    }
}
