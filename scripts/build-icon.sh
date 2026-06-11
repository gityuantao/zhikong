#!/usr/bin/env bash
# Regenerate the app icon (Sources/App/AppIcon.icns) and the README logo
# (assets/logo.png) from scripts/make-appicon.swift. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

RENDER="scripts/make-appicon.swift"
WORK="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$WORK"

gen() { swift "$RENDER" "$1" "$WORK/$2"; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

iconutil -c icns "$WORK" -o Sources/App/AppIcon.icns
mkdir -p assets
swift "$RENDER" 512 assets/logo.png

echo "✓ Sources/App/AppIcon.icns + assets/logo.png regenerated"
