# Slice 3 review findings (GPT-6.2 Astra): all 15 accepted

"Reproduced" means the reviewer demonstrated it with probes built from the production sources.

## High
1. **Restored cards lose output identity** (reproduced).
   - If another file takes `photo-min.jpg`, Reveal selects it and Trash Output trashes it by path.
   - Replace on an untouched restored output wrongly says "The compressed file is missing".
   - The source fingerprint mismatches because `.iso8601` drops fractional seconds.
   - Fix: persist BOTH source and output fingerprints at full precision (e.g. `timeIntervalSinceReferenceDate` as Double, or `.iso8601` with fractional seconds). Check identity immediately before every file action (Reveal, Trash Output, Replace, Copy, drag-out). Disable file actions on legacy entries whose ownership can't be established.
   - Refs: JobStore.swift:310, Services/HistoryStore.swift:48.
2. **History saves the output's original name after Replace or Undo changes it** (reproduced).
   - Fix: persist the resolved output location, plus an explicit no-output state, together with the fingerprint for that location. Schedule a save after Replace and Undo.
   - Ref: HistoryStore.swift:44.
3. **Demo mode still has production engine, file, and settings side effects** (reproduced: a real `.xz` was produced).
   - Paste writes a PNG, Suffix edits save the production `settings.v1`, the login toggle calls `SMAppService`, and the demo writes `/tmp/ologn-demo-ready.json`.
   - Fix: in `--demo`, use in-memory settings (no UserDefaults writes) and a simulated action layer at the service boundary covering submit, paste, drops, retry, replace, trash and login. No engine calls and no filesystem writes. Emit readiness on stdout.
   - Refs: AppDelegate.swift:105, PanelCoordinator.swift:399.
4. **An older save can overwrite a newer save or a clear** (reproduced).
   - Fix: send all disk commits (save, delete, quit flush) through one serial writer, ordered by generation. A stale generation is dropped.
   - Refs: JobStore.swift:598, HistoryStore.swift:156.
5. **An incomplete or failed restore is treated as an empty history** (reproduced).
   - `start()` followed by an immediate quit flush deleted the file.
   - One malformed entry produced zero cards, and quitting then deleted the original.
   - Fix: separate the states loading / restored / failed. Never save before the restore completes, or merge live mutations into it first. Preserve an unreadable file by renaming it to `history.corrupt-<date>.json`. Decode entries individually so one bad record doesn't drop the rest.
   - Refs: JobStore.swift:118, HistoryStore.swift:192.
6. **The shipping `--selftest` overwrites the user's real history** (by reading).
   - Fix: run the selftest persistence round-trip against a temp application-support directory and an isolated `UserDefaults(suiteName:)`. Do the same for `--selftest-replace` and `--selftest-keys` if they touch settings.
   - Ref: AppDelegate.swift:251.

## Medium
7. **Large histories stall the main actor** (measured: 40k entries took 214 ms to restore and 62 ms per snapshot, and every terminal event builds a snapshot).
   - Fix: coalesce before building the snapshot, reconstruct entries off-main, use `URL(fileURLWithPath:isDirectory:)` with explicit hints, and cap history at e.g. 2,000 entries, pruning oldest first.
   - Refs: JobStore.swift:105, :594.
8. **Closing the tray leaves its Quick Look panel visible** and controlled by the hidden tray (reproduced).
   - Fix: on dismiss, mark the tray closed, close the preview it controls, and clear preview state.
   - Ref: PanelCoordinator.swift:167.
9. **Workers → Auto keeps the previous manual CPU limit** (by tracing).
   - Fix (app side only): resolve Auto to an explicit P-core count when building `EngineSettings`, so the gate is always reset. A limit change applying to waiting jobs is acceptable; document it.
   - Ref: Views/SettingsDeck.swift:82.
10. **The control bar has no archive-format selector**, which U2 requires.
    - Fix: add a control-bar menu `Smallest (.tar.xz)` / `Opens everywhere (.zip)` bound to `archiveFormat`. Coordinate with the visual pass on control-bar hierarchy.
    - Ref: ControlBar.swift:20.
11. **The suffix field swallows ⌘⌫** (reproduced).
    - Fix: while a text field editor owns focus, suspend tray command registrations except Esc, or forward intercepted editing chords natively.
    - Ref: PanelCoordinator.swift:950.
12. **VoiceOver can't invoke Retry or Choose Folder on a failed card.**
    - Fix: build pointer and accessibility actions from one state-dependent action set, including recovery actions and fingerprint-based Replace eligibility.
    - Refs: JobCard.swift:68, :190.
13. **Undo toasts still slide under system Reduce Motion.**
    - Fix: use an opacity-only transition under Reduce Motion.
    - Ref: Views/UndoToast.swift:41.

## Low
14. **Increase Contrast skips the selected and failed card borders.** Apply the contrast width in every state. Ref: JobCard.swift:236.
15. **The demo shows `.dmg` as an unsupported failure.**
    - The engine treats `.dmg` as already compressed, so it is "Already optimal".
    - Fix: show the disk image as Already optimal, and use a write-permission failure ("Can't write to Desktop · Choose Folder…") for the failed card.
    - Refs: Demo.swift:89, SkipGate.swift:7.
