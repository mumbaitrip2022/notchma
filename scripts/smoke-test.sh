#!/bin/bash
# End-to-end check of a packaged NotchBar.app on a clean Mac:
# the hook stays fail safe without the app, the app launches, takes events, and quits cleanly.
set -euo pipefail
APP_SRC=${1:?usage: smoke-test.sh path/to/NotchBar.app}
APP="$HOME/Applications/NotchBar.app"
HOOK="$APP/Contents/MacOS/notchbar-hook"
SOCK="$HOME/Library/Application Support/NotchBar/nb.sock"
pass() { echo "✓ $1"; echo "| ✅ | $1 |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
fail() {
  echo "✗ $1"; echo "| ❌ | $1 |" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  # macOS writes crash reports a few seconds after the fact.
  for _ in $(seq 1 20); do ls "$HOME"/Library/Logs/DiagnosticReports/NotchBar* >/dev/null 2>&1 && break; sleep 1; done
  echo "::group::NotchBar log (last 3 minutes)"
  log show --last 3m --style compact --predicate 'process == "NotchBar" AND messageType >= 16' 2>/dev/null | tail -60 || true
  log show --last 3m --style compact --predicate 'eventMessage CONTAINS "NotchBar" AND (process == "launchd" OR process == "ReportCrash" OR process == "kernel")' 2>/dev/null | tail -30 || true
  echo "::endgroup::"
  for f in "$HOME"/Library/Logs/DiagnosticReports/NotchBar*; do
    [ -e "$f" ] || continue
    echo "::group::Crash report $(basename "$f")"; head -c 12000 "$f"; echo; echo "::endgroup::"
  done
  exit 1
}
now() { python3 -c 'import time; print(time.time())'; }

{ echo "### 🔥 Smoke test"; echo; echo "| | Check |"; echo "|---|---|"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

mkdir -p "$HOME/Applications"
rm -rf "$APP" && cp -R "$APP_SRC" "$APP"
codesign --verify --deep --strict "$APP" && pass "Code signature is valid"
lipo "$APP/Contents/MacOS/NotchBar" -verify_arch arm64 x86_64 && pass "App is universal (Apple silicon and Intel)"

# 1. Fail safe: with NotchBar closed, a permission request must return nothing, fast.
REQ='{"session_id":"ci-smoke","hook_event_name":"PermissionRequest","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}'
t0=$(now); out=$(echo "$REQ" | "$HOOK" --agent claude); t1=$(now)
[ -z "$out" ] || fail "Hook printed output while NotchBar was closed: $out"
python3 -c "import sys; sys.exit(0 if $t1 - $t0 < 2 else 1)" || fail "Hook took too long with NotchBar closed"
pass "Hook is fail safe when NotchBar is closed ($(python3 -c "print(f'{($t1 - $t0) * 1000:.0f}')") ms)"

# Cursor's fail safe answer is an explicit "ask".
out=$(echo '{"session_id":"ci","hook_event_name":"beforeShellExecution","command":"ls","cwd":"/tmp"}' | "$HOOK" --agent cursor || true)
[ -z "$out" ] || echo "$out" | grep -q '"ask"\|"continue"' || fail "Cursor fail safe answer was unexpected: $out"
pass "Cursor hook falls back safely"

# 2. Launch and wait for the socket.
crashes_before=$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -c '^NotchBar' || true)
open "$APP"
for _ in $(seq 1 40); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || fail "NotchBar didn't open its socket within 20s"
pgrep -x NotchBar >/dev/null || fail "NotchBar isn't running"
pass "NotchBar launches and listens"

# 3. Feed it a realistic session.
for e in \
  '{"session_id":"ci-smoke","hook_event_name":"SessionStart","cwd":"/tmp"}' \
  '{"session_id":"ci-smoke","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"run the tests"}' \
  '{"session_id":"ci-smoke","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"swift test"}}' \
  '{"session_id":"ci-smoke","hook_event_name":"PostToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"swift test"},"tool_response":{"stdout":"Executed 12 tests, with 0 failures"}}' \
  '{"session_id":"ci-smoke","hook_event_name":"Stop","cwd":"/tmp","last_assistant_message":"All tests pass."}' \
  '{"session_id":"ci-smoke","hook_event_name":"SessionEnd","cwd":"/tmp"}'; do
  echo "$e" | "$HOOK" --agent claude >/dev/null
done
sleep 3
pgrep -x NotchBar >/dev/null || fail "NotchBar quit while handling a session"
pass "Handles a full agent session (start, prompt, tool, stop, end)"

# 4. Quit cleanly, and no crash reports.
osascript -e 'tell application id "dev.notchbar.app" to quit' >/dev/null 2>&1 || pkill -x NotchBar || true
for _ in $(seq 1 20); do pgrep -x NotchBar >/dev/null || break; sleep 0.5; done
pgrep -x NotchBar >/dev/null && fail "NotchBar didn't quit"
crashes_after=$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -c '^NotchBar' || true)
[ "$crashes_after" -le "$crashes_before" ] || fail "macOS wrote a NotchBar crash report"
pass "Quits cleanly with no crash reports"
