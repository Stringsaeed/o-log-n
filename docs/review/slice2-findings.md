# Slice 2 review findings (GPT-6.2 Astra): all 15 accepted

"Reproduced" means the reviewer demonstrated it on this Mac.

## High
1. **Replace trashes the source without verifying either file** (reproduced).
   - With the archive output missing, `replace` reported success and the source ended up in the Trash.
   - With a PNG edited after compression, Replace installed the older compressed bytes and trashed the newer edit.
   - Fix: before trashing anything, validate the source against `JobResult.sourceFingerprint` (the engine now provides `SourceFingerprint.capture(_:)`; run it off the main actor and off cooperative threads). Also validate the output against an output fingerprint captured when the job finished.
   - Keep a recovery record until the swap fully succeeds. If anything fails midway, restore and show the error.
   - Ref: Services/ReplaceService.swift:31.
2. **Tray command keys can stay registered after another app takes focus** (reproduced).
   - Steps: open the tray, press ⌘O, then activate another app while the picker is open. That app received no ⌘Z until Logn was killed.
   - Cause: the resign-key cleanup is skipped while the picker or Quick Look is open, and during the first 300 ms.
   - Fix: release the Carbon command-key registrations unconditionally on resign-key and on app deactivation, and install them only after the tray is confirmed key. While `NSOpenPanel` or Quick Look is up, no tray hot keys may be registered.
   - Scope the local key monitor to events targeting the tray.
   - Ref: Panels/PanelCoordinator.swift:451.
3. **Undo can move a newly created document, or leave a card targeting one** (reproduced).
   - If the user recreates the original path after Replace, Undo moves that new document aside.
   - If `source-min.png` is occupied before Undo, the output goes to `source-min-1.png`, but the card still points at the user's `source-min.png`, including for Trash Output.
   - Fix: verify the installed file's identity (fingerprint) before moving it, and return the actual restored output URL to `JobStore`.
   - Refs: Services/ReplaceService.swift:62, JobStore.swift:175.
4. **Pasting an image can overwrite an existing file** (from reading).
   - Clipboard filenames have one-second precision, and `.atomic` writes replace the destination.
   - Fix: allocate the filename with exclusive creation (`O_CREAT|O_EXCL` or `FileManager.createFile` plus a check), retrying with a suffix on collision.
   - Ref: Panels/PanelCoordinator.swift:753.
5. **A recoverable Undo failure consumes the recovery record** (reproduced).
   - A conflict made Undo throw `occupied`. After the conflict was cleared, a second Undo did nothing.
   - Fix: peek at the stack, pop only after success, and show the conflict or I/O error inline in the tray.
   - Ref: JobStore.swift:168.
6. **Reopening during dismissal leaves an invisible key tray** (reproduced by reopening 40 ms after dismiss).
   - Result: the panel was key, `trayOpen` was true and `trayPresented` was false, and the hidden tray still owned the shortcuts.
   - Fix: set `trayPresented` on every open and invalidate any pending dismissal (use a generation token).
   - Ref: Panels/PanelCoordinator.swift:116.

## Medium
7. **A click right after an abandoned drag strands the dropzone** (reproduced: a click 35 ms after release left it visible and click-through disabled).
   - Fix: end the previous drag session before starting a new gesture.
   - Ref: Services/DragMonitor.swift:55.
8. **The transparent margin accepts drops meant for the app underneath** (reproduced: a drop 8 pt left of the pill was accepted).
   - Fix: use the same capsule geometry for drag entry, drag updates and final acceptance; outside the pill, return `[]` / false.
   - Ref: Panels/DropHostingView.swift:197.
9. **A delayed engine removal can erase a card just restored by Undo** (reproduced).
   - Fix: reconcile pending removals with Undo, or give one component sole ownership of completed-card history.
   - Ref: JobStore.swift:293.
10. **Cross-volume Replace and Undo move files on the main actor.**
    - Fix: stage transfers off the main thread, serialize actions per job, and publish results on the main actor.
    - Refs: JobStore.swift:145, ReplaceService.swift:51.
11. **The `.onDrag` dropzone stays on the display where the drag began.**
    - Fix: reposition it when the cursor enters a different screen.
    - Ref: PanelCoordinator.swift:173.
12. **Dragging a completed batch out of the Done pill exports only the first file.**
    - Fix: one `NSDraggingItem` per output, keeping the self-drag marker.
    - Ref: DropHostingView.swift:114.
13. **One missing settings field resets all saved preferences** (reproduced).
    - Fix: a custom `init(from:)` that falls back to each field's default (`decodeIfPresent ?? default`), including nested `EngineSettings`. `EngineSettings` lives in OLogNKit, so decode it field by field in the app, or add a tolerant decoder in the app layer. Do not modify the engine target.
    - Ref: AppSettings.swift:23.

## Low
14. **Opening Settings hides the only archive-format selector** (U2 requires it in both places).
    - Fix: add the archive row to the Settings deck.
    - Ref: Views/ControlBar.swift:12.
15. **VoiceOver labels are incomplete.**
    - Fix: give each half a descriptive label, e.g. "Smart — drop to compress smaller, visually identical". Combine each card's summary into one label (name, status, before → after, savings) and keep its accessibility actions.
    - Refs: Views/DropzoneView.swift:111, Views/JobCard.swift:50.
