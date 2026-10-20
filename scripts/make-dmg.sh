#!/usr/bin/env bash
# Wraps build/Glasstop.app in a drag-to-install disk image: the app on the left, an
# Applications shortcut on the right, an arrow background. Run scripts/bundle.sh first.
#
# Needs dmgbuild (pip install dmgbuild); it writes the Finder layout itself, so no Finder
# scripting and it works headless (CI).
#
# Usage: scripts/make-dmg.sh [output.dmg]     (default build/Glasstop-<version>.dmg)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Glasstop.app
[[ -d "$APP" ]] || { echo "error: $APP not found; run scripts/bundle.sh first" >&2; exit 1; }
command -v dmgbuild >/dev/null || { echo "error: dmgbuild not found (pip install dmgbuild)" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="${1:-build/Glasstop-$VERSION.dmg}"
WORK=build/dmg
rm -rf "$WORK" "$DMG"
mkdir -p "$WORK"

swift scripts/make-dmg-background.swift "$WORK" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null

dmgbuild -s scripts/dmg-settings.py \
    -D app="$APP" -D background="$WORK/background.tiff" \
    "Glasstop $VERSION" "$DMG"

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
