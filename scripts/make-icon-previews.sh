#!/usr/bin/env bash
# Refresh the files derived from Support/AppIcon.icon:
#   Support/AppIcon.icns      fallback for builds without Xcode's actool
#   assets/logn-icon.png      the image at the top of the README
#   docs/media/icon-1024.png  the icon on its own, with its margin
# Needs Xcode, for ictool inside Icon Composer.
# Usage: scripts/make-icon-previews.sh [sheet-dir]
#   With a directory, also writes one PNG per rendition there, to look over.
set -euo pipefail
cd "$(dirname "$0")/.."
DOC=Support/AppIcon.icon
[ -d "$DOC" ] || { echo "run scripts/make-icon.py first" >&2; exit 1; }
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[ -x "$ICTOOL" ] || { echo "Icon Composer not found in Xcode" >&2; exit 1; }
TMP="$(mktemp -d -t logn-icon)"
render() { # rendition, pixels, output
  "$ICTOOL" "$DOC" --export-image --output-file "$3" --platform macOS \
    --rendition "$1" --width "$2" --height "$2" --scale 1 >/dev/null
}

# The fallback .icns, at every size. ictool draws the icon edge to edge, so
# each size is drawn at 824/1024 of its canvas and padded out, which is the
# margin macOS icons carry.
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
while read -r name px; do
  inner=$(( (px * 824 + 512) / 1024 ))
  render Default "$inner" "$SET/$name"
  sips --padToHeightWidth "$px" "$px" "$SET/$name" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES
iconutil -c icns -o Support/AppIcon.icns "$SET"
cp "$SET/icon_512x512@2x.png" docs/media/icon-1024.png

render Default 512 assets/logn-icon.png
if [ $# -gt 0 ]; then
  mkdir -p "$1"
  for r in Default Dark TintedLight TintedDark ClearLight ClearDark; do
    render "$r" 512 "$1/icon-$r.png"
  done
fi
rm -rf "$TMP"
echo "wrote Support/AppIcon.icns, assets/logn-icon.png and docs/media/icon-1024.png"
