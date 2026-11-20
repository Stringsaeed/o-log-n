#!/usr/bin/env bash
# Build the menu-bar app and assemble build/Logn.app (ad-hoc signed).
# Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product OLogNApp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Logn.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OLogNApp" "$APP/Contents/MacOS/OLogN"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [ -f Support/AppIcon.icns ]; then cp Support/AppIcon.icns "$APP/Contents/Resources/"; fi
# Copy SwiftPM resource bundles, if any.
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
mkdir -p "$APP/Contents/Resources/Licenses"
cp Vendor/libdeflate/COPYING "$APP/Contents/Resources/Licenses/libdeflate-COPYING"
cp Vendor/libjpeg-turbo/LICENSE.md "$APP/Contents/Resources/Licenses/libjpeg-turbo-LICENSE.md"
cp Vendor/libjpeg-turbo/README.ijg "$APP/Contents/Resources/Licenses/libjpeg-turbo-README.ijg"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "$APP"
