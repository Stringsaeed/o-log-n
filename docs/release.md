# Releasing Logn

Logn ships as a Developer ID-signed, notarized DMG. GitHub Releases on [Stringsaeed/o-log-n](https://github.com/Stringsaeed/o-log-n) is the download. The Homebrew cask `stringsaeed/tap/logn` points at that DMG. Logn has no updater, so the cask does not set `auto_updates`.

The build is arm64 only and requires macOS 26 or later.

## Cut a release

1. Merge work into `main` with [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `perf:`. `docs:`, `chore:`, `refactor:`, `test:`, `ci:`, `build:`, and `style:` stay out of the changelog.
2. On every push to `main`, release-please opens or updates a pull request titled `chore: release x.y.z`. The PR bumps [`version.txt`](../version.txt) and `CHANGELOG.md`. The manifest starts at `0.0.0` with `bump-minor-pre-major`, so the first `feat:` proposes **0.1.0**. A `fix:` before 1.0.0 proposes a patch (`0.0.1`).
3. Merge that pull request. release-please tags `vX.Y.Z` and opens a **draft** GitHub release whose body is the changelog section.
4. The Release workflow then runs on the `xcode-27` runner. It checks `version.txt` against the tag, imports the Developer ID certificate into a temporary keychain, runs `scripts/release.sh`, uploads `Logn-<version>.dmg` and `Logn-<version>.dmg.sha256`, and publishes the release (`--draft=false --latest`).
5. The `homebrew` job checks out `Stringsaeed/homebrew-tap` and commits `logn X.Y.Z` with `Casks/logn.rb`. If the cask is already at that version and sha256, it does nothing.

Re-run a build for an existing tag from Actions → Release → Run workflow, and pass the tag (`v0.1.0`). That publishes the tag as the latest release and updates the cask to it.

Pull requests and pushes to `main` also run CI on `xcode-27`: `swift build -c release -Xswiftc -warnings-as-errors`, `swift test`, `scripts/bundle.sh`, then the headless checks `--selftest-replace` and `--selftest-history`. `--selftest` and `--selftest-keys` need an interactive GUI session (a display, `NSApp.activate`, the tray) and are not run on the runner.

## One-time setup

Do this once, before the first release. None of it is committed.

1. **Make the app repo public.** `Stringsaeed/o-log-n` has to be public so Homebrew and browsers can download release assets without a token. `Stringsaeed/homebrew-tap` is already public. Its default branch must accept a push from the token below (Contents: write). A ruleset that requires a pull request for every change will reject the cask commit.
2. **Apple credentials**, kept outside the repo.
   - A **Developer ID Application** certificate exported as a `.p12` (certificate and private key).
   - An App Store Connect API key with the Developer role: Users and Access → Integrations → Team Keys. Download the `.p8` once. Note the key ID and the issuer ID.
3. **Homebrew tap token.** A fine-grained personal access token whose only repository is `Stringsaeed/homebrew-tap`, with **Contents: Read and write**.
4. **Upload the secrets.** `gh` must already be logged in (`gh auth status`). The script prompts for the `.p12` password and the tap token. It prints nothing secret and writes nothing to disk.

   ```sh
   scripts/release/set-github-secrets.sh \
     --p12 ~/Desktop/DeveloperID.p12 \
     --p8 ~/Downloads/AuthKey_XXXXXX.p8 \
     --key-id XXXXXX \
     --issuer 00000000-0000-0000-0000-000000000000
   ```

   That sets `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_API_KEY`, `APPLE_API_ISSUER`, `APPLE_API_KEY_P8`, and `HOMEBREW_TAP_TOKEN` on `Stringsaeed/o-log-n`. Press Enter at the tap-token prompt to leave an existing token unchanged. `REPO=owner/name` overrides the target repository.

5. **Runner.** The release and CI jobs use the GitHub-hosted label `xcode-27` (Xcode 27). The repository must be allowed to use that runner.

`version.txt` is the version release-please owns. `scripts/release.sh` stamps it into the app it builds (`CFBundleShortVersionString`). `CFBundleVersion` is `GITHUB_RUN_NUMBER` on the runner, and the git commit count on a Mac. `Support/Info.plist` in the repo stays the template.

## Local release

The same script runs on a Mac. It does the following:

1. It builds the release app with `scripts/bundle.sh release`.
2. It writes the version into the built bundle.
3. It signs the app with the **Developer ID Application** certificate, using the hardened runtime and a secure timestamp. Logn is not sandboxed, and it needs no entitlements today. If it ever does, add `Support/Logn.entitlements` and the script picks it up.
4. It notarizes the app as a zip, then staples and validates the ticket, so the app passes Gatekeeper offline after it is copied out of the DMG.
5. It builds an APFS, LZFSE-compressed (`ULFO`) DMG containing `Logn.app` and an `Applications` alias. It signs, notarizes, staples and validates the DMG.
6. It runs `spctl` assessments on both artifacts and writes `Logn-<version>.dmg.sha256`.

### Notary credentials

Choose one of the two options.

**A. Keychain profile (local Mac).**

1. Create an app-specific password at account.apple.com → Sign-In and Security → App-Specific Passwords.
2. Run the command below. notarytool prompts for the password and stores it in your login keychain.

   ```sh
   xcrun notarytool store-credentials logn-notary \
     --apple-id "<your Apple ID email>" --team-id "<your 10-character Team ID>"
   ```

**B. App Store Connect API key (what CI uses).**

```sh
export NOTARY_KEY=~/keys/AuthKey_XXXXXX.p8 NOTARY_KEY_ID=XXXXXX NOTARY_ISSUER=<issuer-uuid>
```

Keep the `.p8` outside the repo. When `NOTARY_KEY` is set, the script uses it and ignores the keychain profile. Before notarizing, it calls `notarytool history` with whichever of those two you gave it.

### Signing identity

The login keychain holds **several identical "Developer ID Application" certificates** for the same team. Because they share a name, signing by name is ambiguous. With `SIGN_IDENTITY` unset, the script signs by the SHA-1 hash of the first valid Developer ID identity.

```sh
security find-identity -v -p codesigning          # list hashes
SIGN_IDENTITY=<sha1> scripts/release.sh 0.1.0
```

A full certificate name works only when exactly one identity in the keychain has that name, which is the case in CI's temporary keychain. The script then signs with that certificate's hash. If the name matches more than one certificate, the script stops and asks for a hash.

Consider revoking the duplicates at developer.apple.com, since Developer ID certificates are limited per team.

### Usage

```sh
scripts/release.sh 0.1.0                      # full: build, sign, notarize, staple, DMG
SKIP_NOTARIZE=1 scripts/release.sh 0.1.0      # dry run: signed but not notarized
SKIP_BUILD=1 scripts/release.sh 0.1.0         # reuse build/Logn.app
```

A dry run was verified on 2026-11-19:

- The app is signed with `flags=0x10000(runtime)`, and the authority chain is Developer ID → Developer ID CA → Apple Root CA.
- The DMG is signed.
- `spctl` reports `Unnotarized Developer ID`, which is the expected result when notarization is skipped.

## Troubleshooting

- Status `Invalid`: the script prints `notarytool log <id>`. The usual causes are an unsigned nested binary, a missing hardened runtime, or a missing timestamp.
- `stapler validate` fails right after acceptance: Apple's CDN can lag by a minute. Re-run `xcrun stapler staple dist/Logn-<v>.dmg`.
- Check what users will see with `spctl --assess --type open --context context:primary-signature -vv dist/Logn-<v>.dmg`.
- CI signing fails with "ambiguous" or "identity not found": `APPLE_SIGNING_IDENTITY` must be the certificate's common name (`Developer ID Application: … (TEAMID)`), and the `.p12` must contain that one identity. `set-github-secrets.sh` refuses a certificate that is not a Developer ID Application certificate.
- The Homebrew job fails on `git push`: the tap token needs Contents: write, and the tap's default branch must allow that push.

## Later

- Updates via Sparkle 2 (an EdDSA-signed appcast hosted on ologn.app). That needs Sparkle's framework signed inside the bundle; the nested-code loop in `scripts/release.sh` already handles a nested binary.
- A universal (arm64 + x86_64) build if Intel Macs on macOS 26 should be supported. Today's build is arm64-only, and the cask depends on `arch: :arm64`.
