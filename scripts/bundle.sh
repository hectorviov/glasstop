#!/usr/bin/env bash
# Builds a release binary and wraps it in build/Glasstop.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Glasstop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Glasstop" "$APP/Contents/MacOS/Glasstop"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
echo "Run:     open $APP"
echo "Install: cp -R $APP /Applications/"
