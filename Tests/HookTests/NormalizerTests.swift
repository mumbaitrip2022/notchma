import XCTest
@testable import notchbar_hook

final class NormalizerTests: XCTestCase {
    func testOutputTailTrimsHugeOutput() {
        let big = String(repeating: "x", count: 20_000) + "Tests: 1 passed, 1 total"
        let tail = Normalizer.outputTail(["stdout": big])!
        XCTAssertEqual(tail.count, 4000)
        XCTAssertTrue(tail.hasSuffix("1 total"))
    }

    func testClaudeKeepsFinalMessageDropsResponse() {
        let out = Normalizer.normalize(["session_id": "s", "hook_event_name": "PostToolUse",
                                        "tool_response": ["stdout": "ok"], "last_assistant_message": "  Done.  "],
                                       agent: .claude)!
        XCTAssertNil(out["tool_response"])
        XCTAssertEqual(out["_output_tail"] as? String, "ok")
        XCTAssertEqual(out["last_assistant_message"] as? String, "Done.")
    }

    func testCursorMapping() {
        let shell = Normalizer.normalize(["hook_event_name": "beforeShellExecution", "conversation_id": "c1",
                                          "command": "ls", "cwd": "/p"], agent: .cursor)!
        XCTAssertEqual(shell["hook_event_name"] as? String, "PermissionRequest")
        XCTAssertEqual(shell["session_id"] as? String, "c1")
        let resp = Normalizer.normalize(["hook_event_name": "afterAgentResponse", "conversation_id": "c1",
                                         "workspace_roots": ["/p"], "text": "All set"], agent: .cursor)!
        XCTAssertEqual(resp["hook_event_name"] as? String, "AgentResponse")
        XCTAssertEqual(resp["cwd"] as? String, "/p")
        XCTAssertNil(Normalizer.normalize(["hook_event_name": "beforeTabFileRead", "conversation_id": "c1"], agent: .cursor))
    }

    func testCodexArgvCommand() {
        let out = Normalizer.normalize(["session_id": "s", "hook_event_name": "PreToolUse", "tool_name": "Bash",
                                        "tool_input": ["command": ["bash", "-lc", "ls"]]], agent: .codex)!
        XCTAssertEqual((out["tool_input"] as? [String: Any])?["command"] as? String, "bash -lc ls")
    }
}
