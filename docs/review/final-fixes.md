# Final fixes

Owned findings: 1, 2, 4, 5, 7, 8, 10, 11, 12, and the selftest-quality section. Findings 3, 6, and 9 were left to the orchestrator. Those four files were not edited: `CodecSupport.swift`, `FolderCodec.swift`, `Sources/ologn-cli/main.swift`, `Tests/OLogNKitTests/ReleaseFixesTests.swift`.

Invariant, at the top of `ReplaceService` and `JobStore`, and on `PanelCoordinator`: no Reveal, Preview, Copy, drag-out, Trash Output, Replace, or Undo acts on a file unless its identity matches a stamp the engine recorded. Trash, Replace, and Undo re-check that stamp on the same `JobFileWork` queue immediately before the move.

## Findings

1. **Output identity.** `OutputWriter.publish` stats the file the exclusive rename just published and returns that fingerprint with the URL. `CompressionEngine` runs `publish` inside `Offload.run` and stores the stamp on `JobResult.outputFingerprint` (nil when there is no published file, so existing initializers still compile). The store copies that stamp onto the card when the job finishes. It does not fingerprint the path again and adopt the result. `claimOutput` compares a fresh stat with the stored stamp. Trash passes the stamp into `ReplaceService.discard`, which checks and trashes on the same queue. Undo stamps the file it just moved before returning. History stores the stamp as `outputStamp` and restores it onto the result and the card. Tests: `publishedStampMatchesTheFileThenStopsMatchingAfterRewrite`; history scenario `reused-output` (live overwrite, restored card, trash, replace, and the Done pill).

2. **Folder Replace.** `JobItem.canReplaceOriginal` is false for folders. The shared command list feeds the pointer buttons and the VoiceOver actions, so both are disabled. The pointer button stays hittable so the tooltip can show, and the action returns without running. The tooltip is `Replace Original is unavailable for folders. The archive keeps the original folder.` `replaceOriginal` returns that message before any file IO, including the simulated demo path. Test: history scenario `folder-replace`.

4. **Selftest isolation.** `--selftest-history` installs a scratch app-support directory and an absolute-path defaults suite, seeds both with sentinels, and registers cleanup before any scenario. No scenario reads `~/Library/Application Support/Logn` or `app.ologn.mac`. The other selftests install the same kind of scratch in `AppDelegate` before constructing settings. Test: `demo-writes-nothing`, `scratch-sentinel`, and the post-run hashes below.

5. **Recovery is on disk.** A file that parses with a bad row is copied aside (`history.corrupt-*.json`), then the good rows replace `history.json` atomically. Recovery is `.failed` if either step fails. An unreadable file is still moved aside and reported as failed. Undo of a removal calls `scheduleHistorySave`. Tests: `malformed-entry` (two loads, one corrupt copy, both good names still in `history.json`), `undo-persists`.

7. **Demo writes nothing.** `--demo` draws thumbnails with Core Graphics into `DemoThumbnails`, keyed by `/ologn-demo/…` URLs. `ThumbnailLoader` and `FileThumbnailView` use that cache and do not create files. `Demo.installPopulatedPreview` is the path both launch and the isolation scenario use. `persistsHistory` is false and `skipLoginItem` skips `SMAppService`. Test: `demo-writes-nothing` (populated preview, thumbnail loads, retry, replace, trash, and a settings edit; scratch support, temp `ologn-demo*`, and the scratch defaults suite stayed unchanged).

8. **Reveal and preview use the stamp.** The Done pill and its drag well keep job ids. `doneURLs` is display only. A click or drag resolves each id through `claimActionURL` immediately before a URL is handed to Finder, Quick Look, or the pasteboard. A card with an output must match the output stamp. A card with no output must match the source stamp. No stamp means no URL. Test: `reused-output` (pill returns nothing after the file is replaced) and `source-stamp` (an already-optimal card reveals the source, then refuses it after the source is rewritten).

10. **History cap.** `capHistory` runs when a restore finishes, when a save is scheduled, on quit flush, and on `persistHistoryNow`. The cap is 2,000 terminal cards, oldest first. The save hands a `[JobItem]` snapshot to `HistoryWriter`, which builds `HistoryEntry` values on its queue. Test: `history-cap` (2,001 stored rows load as 2,000, dropping `cap-2000.txt`; a live compression stays at 2,000 and drops `cap-1999.txt`).

11. **Quick Look generation.** `showQuickLook` captures `trayGeneration` and the job id before awaiting the claim. It presents only when that generation is current, the tray is still open, and the selected id is still that job. `dismissTray` bumps the generation. Test: `quicklook-generation` reports `skipped: screen locked` on this run. The scenario is written to block the job’s file queue, dismiss during the claim, and require `quickLookPresentations` to stay unchanged. It did not run unlocked.

12. **Typed failure.** `HistoryEntry.failureKind` is optional (`outputNotWritable`, `unreadable`, `diskFull`, `verificationFailed`, `codec`). Old rows decode as nil and restore as `.codec`. `outputNotWritable` restores as itself, so Choose Folder stays on the card. Test: `permission-restore`.

## Selftest quality

`--selftest-history` now does what those six names claim, and adds one headless scenario for each owned fix that can run without a window:

| Scenario | What it does |
| --- | --- |
| `demo-writes-nothing` | Populated demo path. No writes under scratch support, temp, or the scratch defaults suite. |
| `malformed-entry` | Loads the mixed file twice. |
| `reused-output` | Live race, then a restored card, trash, replace, and the Done pill. |
| `resolved-location` | Replace and Undo through the store, then reload. |
| `stale-clear` | `remove` then `clearFinished`, using the store’s generations. |
| `undo-persists` | Clear, undo, and the card is in the file. |
| `folder-replace` | Finding 2. |
| `source-stamp` | Finding 8 for an output-less card. |
| `history-cap` | Finding 10. |
| `permission-restore` | Finding 12. |
| `quicklook-generation` | Finding 11. Skipped while the screen is locked. |
| `scratch-sentinel` | Finding 4. Sentinel file and defaults key still present. |

## Verification

- `swift build -c release -Xswiftc -warnings-as-errors` — clean.
- `swift test` — three runs, 43 tests passed each time.
- `--selftest` — exit 0. Job outcome `compressed`.
- `--selftest-replace` — exit 0. Scenarios 1, 3, 4, 5, 13 passed.
- `--selftest-keys` — exit 1. Scenarios 6, 7, and 8 passed. Scenario 2 failed with `shown false panel true resign true restored false blur true focus false count 0`. The screen was locked (`quicklook-generation` reported `skipped: screen locked` in the same session). That scenario needs the tray to become key.
- `--selftest-history` — exit 0. All scenarios passed. `quicklook-generation` was the locked-screen skip.
- `--bench-tray` — exit 0. `trayOpenMs` 66.43.
- `scripts/bundle.sh` then `codesign -v build/Logn.app` — exit 0.
- No `OLogNApp` or `Logn` process left running.

`~/Library/Application Support/Logn/history.json` before and after: sha256 `a9996b9d3e95fe6457bc2d1b5fe752100987f6a89fedd1bcb3b2066b8782087f`, 1053 bytes, mtime unchanged.

`defaults export app.ologn.mac -` before and after: sha256 `633cc0e719802879b0f3cbffdba761832cbabd43184194266e9db2db38c16f72`. The session-start OpenStep export at `/tmp/ologn-defaults-before.plist` is still sha256 `2df93d2b9679d94785076d01c6f869798d2d433814300ed455fb3b28b3530620` (164 bytes). Same domain, two encodings. Nothing under `app.ologn.mac` changed.

## Residual

- Finding 11 is implemented and skipped, not exercised, while the screen is locked. Scenario 2 of `--selftest-keys` fails for the same reason.
- A folder fingerprint still ignores a same-length rewrite of a child. Replace Original is disabled for folders instead of trying to detect that.
- `alreadyOptimal` has no output file, so `outputFingerprint` stays nil. Reveal uses the source stamp.
- History rows written before `failureKind` or `outputStamp` restore as `.codec` and cannot claim a file.
- If `stat` fails after the exclusive rename, `publish` throws and the job fails. The published file is left in place.
- `discard` checks the stamp and then trashes, with no await between them. Another process can still replace the inode in that gap.
