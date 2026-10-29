#!/bin/zsh
# Builds NotchBar.app into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)

APP=build/NotchBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NotchBar" "$APP/Contents/MacOS/NotchBar"
cp "$BIN/notchbar-hook" "$APP/Contents/MacOS/notchbar-hook"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/codex.png "$APP/Contents/Resources/"
strip -x "$APP/Contents/MacOS/NotchBar" "$APP/Contents/MacOS/notchbar-hook" 2>/dev/null || true

codesign --force --sign - "$APP/Contents/MacOS/notchbar-hook"
codesign --force --sign - "$APP"
echo "Built $APP"
