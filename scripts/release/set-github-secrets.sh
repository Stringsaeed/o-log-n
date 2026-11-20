#!/usr/bin/env bash
# Uploads the release secrets to GitHub Actions (Stringsaeed/o-log-n) with `gh secret set`.
# Nothing is written to disk or echoed. Run once, and again whenever a credential rotates.
#
#   scripts/release/set-github-secrets.sh \
#     --p12 ~/Desktop/DeveloperID.p12 \
#     --p8 ~/Downloads/AuthKey_ABC123XYZ.p8 --key-id ABC123XYZ --issuer 00000000-0000-0000-0000-000000000000
#
# Prompts for the .p12 password and the Homebrew tap token. Requires `gh` already logged in.
set -euo pipefail
REPO=${REPO:-Stringsaeed/o-log-n}
P12= P8= KEY_ID= ISSUER=
usage() {
  cat >&2 <<'EOF'
Usage: scripts/release/set-github-secrets.sh \
  --p12 <DeveloperID.p12> \
  --p8 <AuthKey_KEYID.p8> --key-id <KEYID> --issuer <ISSUER-UUID>

Prompts for the .p12 password and the Homebrew tap token.
REPO defaults to Stringsaeed/o-log-n. Nothing is written to disk or echoed.
EOF
}
while [[ $# -gt 0 ]]; do
  case $1 in
    --p12) P12=$2; shift 2 ;;
    --p8) P8=$2; shift 2 ;;
    --key-id) KEY_ID=$2; shift 2 ;;
    --issuer) ISSUER=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done
[[ -f $P12 && -f $P8 && -n $KEY_ID && -n $ISSUER ]] || { usage; exit 1; }
command -v gh >/dev/null || { echo "error: gh is not installed" >&2; exit 1; }

set_secret() { printf '%s' "$2" | gh secret set "$1" --repo "$REPO" >/dev/null && echo "  ✓ $1"; }

read -rsp "Password for $(basename "$P12"): " P12_PASS; echo
# LibreSSL (macOS /usr/bin/openssl) rejects -legacy; OpenSSL 3 needs it for older .p12 files.
parse_identity() {
  openssl pkcs12 -in "$P12" -passin "pass:$P12_PASS" -nokeys "$@" 2>/dev/null \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F' = ' '/commonName/{print $2; exit}'
}
IDENTITY=$(parse_identity -legacy || true)
[[ -n $IDENTITY ]] || IDENTITY=$(parse_identity || true)
[[ $IDENTITY == "Developer ID Application:"* ]] || { echo "error: $P12 isn't a Developer ID Application certificate (got: ${IDENTITY:-nothing})" >&2; exit 1; }

echo "Setting secrets on $REPO:"
set_secret APPLE_CERTIFICATE "$(base64 < "$P12")"
set_secret APPLE_CERTIFICATE_PASSWORD "$P12_PASS"
set_secret APPLE_SIGNING_IDENTITY "$IDENTITY"
set_secret APPLE_API_KEY "$KEY_ID"
set_secret APPLE_API_ISSUER "$ISSUER"
# Upload the .p8 bytes unchanged (command substitution would strip a trailing newline).
gh secret set APPLE_API_KEY_P8 --repo "$REPO" < "$P8" >/dev/null && echo "  ✓ APPLE_API_KEY_P8"

read -rsp "Homebrew tap token (fine-grained PAT, Contents: write on Stringsaeed/homebrew-tap; Enter to skip): " TAP; echo
[[ -n $TAP ]] && set_secret HOMEBREW_TAP_TOKEN "$TAP"
unset P12_PASS TAP
echo "Done."
