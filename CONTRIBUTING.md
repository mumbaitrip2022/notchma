# Contributing to NotchBar

Thanks for wanting to help! NotchBar is a small native Mac app, so getting started is quick.

## Before you start

- **Bugs:** open an issue first, ideally from the app (gear menu › *Report a Problem…*), so the details are filled in.
- **Features:** open a feature idea first and say what you'd like to build. A quick "yes, go for it" saves you from building something that won't be merged.
- **Small fixes** (typos, docs, obvious bugs) can go straight to a pull request.
- Look for issues labeled `good first issue` if you'd like an easy way in.

## Set up

Needs a Mac with Apple silicon, macOS 14 or newer, and Xcode 16 or newer (Swift 6). No other dependencies.

```sh
git clone https://github.com/mumbaitrip2022/notchma.git && cd notchma
make run        # build and launch from ./build
swift test      # unit and integration tests
```

`make install` copies the app to `~/Applications` and connects the hooks for every agent you have. Use it when you want to test with real Claude Code, Codex or Cursor sessions.

### Testing the UI without real agents

Debug builds (`swift build`, then `./.build/debug/NotchBar`) accept test commands on the app's socket, `~/Library/Application Support/NotchBar/nb.sock` (one JSON object per line):

| Command | What it does |
|---|---|
| `{"hook_event_name":"_Hover","session_id":"x","on":true}` | Open or close the notch |
| `{"hook_event_name":"_Page","session_id":"x","page":"receipt"}` | Show a page: `home`, `launcher`, `receipt`, `tour`, `report` |
| `{"hook_event_name":"_PetDemo","session_id":"x"}` | Fill the receipt with sample numbers (memory only) |
| `{"hook_event_name":"_Update","session_id":"x","do":"fake"}` | Pretend an update is available |
| `{"hook_event_name":"_Snapshot","session_id":"x","path":"/tmp/n.png"}` | Save a picture of the notch |
| `{"hook_event_name":"_Dump","session_id":"x","path":"/tmp/n.txt"}` | Write the window and state |

Add `-simulateNotch YES` when launching to fake a MacBook notch on any screen.

These commands don't exist in release builds.

## How the code is organized

- `Sources/notchbar-hook`: the tiny helper each agent runs on every hook event. It must stay fast and **fail safe**: if anything goes wrong, it prints nothing and the agent shows its own prompt.
- `Sources/NotchBar`: the app.
  - `SessionStore.swift`: all session and approval state.
  - `NotchController.swift`: the window, expanding, menus.
  - `Views/`: SwiftUI views.
  - `Pet/`: the pet, the daily receipt and its stats.
  - `Services/`: updater, diagnostics, terminals, system vitals and more.

## House rules

- **Fail safe first.** No change may leave an agent stuck waiting on NotchBar.
- **Private by default.** No analytics and no new network requests. NotchBar only talks to GitHub for the daily update check and for CI status after an agent pushes.
- **Light.** Nothing polls while idle. Animations stop when they aren't visible.
- **Look and feel.** Solid colors only, no gradients. Grayscale by default; amber means "needs you", blue means "your reply", green means "done", red means "danger".
- **Words.** Short, friendly, lowercase for casual lines. No em or en dashes in app text (CI checks this with `./scripts/check-copy.sh`).

## Pull requests

1. Fork, branch from `main`, keep the change focused.
2. Make sure `swift test` and `./scripts/check-copy.sh` pass.
3. Fill in the pull request template, with screenshots for anything visible.
4. CI builds and tests every pull request. The maintainer reviews and squash merges.

## Releases (maintainer)

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. `make dist` builds the Apple silicon app, zip and DMG in `./dist`.
3. Tag `vX.Y.Z`, push, and create a GitHub release with the DMG and zip attached.
4. The release notes' first `## heading` and first six `- ` bullets become the in-app update banner and "what's new" list, so write them for users.

See [DISTRIBUTING.md](DISTRIBUTING.md) for signing and notarization.

## Code of conduct

Be kind. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
