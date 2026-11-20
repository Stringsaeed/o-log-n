# Slice 2 fixes

All 15 accepted findings are fixed in `Sources/OLogNApp`. The engine target was not changed.

Replace and Undo share one rule, written at the top of `Services/ReplaceService.swift`: no sequence of user actions may lose the only copy of a file, overwrite a file Logn did not create, or leave a card pointing at a file that is not its output. File moves, fingerprints, and Trash run on a per-job serial `DispatchQueue` via `JobFileWork`, and the result is published on the main actor.

## 1. Replace trashes the source without verifying either file

**Fix.** Before any mutation, `ReplaceService.replace` checks the source against `JobResult.sourceFingerprint` and the output against a fingerprint captured when the job finished (`JobStore.scheduleOutputFingerprint`, off the main actor). A missing or mismatched file throws `outputMissing` or `sourceChanged` / `outputChanged` and does not trash anything. The swap keeps a `ReplaceRecord` until it finishes. If a later step fails, the earlier move is reversed. If that reverse fails, the error is `incomplete(ReplaceRecord)` and the ledger keeps the record, whose paths are where the bytes actually are.

**Verified.** `--selftest-replace` scenario 1: deleting the output refuses with `outputMissing` and leaves the source; editing the source refuses with `sourceChanged`; editing the output refuses with `outputChanged`.

**Residual.** A nil source fingerprint (a result built without a snapshot) refuses the replace. That is intentional. Cross-volume recovery was not exercised on a second volume (see finding 10).

## 2. Tray command keys stay registered after another app takes focus

**Fix.** `releaseCommandKeys()` runs at the start of `windowDidResignKey`, before the dismiss guards, and from `applicationDidResignActive`. `installCommandKeysIfSafe` registers the 13 tray chords only when the tray is open, key, and no open panel, Quick Look, or panel session is up. `beginPanelSession` (browse and choose-folder) releases them first. The local key monitor consumes a key only when `event.window === tray` and the tray is key. The global ⌃⌥Space toggle is not one of the tray chords.

**Verified.** Live, pid 6279, evidence in the fix2 scratchpad. ⌃⌥Space opened the tray, a click made it key, ⌘O opened an `NSOpenPanel` titled Open (`f2-picker.png`). Activating "Logn fix2 undo target" and pressing ⌘Z delivered Undo once (`undo-delivered count=1`) while that pid was still alive and the picker was still up (`f2-cmdz.png`). `--selftest-keys` scenario 2 also checks the registration count: 13 when key, 0 during a panel session, 0 after resign-key, 0 after `applicationFocusChanged(false)`.

**Residual.** None observed for this bug. Quick Look was covered by the same release path and by the selftest's panel-session count, not by a live Quick Look session.

## 3. Undo can move a file Logn did not create, or leave the card pointing at one

**Fix.** Undo captures the file at the installed path and moves it only when the fingerprint matches the file the swap installed. A foreign occupant is left in place (`occupied`, or the installed bytes are exclusive-moved to `stem-2.ext`, `stem-3.ext`, …). The URL returned to `JobStore` is the path those bytes landed on. `OutputPin` records it. An identity mismatch unpins the card (`.pinned(nil)`) so it stops claiming the foreign file, and the undo record stays.

**Verified.** `--selftest-replace` scenario 3. After replace, overwriting the installed path makes undo return `outputChanged`, keeps the ledger, and pins nil. A user file already at `photo-min.png` is not overwritten; undo moves the installed bytes to `photo-min-2.png`.

**Residual.** None on the same volume. The suffix sequence is `-2`, `-3`, not the old `-1`.

## 4. Pasting an image can overwrite an existing file

**Fix.** `ExclusiveFile.create` opens with `O_CREAT|O_EXCL|O_WRONLY` on the job queue and retries `stem-2.ext`, `stem-3.ext`, … on `EEXIST`. Clipboard paste goes through that helper.

**Verified.** `--selftest-replace` scenario 4: two creates with the same stem; the second file is `stem-2.png` and the first bytes are unchanged.

**Residual.** The search stops at attempt 10000 and then throws. That is not a realistic clipboard collision.

## 5. A recoverable Undo failure consumes the recovery record

**Fix.** `UndoLedger.peek` does not pop. `commitSuccess` pops only after the file operation returns. `occupied`, `notInTrash`, and other failures leave the record in place. A second undo runs the same record.

**Verified.** `--selftest-replace` scenario 5: a blocker at the original path makes the first undo return `occupied` without moving the installed file or popping; after the blocker is removed, the second undo restores the file and the ledger is empty.

**Residual.** A permanent `notInTrash` stays at the top of the stack, so older undo records wait behind it. The tray shows "Original no longer in Trash". Clearing that record would require a new gesture; this round does not add one.

## 6. Reopening during dismissal leaves an invisible key tray

**Fix.** `showTray` bumps `trayGeneration` and, when the panel is still on screen, sets `trayPresented = true` immediately. `dismissTray` bumps the same generation. The deferred `orderOut` runs only if the generation is unchanged and the tray is still closed.

**Verified.** Live, two steps, because a single "still visible" check can pass if the hotkey never fired. A lone ⌃⌥Space hid the tray (window count 1 → 0) and the next one showed it (0 → 1), so the toggle was live. Then dismiss, 40 ms, reopen, sampled every 20 ms for 800 ms: all 40 samples still had the tray window (`hidden-samples=0`). The old bug ordered the panel out about 230 ms after dismiss, which would have produced zeros in that trace. `--selftest-keys` scenario 6 does the same reopen inside the process and checks `trayOpen`, `trayPresented`, `isVisible`, and the chord count. Screenshot `f6-reopen.png` shows the tray still up; the Open panel from finding 2 was still on screen in that shot and was closed with the process afterward.

**Residual.** The 40 ms gap is wall time between the two Carbon events, not a timestamp inside `dismissTray`. The in-process selftest sleeps 40 ms on the main actor between `dismissTray` and `showTray`, which is the stricter scheduling.

## 7. A click right after an abandoned drag strands the dropzone

**Fix.** `DragSessionModel.beginGesture` ends a session that is still tracking or waiting out the 150 ms drop delay, and the monitor calls `onEnded` on that mouse-down. The delayed end is token-checked, so the click also cancels it. A click that never moved 24 pt does not arm a new delay. A local monitor applies the same rules inside Logn's own windows.

**Verified.** Live file drag: the 304×96 dropzone appeared (`f7-during.png`, bounds 748,43 304×96). Mouse-up away from the pill, then a click 35 ms later at the same point. 500 ms later the drop window was gone (`f7-after.png`, window list had no 304×96 window). `--selftest-keys` scenario 7 checks the model: a mouse-down while `endPending` asks the caller to end immediately.

**Residual.** The 150 ms delay is still there for a real drop, so the pill can linger briefly after a release that is not followed by a click. That is the drop landing window, not the stuck-panel bug.

## 8. The transparent margin accepts drops meant for the app underneath

**Fix.** `DropzoneMetrics.contains` is the capsule (a puck uses the rounded rect). `hitTest`, `draggingEntered`, `draggingUpdated`, and `performDragOperation` all use it. A point in the panel but outside the capsule is not a drop target.

**Verified.** Live drop at the margin. The expanded top-center pill is local (12, 14, 280×76); 8 pt to its left is local (4, 52). The drag ended at AppKit (752, 1082), which is the live panel origin (748, 1030) plus that point, with `NSDragOperationNone` (`operation=0`). 800 ms later the drop window was gone (`f8-during.png`, `f8-after.png`). An accepted drop would have stayed up through compression and the dwell. `--selftest-keys` scenario 8 checks the same local point: inside the 304×96 panel, outside the capsule, and the center inside.

**Residual.** The first drag-enter while proximity is still false uses the smaller 228×60 pill. That pill sits inside the expanded one, so the 8 pt margin of the expanded pill is outside it too.

## 9. A delayed engine removal can erase a card just restored by Undo

**Fix.** `JobStore` ignores `.removed` when the card is still in `items`. The store is what removes a card; the engine event is only the echo of `CompressionEngine.remove`. An undo that put the card back is left alone.

**Verified.** By reading the `apply` switch. There is no selftest for this path: `Job` has no public initializer the app can use to push a synthetic `.removed` through `JobStore`. The branch is a guard around the existing bookkeeping.

**Residual.** If the engine ever published `.removed` for a reason other than the store's own `remove`, a card that was still listed would now be kept. The current engine publishes `.removed` only from `CompressionEngine.remove`.

## 10. Cross-volume Replace and Undo move files on the main actor

**Fix.** `JobFileWork` runs each job's file work on a dedicated serial `DispatchQueue` behind a continuation. `ReplaceService` and `ExclusiveFile` assert `dispatchPrecondition(.notOnQueue(.main))`. Same-volume moves use `renamex_np` with `RENAME_EXCL`. On `EXDEV`, `FileMove` copies with `COPYFILE_ALL|COPYFILE_EXCL|COPYFILE_RECURSIVE` to `.ologn-move-<uuid>` on the destination, exclusive-renames into place, and only then deletes the source. A failed copy deletes the partial and leaves the source.

**Verified.** The same-volume selftest scenarios run through `JobFileWork`, so they take the off-main path. The release build is clean under `-warnings-as-errors`, including the `Synchronization.Mutex` that guards the queue map (`OSAllocatedUnfairLock` is not in this SDK).

**Residual.** The `EXDEV` branch was not run against a second volume on this machine. A crash between the exclusive rename and the source delete would leave two copies, not zero. That still satisfies the "do not lose the only copy" rule.

## 11. The `.onDrag` dropzone stays on the display where the drag began

**Fix.** While `effectivePresence == .onDrag` and the panel is not pinned to the status item, `fileDragMoved` compares `ScreenLocator.underMouse()` with `dropScreen` by identity and calls `placeDropzone` when the screen changes. `placeDropzone` records `dropScreen`.

**Verified.** By reading `fileDragMoved` and `placeDropzone`. This Mac has one built-in display, so the branch did not run live.

**Residual.** Not live-tested on a second display. `NSScreen` identity is the comparison; a resolution change that keeps the same object would not reposition, which is correct.

## 12. Dragging a completed batch out of the Done pill exports only the first file

**Fix.** `DoneDragWell` is an `NSView` dragging source covering the done/optimal pill except the trailing 32 pt chevron. It writes one `NSDraggingItem` per output URL (`url as NSURL`). The self-drag marker `app.ologn.mac.self-drag` is set on the session pasteboard in `draggingSession(_:willBeginAt:)`. The job-card thumbnail still uses SwiftUI `.onDrag` for a single file.

**Verified.** By reading `DropHostingView`. Not dragged live onto the Finder; the well is created only for `.done` / `.optimal`, and the live checks stopped at the ready pill.

**Residual.** A Finder drop of a multi-file well was not performed in this pass. `NSItemProvider` was not used because it does not conform to `NSPasteboardWriting` here; `NSURL` does.

## 13. One missing settings field resets all saved preferences

**Fix.** `AppSettings` uses a hand-written `init(from:)` / `encode(to:)`. Each field is `try?` decoded and keeps its default on failure. Nested `EngineSettings` is decoded field by field in the app (`TolerantEngineSettings`) so a bad or missing engine key does not wipe the rest. A missing engine object becomes `EngineSettings()`. `maxCPUJobs` is applied only when the key is present and not null.

**Verified.** `--selftest-replace` scenario 13: `historyDays` removed, `jpegLossless` removed, `quality` set to `"not-a-preset"`, then a second decode with the engine key removed. Surviving fields stay, defaults come back as history 7 days, quality `.balanced`, JPEG `.pixelExact`, and a missing engine is `EngineSettings()`.

**Residual.** An unknown future field is ignored, which is what tolerant decoding is for. Values of the wrong JSON type also fall back to the default for that field only.

## 14. Opening Settings hides the only archive-format selector

**Fix.** Settings column 2 starts with an Archive menu (`ArchiveFormat.title`: "Smallest (.tar.xz)" / "Opens everywhere (.zip)"), labeled "Archive format" for accessibility. The control bar still hides its archive control while Settings are open; the new row is the one that stays visible. Default remains `.xz`.

**Verified.** By reading `TrayView.archiveMenu`. The live tray screenshots show the closed-tray control ("Smallest (.tar.xz)") because Settings were not opened during the event checks. No separate Settings screenshot.

**Residual.** Visual polish of the row is out of scope. The menu is the same control style as the other Settings rows.

## 15. VoiceOver labels are incomplete

**Fix.** Each dropzone half uses the finding's strings: "Smart — drop to compress smaller, visually identical" and "Lossless — drop to compress with exact quality", and `.accessibilityAddTraits(.isButton)`. Each job card is one element (`.accessibilityElement(children: .ignore)`) with a combined label and named actions: Reveal in Finder, Copy Compressed File, Replace Original (Moves Original to Trash), Preview with Quick Look, and Remove from List or Cancel Compression. `showQuickLook(for:)` stays private; `previewItem(_:)` is the public entry.

**Verified.** By reading `DropzoneView.half` and `JobCard`. VoiceOver was not run against the live app.

**Residual.** Copy and Replace are advertised even when the pointer button would be disabled. Activating one then still goes through the store, which toasts rather than performing the file operation. Inline replace/undo errors are real text on the card (`actionError`), separate from the accessibility label.

## Checks

| Check | Result |
| --- | --- |
| `swift build -c release -Xswiftc -warnings-as-errors --product OLogNApp` | Clean. |
| `scripts/bundle.sh` | Produced `build/Logn.app`. `codesign -v` passed. |
| `--selftest` | Exit 0. `hotkeyStatus` 0, `job` `compressed`, `presence` `onDrag`. |
| `--selftest-replace` | Exit 0. Scenarios 1, 3, 4, 5, 13 passed. |
| `--selftest-keys` | Exit 0. Scenarios 7, 8, 2, 6 passed. |
| `swift test` | 38 tests passed. App sources were not part of that target; it was run to confirm the engine tests still pass. |
| Live 2, 6, 7, 8 | Passed. Evidence under `<scratch>/fix2/`. |

The Logn process started for the live checks (pid 6279) was killed afterward. No `OLogN` process was left running.

## Engine changes wanted

None. The fix-round-1 API (`SourceFingerprint`, `JobResult.sourceFingerprint`) was enough.

A public `Job` initializer would let a future selftest drive finding 9 through `JobStore` instead of by inspection. It is not required for the fix.
