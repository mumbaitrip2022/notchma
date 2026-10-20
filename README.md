# NotchBar

A Dynamic-Island-style bar for **Claude Code, Codex and Cursor** on macOS. It sits at the top-center of your screen as a black island, shows what every agent session is doing, and lets you **approve or deny permission requests** without switching apps.

Native Swift (SwiftUI + AppKit). ~14 MB memory and 0% CPU when idle.

## Install

**Requirements:** macOS 14 Sonoma or newer (Sonoma, Sequoia, Tahoe…), Apple Silicon or Intel.
Works on every Mac: on MacBooks with a notch it wraps around the camera like the iPhone's Dynamic Island;
on other screens it draws its own island at the top of the display.

### From a download
1. Open `NotchBar-x.y.z.dmg` and drag **NotchBar** into **Applications** (or unzip `NotchBar-x.y.z.zip`).
2. Open NotchBar from Applications. If it was opened from somewhere else, it offers to move itself there —
   say yes (agents connect to it by path).
3. The island opens with **Connect** — click it. NotchBar adds its hooks to whichever of Claude Code, Codex
   and Cursor are installed. Your other settings are untouched, and a backup is kept next to each file.
4. **Codex only:** run `/hooks` in Codex once and trust the NotchBar entries.
5. Optional, in Settings: Launch at login, Accessibility (paste drafts / raise Warp windows), Calendar, Voice.

> If the build isn't notarized, macOS says it "can't be opened". Open **System Settings › Privacy & Security**,
> scroll down and click **Open Anyway** (macOS 15+ no longer offers this from the right-click menu).
> Or in Terminal: `xattr -dr com.apple.quarantine /Applications/NotchBar.app`

### From source
```sh
git clone https://github.com/mumbaitrip2022/notchma.git && cd notchma
make install     # builds, copies to ~/Applications, connects hooks, launches
```
Needs Xcode 16+ (Swift 6). Apps you build yourself never trigger Gatekeeper warnings.

## Agents

| Agent | Live status | Approvals in the notch | Config written |
|---|---|---|---|
| Claude Code | ✓ | ✓ (only when Claude would ask) | `~/.claude/settings.json` |
| Codex | ✓ | ✓ (only when Codex would ask) | `~/.codex/hooks.json` |
| Cursor | ✓ | opt-in: gear menu → *Approve Cursor Commands in Notch* | `~/.cursor/hooks.json` |

- **Codex** asks you to review new hooks once before running them: run `/hooks` in Codex and trust the NotchBar entries.
- **Cursor** calls hooks for *every* shell/MCP command (not just ones it would ask about), so notch approvals are off by default; turning them on means each command waits for you in the notch.

## Usage & cost

- **Plan limits:** rings under the header show Claude's 5-hour / weekly limits and Codex's windows, with reset times. The island warns once at 80% and again at 95%.
- **Task receipt:** when a task finishes, the banner and the session row show `time · tokens · ≈$cost · +lines −lines`.
  The `≈$` figure is the **API-equivalent** value of the work; on a Pro/Max plan it is not billed.
- **Context meter:** a thin bar on each session shows how full its context window is (amber at 70%, red at 90%).
- Claude data comes from a statusline NotchBar installs (it also prints `Opus 5.5 · ctx 42% · 5h 35% · week 6%` in your terminal). If you already have a statusline, NotchBar leaves it alone and skips Claude limits/cost.
- Codex data is read from its own session logs. Cursor doesn't expose usage, so it shows status only.

## Smart approvals & health

- **Always allow:** after you approve the same simple command twice in a project (e.g. `npm test`), the third request offers **Always allow** (`⌃⌥A`).
  - Claude Code: saved as a native rule in that project's `.claude/settings.local.json` — works even without NotchBar.
  - Codex / Cursor: NotchBar answers matching requests instantly (~45 ms).
  - Never offered for chained/piped commands (`&&`, `|`, `;`…), interpreters (`python`, `node`, `sh`…), or anything flagged destructive.
  - Review or remove rules in the gear menu → **Always Allowed**.
- **Stuck detection:** a working agent with no events and no log growth for 6 min (15 min while a command runs) gets an amber "may be stuck".
- **Loop detection:** the same call 4× in 10 minutes, or the same command failing 3× in a row, gets flagged. Flagged sessions float to the top.

## Flow features

**Keep agents busy**
- **Attention queue** — the header shows "3 waiting on you · oldest 12m". `⌃⌥J` (anywhere) jumps to the next one: approvals open the notch, everything else jumps to its terminal.
- **Trust window** — on any approval card, *Trust <project> for 20m* (`⌃⌥T`) auto-allows non-destructive commands, in-project edits, reads and web lookups in that project until it ends. MCP/unknown tools and destructive commands still ask. End it from the green bar.
- **Read-only defaults** (Settings, off by default) — `git status/diff/log`, `ls`, `cat`, `grep`… with no pipes/redirects are auto-allowed everywhere.
- **Allow all** — when one agent queues several safe requests, clear them in one click.

**Switch less**
- **Final answer in the notch** — unfold a session (chevron) to read the agent's last message, test result and files edited.
- **Smarter done** — "Done · tests ✓ 24 passed · 3 files" parsed from jest, vitest, pytest, XCTest, swift-testing, cargo, go, rspec, mocha, phpunit and dotnet output.
- **Open diff / Copy summary** — uncommitted changes (incl. new files) open as a `.diff` in Cursor/VS Code; the summary is a ready commit message.
- **Exact jump** — tmux pane, iTerm2/Terminal tab, or the right Cursor/VS Code window. Warp/Ghostty have no tab API: NotchBar raises the window whose title matches the project (needs Accessibility).
- **Draft the next prompt** — type it while the agent works; when it finishes you get a banner, and one tap copies it, jumps to the tab and (with Accessibility) pastes it. NotchBar never presses Return for you.

**Run in parallel**
- **New task (+)** — pick a project, agent and prompt; optionally its own **git worktree** on a new branch; start now or **at the next limit reset**. Opens in Warp (launch configuration), iTerm2 or Terminal.
- **Conflict alert** — "Two agents are editing cart.ts" the moment two live sessions touch the same file.

**Use your plan well**
- **Limit forecast** — "full ~4:10 PM at this pace", plus a hint when another agent has room.
- **Use-it-or-lose-it** — a nudge when lots of a window is unused and it resets within 45 min.
- **Context nudge** — at 85% context, a tap copies `/compact` and jumps to the session.

**Fit your day** (opt-in, Settings)
- **Meeting awareness** — warns about waiting agents 10 min before a calendar event; during it only approvals and urgent alerts show, then one digest afterwards.
- **Voice** — `⌃⌥V` to dictate your next prompt (on-device recognition when supported); it becomes the draft for the session you're looking at.

All shortcuts are ⌃⌥ and only registered while useful: `Y` allow · `N` deny · `A` always · `T` trust · `J` next · `V` voice.

## Use

| | |
|---|---|
| **Hover** the notch | Expand to see all sessions |
| **Click** the notch | Pin it open |
| **Click a session** | Jump to its terminal (Warp, Cursor, iTerm, Terminal, Ghostty) |
| Permission request | Bar opens with a chime and shows the command or diff |
| `⌃⌥Y` / `⌃⌥N` | Allow / Deny from **any app** — active only while a request is waiting |
| `⌘↩` / `⌘⌫` / `esc` | Allow / Deny / hand back (while hovering the card) |
| Two agents busy | A second bubble splits off the island, like the iPhone |
| Turn finished | The island briefly expands with a "done" banner |
| `•••` menu | Display (follow active screen / main / built-in), sounds, launch at login, disconnect, quit |

Collapsed states: agent glyph + spinner = working · amber dot = needs approval · red dot = destructive command · green check = finished · blue dot = waiting for you.

## How it works

```
claude ──hook JSON──▶ notchbar-hook ──unix socket──▶ NotchBar.app
                         ▲                              │
                         └────── allow / deny ──────────┘
```

- `make install` adds hook entries for `PermissionRequest`, `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `Notification`, `SessionStart` and `SessionEnd` to `~/.claude/settings.json`. Your other settings are untouched, and the original is saved as `settings.json.notchbar-backup`.
- **Fail-safe:** if NotchBar isn't running, crashes, or you don't answer within ~10 minutes, the hook exits silently and Claude shows its normal terminal prompt. Nothing can get stuck.
- `AskUserQuestion` and plan approvals always stay in the terminal.
- The socket lives at `~/Library/Application Support/NotchBar/nb.sock` and is readable only by you (mode 0600).

## Uninstall

Settings › **Uninstall NotchBar…** (or hold ⌥ in the gear menu). It removes only NotchBar's entries from the
agents' settings and moves the app to the Trash. From source: `make uninstall`.

If the app is ever deleted without uninstalling, nothing breaks: each hook checks the app exists first, and the
agents simply fall back to their own prompts.

## Develop

```sh
make run         # build and launch from ./build
swift test       # 25 unit + integration tests (parsers, safety rules, git, shell)
swift build      # debug build (includes test-only socket commands)
```
