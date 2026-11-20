#!/usr/bin/env bash
# Build, Developer-ID-sign, notarize and staple Logn, then package a notarized DMG.
#
#   scripts/release.sh [version]          # version defaults to CFBundleShortVersionString
#
# Environment:
#   SIGN_IDENTITY   SHA-1 hash of a "Developer ID Application" identity, or its full name
#                   when exactly one keychain identity has that name (the CI temporary keychain).
#                   Default: the first valid Developer ID hash. A name that matches several
#                   certificates is refused; pass the hash (see docs/release.md).
#   NOTARY_PROFILE  notarytool keychain profile (default: logn-notary). See docs/release.md for setup.
#   NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER
#                   App Store Connect API key (.p8 path, key id, issuer id). Overrides NOTARY_PROFILE (for CI).
#   SKIP_NOTARIZE=1 Sign and package only (a local dry run; Gatekeeper will reject the result).
#   SKIP_BUILD=1    Reuse the existing build/Logn.app instead of running scripts/bundle.sh release.
#
# Output: dist/Logn-<version>.dmg (+ .sha256), and dist/Logn.app (stapled).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Logn"
PLIST="Support/Info.plist"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
# CI stamps the Actions run number. Locally this stays the commit count.
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-logn-notary}"
DIST="dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------------------------
for tool in xcrun codesign ditto hdiutil spctl shasum; do command -v "$tool" >/dev/null || die "missing $tool"; done

identity_lines="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(printf '%s\n' "$identity_lines" | awk '/"Developer ID Application:/ {print $2; exit}')"
  [ -n "$SIGN_IDENTITY" ] || die "no valid 'Developer ID Application' identity in the keychain"
elif printf '%s' "$SIGN_IDENTITY" | grep -Eq '^[0-9A-Fa-f]{40}$'; then
  printf '%s\n' "$identity_lines" | grep -F -q "$SIGN_IDENTITY" || die "identity $SIGN_IDENTITY not found or not valid"
else
  # Match the quoted name exactly. One hit (the CI keychain) is signed by its hash,
  # which codesign accepts without the "ambiguous identity" error a shared name causes.
  matches="$(printf '%s\n' "$identity_lines" | grep -F "\"${SIGN_IDENTITY}\"" || true)"
  if [ -z "$matches" ]; then
    die "identity $SIGN_IDENTITY not found or not valid"
  fi
  count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  if [ "$count" -ne 1 ]; then
    die "signing identity matches $count certificates; set SIGN_IDENTITY to one certificate's SHA-1 (security find-identity -v -p codesigning)"
  fi
  SIGN_IDENTITY="$(printf '%s\n' "$matches" | awk '{print $2}')"
  [ -n "$SIGN_IDENTITY" ] || die "could not read the certificate hash for the signing identity"
fi

notary_args=()
if [ -n "${NOTARY_KEY:-}" ]; then
  [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ] || die "NOTARY_KEY needs NOTARY_KEY_ID and NOTARY_ISSUER"
  [ -f "$NOTARY_KEY" ] || die "NOTARY_KEY is not a file ($NOTARY_KEY)"
  notary_args=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  notary_how="App Store Connect API key ${NOTARY_KEY_ID}"
else
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
  notary_how="keychain profile '${NOTARY_PROFILE}'"
fi
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  if ! xcrun notarytool history "${notary_args[@]}" >"$WORK/notary-history.txt" 2>&1; then
    cat "$WORK/notary-history.txt" >&2
    die "notary credentials not usable (${notary_how}). One-time setup: see docs/release.md"
  fi
fi

# --- notarize helper: submit, wait, print the log on failure ------------------------------------
notarize() {
  local file="$1" out="$WORK/notary-$(basename "$file").json"
  log "notarizing $(basename "$file") (this usually takes 1–5 min)"
  xcrun notarytool submit "$file" "${notary_args[@]}" --wait --timeout 30m --output-format json > "$out" || true
  local status id
  status="$(/usr/bin/plutil -extract status raw -o - "$out" 2>/dev/null || echo unknown)"
  id="$(/usr/bin/plutil -extract id raw -o - "$out" 2>/dev/null || echo '')"
  if [ "$status" != "Accepted" ]; then
    cat "$out" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "${notary_args[@]}" >&2 || true
    die "notarization of $(basename "$file") finished with status: $status"
  fi
  log "accepted ($id)"
}

# --- build + sign the app ----------------------------------------------------------------------
log "building $APP_NAME $VERSION ($BUILD_NUMBER)"
if [ "${SKIP_BUILD:-0}" = "1" ]; then APP_BUILT="build/$APP_NAME.app"; else APP_BUILT="$(scripts/bundle.sh release | tail -1)"; fi
[ -d "$APP_BUILT" ] || die "bundle.sh did not produce an app"
rm -rf "$DIST/$APP_NAME.app" && mkdir -p "$DIST"
ditto "$APP_BUILT" "$DIST/$APP_NAME.app"
APP="$DIST/$APP_NAME.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

log "signing with Developer ID (hardened runtime, secure timestamp)"
ENTITLEMENTS=()
[ -f Support/Logn.entitlements ] && ENTITLEMENTS=(--entitlements Support/Logn.entitlements)
# Sign nested code first (none today; future frameworks/helpers), then the app itself.
find "$APP/Contents" \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -prune -print0 2>/dev/null \
  | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" {}
codesign --force --options runtime --timestamp ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

# --- notarize + staple the app (so it passes Gatekeeper offline once copied out of the DMG) ------
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  ditto -c -k --keepParent "$APP" "$WORK/$APP_NAME.zip"
  notarize "$WORK/$APP_NAME.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# --- DMG: app + /Applications alias, signed, notarized, stapled ---------------------------------
DMG="$DIST/$APP_NAME-$VERSION.dmg"
log "packaging $(basename "$DMG")"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs APFS -format ULFO -ov "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  log "Gatekeeper assessment"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
  log "SKIP_NOTARIZE=1: signed but NOT notarized — Gatekeeper will reject this build on other Macs"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
log "done: $DMG"
