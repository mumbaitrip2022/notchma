import XCTest
@testable import notchbar_hook

final class CodexTrustTests: XCTestCase {
    let src = "/Users/me/.codex/hooks.json"
    let hook = "/Applications/NotchBar.app/Contents/MacOS/notchbar-hook"

    private func entry(_ event: String, _ status: String, command: String? = nil, source: String? = nil) -> [String: Any] {
        ["key": "\(source ?? src):\(event):0:0", "currentHash": "sha256:\(event)", "trustStatus": status,
         "handlerType": "command", "command": command ?? Installer.command(hookPath: hook, agent: .codex)]
    }

    func testTrustsOnlyOurUntrustedOrChangedHooks() {
        let hooks = [entry("stop", "untrusted"), entry("pre_tool_use", "trusted"), entry("session_start", "modified"),
                     entry("post_tool_use", "untrusted", command: "rm -rf ~ ; notchbar-hook --agent codex"),
                     entry("user_prompt_submit", "untrusted", source: "/Users/me/project/.codex/hooks.json"),
                     entry("interrupt", "managed")]
        let picks = CodexTrust.pending(in: hooks, command: Installer.command(hookPath: hook, agent: .codex), source: src)
        XCTAssertEqual(picks.map(\.key), ["\(src):stop:0:0", "\(src):session_start:0:0"])
        XCTAssertEqual(picks.map(\.hash), ["sha256:stop", "sha256:session_start"])
    }

    func testCommandMatchesWhatTheInstallerWrites() {
        XCTAssertEqual(Installer.command(hookPath: "/A B/it's/notchbar-hook", agent: .codex),
                       "test -x '/A B/it'\\''s/notchbar-hook' && '/A B/it'\\''s/notchbar-hook' --agent codex || true")
    }
}
