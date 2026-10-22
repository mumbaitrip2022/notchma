#!/bin/zsh
# Builds a shareable NotchBar for Apple silicon Macs.
#
#   make dist                       → ad-hoc signed .zip + .dmg in ./dist
#   NOTCHBAR_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTCHBAR_NOTARY_PROFILE=notchbar make dist
#                                   → signed + notarized + stapled (opens cleanly on any Mac)
#
# One-time notary setup:
#   xcrun notarytool store-credentials notchbar --apple-id you@example.com --team-id TEAMID
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
SIGN_ID=${NOTCHBAR_SIGN_IDENTITY:-}
NOTARY=${NOTCHBAR_NOTARY_PROFILE:-}

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

echo "▸ Building release for Apple silicon…"
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf dist && mkdir -p dist
APP=dist/NotchBar.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NotchBar" "$BIN/notchbar-hook" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for b in NotchBar notchbar-hook; do
  [ "$(lipo -archs "$APP/Contents/MacOS/$b")" = "arm64" ] || { echo "✗ $b must be Apple silicon (arm64) only"; exit 1; }
done

echo "▸ Signing…"
if [ -n "$SIGN_ID" ]; then
  for target in "$APP/Contents/MacOS/notchbar-hook" "$APP"; do
    codesign --force --options runtime --timestamp \
      --entitlements Resources/NotchBar.entitlements --sign "$SIGN_ID" "$target"
  done
else
  echo "  (no NOTCHBAR_SIGN_IDENTITY — ad-hoc signing; recipients will need to approve it once)"
  codesign --force --sign - "$APP/Contents/MacOS/notchbar-hook"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

notarize() {  # $1 = file to submit
  [ -n "$SIGN_ID" ] && [ -n "$NOTARY" ] || return 0
  echo "▸ Notarizing $(basename "$1")…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY" --wait
}

ZIP="dist/NotchBar-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if notarize "$ZIP" && [ -n "$NOTARY" ]; then
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"   # zip again with the ticket stapled
fi

echo "▸ Making disk image…"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/NotchBar-$VERSION.dmg"
hdiutil create -quiet -volname "NotchBar" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
if [ -n "$SIGN_ID" ]; then
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
  notarize "$DMG" && [ -n "$NOTARY" ] && xcrun stapler staple "$DMG"
fi

# Same disk image under a fixed name, so this link always serves the newest release:
#   https://github.com/mumbaitrip2022/notchma/releases/latest/download/NotchBar.dmg
cp "$DMG" dist/NotchBar.dmg

echo
echo "✓ NotchBar $VERSION"
for f in "$ZIP" "$DMG"; do
  printf "  %-34s %6s  sha256 %s\n" "$f" "$(du -h "$f" | cut -f1)" "$(shasum -a 256 "$f" | cut -c1-16)…"
done
