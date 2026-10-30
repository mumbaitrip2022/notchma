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
# Saves the top middle of the screen (where the notch lives) to $SHOTS_DIR/<name>.png.
# Best effort: a missing screenshot never fails the smoke test.
shot() {
  [ -n "${SHOTS_DIR:-}" ] || return 0
  mkdir -p "$SHOTS_DIR"
  local f="$SHOTS_DIR/$1.png" w h cw ch
  screencapture -x -m "$f" 2>/dev/null || { echo "(no screenshot: screencapture failed)"; return 0; }
  w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}'); h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}')
  cw=$(( w < 1200 ? w : 1200 )); ch=$(( h < 520 ? h : 520 ))
  sips -c "$ch" "$cw" --cropOffset 0 $(( (w - cw) / 2 )) "$f" >/dev/null 2>&1 || true
  echo "Saved screenshot $1 (${cw}x${ch} of ${w}x${h})"
}

{ echo "### 🔥 Smoke test"; echo; echo "| | Check |"; echo "|---|---|"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

mkdir -p "$HOME/Applications"
rm -rf "$APP" && cp -R "$APP_SRC" "$APP"
codesign --verify --deep --strict "$APP" && pass "Code signature is valid"
[ "$(lipo -archs "$APP/Contents/MacOS/NotchBar")" = "arm64" ] && pass "App is built for Apple silicon"

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
  '{"session_id":"ci-smoke","hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"swift test"}}'; do
  echo "$e" | "$HOOK" --agent claude >/dev/null
done
sleep 2
shot 1-working

# An approval card, the way you'd see it: the hook waits for an answer while we take the picture,
# then goes away without one. NotchBar has to shrug that off.
echo '{"session_id":"ci-smoke","hook_event_name":"PermissionRequest","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"rm -rf .build && swift build"}}' \
  | "$HOOK" --agent claude >/dev/null 2>&1 &
ask=$!
sleep 3
shot 2-approval
kill "$ask" 2>/dev/null || true
wait "$ask" 2>/dev/null || true
sleep 1
pgrep -x NotchBar >/dev/null || fail "NotchBar quit when a pending approval went away"
pass "Shows an approval and survives the agent leaving mid question"

for e in \
  '{"session_id":"ci-smoke","hook_event_name":"PostToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"swift test"},"tool_response":{"stdout":"Executed 12 tests, with 0 failures"}}' \
  '{"session_id":"ci-smoke","hook_event_name":"Stop","cwd":"/tmp","last_assistant_message":"All tests pass."}'; do
  echo "$e" | "$HOOK" --agent claude >/dev/null
done
sleep 2
shot 3-done
echo '{"session_id":"ci-smoke","hook_event_name":"SessionEnd","cwd":"/tmp"}' | "$HOOK" --agent claude >/dev/null
sleep 2
pgrep -x NotchBar >/dev/null || fail "NotchBar quit while handling a session"
pass "Handles a full agent session (start, prompt, tool, stop, end)"

# 4. Quit cleanly, and no crash reports.
osascript -e 'tell application id "dev.notchbar.app" to quit' >/dev/null 2>&1 || pkill -x NotchBar || true
for _ in $(seq 1 20); do pgrep -x NotchBar >/dev/null || break; sleep 0.5; done
pgrep -x NotchBar >/dev/null && fail "NotchBar didn't quit"
crashes_after=$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -c '^NotchBar' || true)
[ "$crashes_after" -le "$crashes_before" ] || fail "macOS wrote a NotchBar crash report"
pass "Quits cleanly with no crash reports"
