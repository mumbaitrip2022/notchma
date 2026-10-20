# Sharing NotchBar

## 1. Build the shareable app

```sh
make dist
```

Produces `dist/NotchBar-<version>.zip` and `dist/NotchBar-<version>.dmg`: a universal app (Apple Silicon + Intel),
macOS 14+. Without signing credentials it's ad-hoc signed, so recipients must approve it once
(System Settings › Privacy & Security › **Open Anyway**).

## 2. Sign and notarize (recommended — opens cleanly on any Mac)

You need a **Developer ID Application** certificate (Apple Developer Program). An *Apple Distribution*
certificate is for the App Store and can't be notarized for outside distribution.

1. Xcode › Settings › Accounts › your team › **Manage Certificates…** › **+** › **Developer ID Application**.
2. Store notarization credentials once (use an app-specific password from appleid.apple.com):
   ```sh
   xcrun notarytool store-credentials notchbar --apple-id you@example.com --team-id YOURTEAMID
   ```
3. Build, sign, notarize and staple:
   ```sh
   NOTCHBAR_SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
   NOTCHBAR_NOTARY_PROFILE=notchbar \
   make dist
   ```
4. Check: `spctl -a -vv dist/NotchBar.app` should say `source=Notarized Developer ID`.

## 3. Publish

- **GitHub Releases:** tag `v<version>`, attach the `.dmg` and `.zip`, paste the SHA-256 lines `make dist` prints.
- **Homebrew (later):** a cask pointing at the release `.zip` lets people `brew install --cask notchbar`.
- Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist` for each release.

## Compatibility checklist before a release

- `make test` passes (33 tests: parsers, safety rules, real git, shell).
- Debug build with `defaults write dev.notchbar.app simulateNotch -bool true` to preview the notched-MacBook
  layout on a Mac without a notch (the debug snapshot marks the camera area in red).
- Fresh-user path: delete `~/Library/Preferences/dev.notchbar.app.plist`, open the app from `~/Downloads`
  → it offers to move to Applications → welcome → Connect.
