#!/usr/bin/env bash
# Builds a release binary and wraps it in build/Glasstop.app. Ad-hoc signed by default;
# SIGN_IDENTITY="Developer ID Application: …" signs for distribution (hardened runtime +
# secure timestamp, both required for notarization).
#
# Usage: scripts/bundle.sh [--install]
#   --install   also copy the app to /Applications (quits a running Glasstop first)
#   OUT_DIR=dir scripts/bundle.sh   build somewhere other than build/
#   VERSION=1.2.0 BUILD_NUMBER=42 scripts/bundle.sh   stamp the bundle (releases use the git tag)
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1
OUT_DIR="${OUT_DIR:-build}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$OUT_DIR/Glasstop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Glasstop" "$APP/Contents/MacOS/Glasstop"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ "${SIGN_IDENTITY:--}" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
fi

echo "Built $APP ($(du -sh "$APP" | cut -f1)), version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

if (( INSTALL )); then
    pkill -x Glasstop && sleep 1 || true
    rm -rf /Applications/Glasstop.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Glasstop.app"
    echo "Run:     open /Applications/Glasstop.app"
else
    echo "Run:     open $APP"
    echo "Install: scripts/bundle.sh --install"
fi
