#!/bin/bash
# CI: switch to the newest Xcode installed on the runner and print what we got.
set -euo pipefail
XCODE=$(find /Applications -maxdepth 1 -name 'Xcode_*.app' | sort -V | tail -1)
[ -n "$XCODE" ] || XCODE=/Applications/Xcode.app
sudo xcode-select -s "$XCODE"
echo "xcode=$(basename "$XCODE" .app)" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "swift=$(swift --version 2>&1 | head -1)" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "Using $XCODE"
