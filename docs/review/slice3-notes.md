# Slice 3 notes

Polish for the tray, dropzone, settings deck, history, status-item glyph, and the screenshot harness. App target only, plus one required `Job` initializer in `Sources/OLogNKit/Model.swift` (see Deviations). No commit.

## Checks

Re-run on the already-bundled `build/Logn.app` after the last source edit. Sources were not changed for this note.

| Check | Result |
| --- | --- |
| `codesign -v build/Logn.app` | clean (`SIGN_OK`). `CFBundleIconFile` is `AppIcon`. `Support/AppIcon.icns` is present. |
| `--selftest` | exit 0. `{"trayFrame":[220,12,1360,298],"dropzoneFrame":[748,1030,304,96],"hotkeyStatus":0,"dragMonitor":true,"job":"compressed","presence":"onDrag"}` |
| History round-trip | `~/Library/Application Support/Logn/history.json` parses with 1 entry after that selftest. |
| Settings round-trip | `defaults read app.ologn.mac settings.v1` succeeds. |
| `--selftest-replace` | exit 0. Scenarios 1, 3, 4, 5, 13 pass. |
| `--selftest-keys` | exit 0. Scenarios 7, 8, 2, 6 pass. |
| `swift test` | 38 tests passed (2.672 s). Vendor C `-Wshorten-64-to-32` warnings are pre-existing and are not the app target. |
| Release app build | `swift build -c release -Xswiftc -warnings-as-errors --product OLogNApp` completed clean (20.42 s) on the sources this binary was bundled from. |
| Processes | no `OLogN` left running. |

`--selftest` persists its job with `persistHistoryNow(minimumDays: 7)` before the temp directory is removed, and it sets `persistsHistory = false` so the debounced saver cannot rewrite the file afterward.

## Tray open

`--bench-tray` builds 200 in-memory items, skips history load, and times `showTray(makeKey: false, immediate: true)` plus `layoutSubtreeIfNeeded` on the production tray frame (not the tall demo frame). Three runs this session:

- 66.78 ms
- 70.40 ms
- 69.23 ms

All under 100 ms. The queue is a `LazyVStack`, so only visible cards lay out.

## Visual review

Lossless copy override: resting caption is **Exact quality**, targeted caption is **Drop exact**. Architecture D2: lossless keeps the content identical, not the file bytes. The review's "Bit-exact" / "Drop bit-exact" strings are not used.

Screenshots are under `<scratch>/slice3/`. Tray and settings are `screencapture -l`. Dropzones are `screencapture -R` of the composited screen (pad 12 pt). Window-buffer `-l` samples Liquid Glass against an empty backdrop and paints a false cyan/magenta fringe; the composited pill is a crisp capsule with a cobalt aimed half.

| # | Pri | Status | What the captures show |
| --- | --- | --- | --- |
| 1 | P0 | done | Cards span the queue column in dark, light, and reduce-transparency. Left edges, thumbs, size columns, and badges line up. |
| 2 | P0 | done | Actions stay in a reserved trailing column. Selecting Mac Pink.heic reveals folder / copy / replace / close without shifting `8.4 MB → 3.0 MB` or `−64%`. |
| 3 | P0 | done | Mode, quality, format, output, and settings menus show one trailing `chevron.up.chevron.down`. No leading AppKit indicator. |
| 4 | P0 | done | Smart thumb is a light neutral capsule. Selection and the aimed dropzone half are cobalt, not olive. `focusEffectDisabled` is on the segment. |
| 5 | P0 | done | Tray luminance stays even. Intake is a recessed dashed well. Reduce-transparency is a solid window fill (`tray-reduce-transparency.png`, 383 KB vs tray-dark 424 KB). |
| 6 | P0 | done | Mac Blue / Mac Pink / Mac Purple.heic show real thumbs on cards and on the done pill. Coast.mov, Disk Image.dmg, Notes.txt, and Contract.pdf stay on the workspace icon because those demo paths are synthetic. |
| 7 | P0 | done | `ByteText.percent`: `≤0` → `0%`, `<0.01` → `<−1%`, `≥0.9995` → `>−99.9%`, `≥0.995` → one decimal capped at 99.9, otherwise a rounded integer. The demo shots use ordinary values (`−64%`, `−59%`, `40%`), not the boundaries. |
| 8 | P0 | done | Untargeted Smart / Lossless read Smallest / Exact quality. Targeted reads Drop to shrink / Drop exact. Titles share a baseline in both aim shots. |
| 9 | P1 | done | "Saved" and "this session" are proportional secondary text. `6.8 MB` is emerald tabular. |
| 10 | P1 | done | sparkles on Smart, checkmark.shield on Lossless. Aimed half is cobalt; the other half is dimmed. Hairline divider stays. |
| 11 | P1 | done | `GlassEffectContainer` wraps the pill with `glassEffectID("dropzone-pill")`. The aimed half uses matched geometry `aim-pill`. A still cannot show the morph. |
| 12 | P1 | done | `DropzonePanel.hasShadow = false`. Composited shots show a 1 pt rim and a soft halo, no rectangular panel shadow. The ⌥ badge offset is `y: 4`; Option was not held, so the badge is not in the shot. |
| 13 | P1 | done | Empty state is a centered lockup outside the scroll view, secondary text, no extra 0.48 opacity, with a ⌘V keycap. The demo tray is full, so this state is not in the screenshots. |
| 14 | P1 | done | Archive left the control bar and lives in the deck as Smallest (.tar.xz). Clear Done is 30 pt. Opacity 0.38 and `allowsHitTesting(false)` apply only when nothing is terminal; the demo has finished jobs, so the button is full strength in the shots. |
| 15 | P1 | done | Interior pills use `SoftPillBackground` (fill + 0.5 pt hairline), not nested `.glassEffect(.regular)`. |
| 16 | P1 | done | Interactive chrome uses `LognColor.accent` / `accentFill` / `accentBorder`. Emerald is reserved for savings. |
| 17 | P1 | done | Selected card has a 1.25 pt cobalt border. Hover fill is a separate token. `ActionIconButton` is 26×26 with its own hover fill. Hover is not in the stills. |
| 18 | P1 | done | Running card: `84.0 MB`, a 112×5 bar, and a single `40%` badge. Queued uses `ProgressView` at 0.75 scale. A still freezes that spinner as a small mark. |
| 19 | P1 | done | Queue has vertical padding, `scrollClipDisabled(false)`, and a 10 pt bottom feather when there are more than 3 rows. The tall demo tray does not clip the last card. |
| 20 | P1 | done | Metrics are SF Pro with `monospacedDigit`. Finished rows show secondary input, tertiary arrow, semibold primary output (`8.4 MB → 3.0 MB`). |
| 21 | P1 | done | Done / optimal pill is 268×58. Headline is 15 pt bold emerald `−64%` with checkmark.circle.fill. Subline `Saved 5.1 MB · Mac Pink.heic` is complete. Tray button is a 24×24 circle. |
| 22 | P1 | done | Intake badge is a 42 pt circle with `square.and.arrow.down`. Mode (184 pt) has sparkles / checkmark.shield. Output has a folder icon. |
| 23 | P2 | done | In-view springs: dropzone 0.22/0.86 and 0.24/0.84, mode segment 0.22/0.88, card hover 0.16/0.90, toast 0.26. Reduce Motion falls back to a short linear animation. Panel open/close timings stay at the Slice 2 values. |
| 24 | P2 | done | Savings, badge percent, dropzone headline/subline, and intake throughput use `contentTransition(.numericText())`, gated by Reduce Motion. Progress UI publishes at ≤15 Hz (66 ms). Terminal events publish immediately. |
| 25 | P2 | done | Symbol effects (bounce, bounce.up.byLayer, repeating pulse, rotate) are gated by `!reduceMotion`. Stills show the symbols at rest. |
| 26 | P2 | done | `ByteText.string` steps to `%.1f MB` at 999_500 bytes and `%.2f GB` at 999_500_000, so `%.0f KB` cannot print `1000 KB`. Not exercised in the screenshots. |
| 27 | P2 | done | Settings rows are 26 pt value capsules with one trailing chevron. Shortcut is a keycap (`⌃⌥Space`) plus an inline 22 pt Reset. |
| 28 | P2 | done | Double-click reveals in Finder (the double-tap gesture is registered before the single tap). A finished thumb scales to 1.05 on hover when an output URL exists. |
| 29 | P2 | done | Disk-full banner: filled Resume and outlined Cancel Queue, both coral capsules. Copy in the shot: "Disk full — paused 2 remaining jobs". |
| 30 | P2 | done | Intake hover brightens the well, raises the dash opacity, and lifts the icon, spring 0.18/0.88. Resting state is what the shots show. |

## Screenshot harness

Honoured only when the flag is on the command line. `--demo` fills the tray in memory and writes no files: queued, running at 0.40, compressed, already optimal, failed, cancelled, a batch header (`Batch · 3 files`, `5.4 MB`), a replaced card, a sticky undo toast, and the disk-full banner. `--demo` does not load or save history, does not start the drag monitor or hotkey, and sets `suspendDismiss` so resign-key does not close the tray.

`--demo-open tray|settings|dropzone-smart|dropzone-lossless|dropzone-done`, `--appearance light|dark`, `--reduce-motion`, and `--reduce-transparency` are in-process. Nothing writes system appearance, accessibility, or another app's defaults.

The demo tray is grown only for screenshots (`fitDemoTray`: 820 pt for the tray, 460 pt for settings) so every card and every settings row is on screen. Production `PanelGeometry` is unchanged. The ready file `/tmp/ologn-demo-ready.json` includes window ids and top-left screen rects for `screencapture -R`.

Files:

- `tray-dark.png`, `tray-light.png`, `tray-reduce-transparency.png`
- `settings-dark.png`
- `dropzone-smart.png`, `dropzone-lossless.png`, `dropzone-done.png`
- `icon-512.png` (512 px)
- `menu-glyph.png`, `menu-glyph-progress.png` (64 px, black template on transparency: 779 and 1,079 ink pixels)

## Icon

`scripts/make-icon.swift` draws every iconset size with Core Graphics (exact pixel contexts, not `NSImage`) and `iconutil` writes `Support/AppIcon.icns`. Artwork is a frosted squircle, two inward cobalt glass jaws, and an emerald diamond core. It does not use `assets/icon.svg`. `StatusGlyph.image(side:progress:)` is the same caliper, as a template image, with an arc from 12 o'clock while jobs run. The arc is drawn into `button.image` so the menu bar tints it. The status-item drop target is unchanged. The arc is hidden while the tray is open or the dropzone is showing a pill, which is why the demo shots do not show it.

## Deviations

- History is `~/Library/Application Support/Logn/history.json` (decision U1). Architecture §6 still says `o-log-n`.
- `Job` gained a public memberwise initializer in `Sources/OLogNKit/Model.swift`. The synthesized one is internal, so history restore and the demo tray could not construct a `Job`. Same labels as the synthesized init. No other kit change. History restore mints a new `JobID` and merges on source URL plus `createdAt`, and it never replaces an in-flight item.
- `--bench-tray` is an extra explicit launch argument. It is not part of the demo flag set.
- Selftest persistence uses `minimumDays: 7`, so a user whose `historyDays` is 0 (On Quit) still leaves a file the checker can parse.
- Writable accessibility overrides are `EnvironmentValues._accessibilityReduceTransparency` and `._accessibilityReduceMotion`, plus `PanelCoordinator.forceReduceMotion` / `forceReduceTransparency`. The public environment keys are get-only. Views that draw glass also read the coordinator flag.
- Sound effects stay out of scope (§7). Folder structure, skip-dotfiles, and reset-stats have no `AppSettings` field, so those rows are not in the deck.
- Archive format stays off the pill row. The Format menu's "Folders & Archives" section and the Settings Archive row both set it (U2). See Final fix round.
- Increase Contrast follows `@Environment(\.colorSchemeContrast)` only. There is no in-app simulation flag, and system settings were not changed.

## Known gaps

- No live menu-bar capture. The status-item window id was not a capturable `CGWindowID`, and the arc is suppressed while the tray or a dropzone pill is up. Evidence is `menu-glyph.png` and `menu-glyph-progress.png`.
- Increase Contrast was not screenshot.
- VoiceOver, Quick Look on Space, and a real `SMAppService` register/unregister were not exercised live. VoiceOver actions are conditional in code: Copy only when `outputURL != nil`, Replace only when `canReplace`. Login-item errors surface as `settings.loginError` on the row. An ad-hoc signature can be refused; that path shows the error and does not crash.
- The sticky "Original no longer in Trash" toast (Dismiss calls `dismissBlockedUndo()`, which drops the ledger top only for that toast) was not screenshot. The demo toast is the successful replace, with Undo.
- Clear Done at 0.38 opacity, the ⌥ dropzone badge, byte-boundary strings, and percent-boundary strings were not screenshot.

## Final fix round

Production geometry on this display is `trayFrame` `[220, 12, 1360, 298]`. `--demo-height 248` simulates a 13" Air. Captures are `screencapture -R` of the composited screen. `--selftest-history` prints one JSON line per scenario and exits 0 only if all six pass.

| Check | Result |
| --- | --- |
| `swift build -c release -Xswiftc -warnings-as-errors --product OLogNApp` | clean |
| `scripts/bundle.sh` and `codesign -v build/Logn.app` | clean |
| `--selftest` | exit 0. `trayFrame` 298 pt, job `compressed`, `hotkeyStatus` 0, `dragMonitor` true |
| `--selftest-replace` | exit 0. Scenarios 1, 3, 4, 5, 13 |
| `--selftest-keys` | exit 0. Scenarios 7, 8, 2, 6 |
| `--selftest-history` | exit 0. `demo-writes-nothing`, `quit-keeps-history`, `malformed-entry`, `reused-output`, `resolved-location`, `stale-clear` |
| `swift test` | 38 tests passed |
| `--bench-tray` | 66.24 ms, 66.28 ms, 64.43 ms. All under 100 ms |
| Processes | no `OLogN` left running |

### Code findings

| # | Status | What changed |
| --- | --- | --- |
| 1 | done | Source and output stamps store `timeIntervalSinceReferenceDate` as a Double. Reveal, Trash, Replace, Copy, drag-out, and Quick Look of an output call `claimOutput` immediately before the file action. Legacy second-precision stamps do not authorize an action. |
| 2 | done | Replace and Undo pin the resolved URL, store that file's fingerprint, and save. A replaced card round-trips `photo-min.heic`. |
| 3 | done | `--demo` uses in-memory settings (`persistsWrites = false`), `skipLoginItem`, and `JobStore(simulated:)`. No engine, no UserDefaults write, no `SMAppService`. Readiness is `demo-ready` on stdout. Demo media is a temp directory deleted on quit. |
| 4 | done | `HistoryWriter` is one serial queue. A commit whose generation is older than the applied generation is dropped. Quit uses `commitBlocking` only after restore has finished. |
| 5 | done | Phases are loading, restored, and failed. A flush during load does not touch the file. One bad object is skipped, the other entries are kept, and the original is copied to `history.corrupt-<date>.json`. |
| 6 | done | `--selftest`, `--selftest-replace`, and `--selftest-keys` set a temp app-support directory and a `UserDefaults(suiteName:)` before `SettingsStore()` exists. |
| 7 | done | Restore and the history snapshot run off the main actor. The cap is 2,000 newest entries. Fingerprint IO goes through `JobFileWork`. |
| 8 | done | Dismissing the tray closes the Quick Look panel and clears its URLs. Not exercised with the Space key in this pass. |
| 9 | done | App-side only. `engineForJobs` fills a nil `maxCPUJobs` with the P-core count (`hw.perflevel0.physicalcpu`, else `activeProcessorCount`). The stored setting stays Auto. A limit change applies to jobs still waiting. |
| 10 | done | Format menu section "Folders & Archives": Smallest (.tar.xz) and Opens everywhere (.zip). The pill tints when archive is `.zip`. The Settings Archive row remains. Four pills. |
| 11 | done | While a field editor is focused, tray chords are not installed. ⌘⌫ is forwarded as `deleteToBeginningOfLine:`. Esc still closes the tray. |
| 12 | done | Failed and cancelled cards keep the recovery action visible at rest, and the same actions are `accessibilityActions`. VoiceOver was not driven live. |
| 13 | done | Toast text is `Replaced Scan.heic (original in Trash)` with an Undo button and a ⌘Z keycap. Opacity-only transition. Tinted capsule, no nested glass. |
| 14 | done | Selected and failed borders use `max(base, 1.5)` when `colorSchemeContrast` is increased. No screenshot: system settings were not changed, and there is no in-app contrast flag. |
| 15 | done | Installer.dmg is already optimal. Protected.pdf fails with "No write permission". The replaced card is `.png → .heic`. Pink HEIC method is `q80`, so the meta line is `HEIC · Smart · q80`. |

### Visual items

| # | Pri | Status | Evidence |
| --- | --- | --- | --- |
| 1 | P0 | done | Toast copy and keycap in `tray-dark-298.png` and `tray-light-298.png`. |
| 2 | P0 | done | Aimed captions measure about 5.8:1 to 7.8:1. Dimmed halves about 5.5:1 to 7.8:1. Done and compressing sublines use `primary` at 0.72. |
| 3 | P0 | done | Settings at 248 pt shows five rows in each column, no scroll, toggles on the trailing edge. `settings-dark-248.png`, `settings-light-248.png`. |
| 4 | P0 | done | Live `StatusGlyph` at 18 pt, @2x, 36×36. Idle and 40% share one canvas. Ring-to-jaw gap measures 2.06 pt. |
| 5 | P0 | done | 1024 squircle inset 100 px, solid inward jaws, emerald diamond. `icon-grid.png` places it between Finder and Safari. |
| 6 | P1 | done | Badge text is `cobaltText`, `coralText`, emerald, or `primary` at 0.78. Fills are 0.12–0.13. Only the thumbnail dims. Waiting and 40% are on the 298 pt trays; Optimal, Failed, and Replaced sit below the fold under the disk banner. |
| 7 | P1 | done | Reduce Transparency pills use a lifted fill plus a 1 pt separator. `tray-flat-dark.png`, `tray-flat-light.png`. |
| 8 | P1 | done | Unselected Lossless is `primary` at 0.75. Resume is white on `#DC2626`. Cancel uses the light/dark coral text. |
| 9 | P1 | done | Settings hides Clear Done, the disk banner, the toast, and the savings line. One gear closes it. Title is 14 pt semibold. |
| 10 | P1 | done | Batch savings read `−5.4 MB`, aligned to the badge column. Batched cards have a leading rail and extra space before the next group. |
| 11 | P1 | done | Same as finding 12. The failed card's Choose Folder action is in the fixture, below the fold at 298 pt. |
| 12 | P1 | done | Replaced note is `.png → .heic`. The toast names `Scan.heic`. |
| 13 | P1 | done | Same as finding 10. Settings still has the Archive row. |
| 14 | P2 | done | Done-pill drag well is `pill.width - 38`. |
| 15 | P2 | done | Intake border is a 1 pt dash, or a 2 pt cobalt stroke while a drag targets it (`tray-drag-dark.png`). ⌘V is a keycap. |
| 16 | P2 | done | Same as finding 14. Capture skipped; system contrast was not changed. |
| 17 | P2 | done | Demo media is a real PNG, HEIC, PDF, and MOV in a temp directory. Fixture matches the engine cases in finding 15. |
| 18 | P2 | done | Empty tray, puck, compressing, drag-hover, and the 298 pt queue (feather when more than 3 items) are in the final directory. |

Section labels and meta lines that were system secondary or tertiary measured about 3.2:1 on the glass. They now use `primary` at 0.72 or 0.82. Rechecked settings labels are about 7.2:1 to 8.3:1.

Screenshots: `<scratch>/final/` (a curated set is committed in `docs/media/`).
