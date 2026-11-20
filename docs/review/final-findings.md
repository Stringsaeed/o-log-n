# Final review findings (GPT-6.2 Astra, pass 4): all 12 accepted

**Split:** the orchestrator fixes #3, #6 and #9, in `CodecSupport.swift`, `FolderCodec.swift`, `Sources/ologn-cli/main.swift` and `ReleaseFixesTests.swift`. Grok fixes everything else and must not edit those four files.

## High
1. **A live card can adopt someone else's file as its output** (reproduced).
   - The output was atomically replaced between the terminal event and the app's fingerprint task, and `claimOutput` accepted the new inode.
   - Trash also passes only the URL across a second queue hop after validation.
   - Fix:
     - The engine captures the output fingerprint from the file it just published, inside `OutputWriter.publish` / `CompressionEngine` right after the rename, and carries it additively as `JobResult.outputFingerprint: SourceFingerprint?`.
     - The app never "claims" an output by re-fingerprinting whatever is at the path; it compares against the engine's stamp.
     - Every destructive operation (Trash Output, Replace, Undo moves) receives the expected identity and re-checks it on the same queue immediately before acting.
   - Refs: JobStore.swift:572, :378.
2. **Folder Replace accepts a folder whose contents changed after compression** (reproduced: a same-length rewrite of a child kept the folder fingerprint equal).
   - Fix: disable Replace Original for folder jobs in v1, in both pointer and accessibility actions, with a tooltip explaining that the archive keeps the original folder.
   - Refs: Model.swift:72, ReplaceService.swift:95.
3. **[orchestrator] Shutdown can signal a recycled PID, or miss a child launched during shutdown.** Refs: CodecSupport.swift:116, :156.
4. **`--selftest-history` reads the user's real data before installing isolation** (from reading).
   - Fix: install the scratch app-support root and scratch defaults suite before dispatching any scenario, and seed both with sentinels. The real `~/Library/Application Support/Logn` and `app.ologn.mac` must never be read or written by any selftest. Register the scratch for cleanup.
   - Refs: SelfTest.swift:506, :805.

## Medium
5. **Recovered cards can exist only in memory** (reproduced).
   - With one valid and one malformed row, successive loads gave 1 card and then 0, because quarantine moved the only history file.
   - Undo after Clear Done restored a card but left no history file.
   - Fix: preserve the corrupt original as a copy, atomically persist the good rows before declaring recovery complete, and schedule a generation-ordered save after undoing a removal.
   - Refs: HistoryStore.swift:280, JobStore.swift:664.
6. **[orchestrator] An interrupted CLI leaves job scratch behind.** Ref: ologn-cli/main.swift:18.
7. **Starting a populated demo writes eight files** (reproduced).
   - Fix: demo thumbnails come from memory, e.g. CGImages drawn at launch and handed to the thumbnail view through an in-memory cache keyed by the demo URL. No files at all. Include populated demo startup in the isolation test.
   - Refs: Demo.swift:37, AppDelegate.swift:164.
8. **Some Reveal and Preview paths bypass identity checks.**
   - The Done-pill click reveals a cached URL.
   - An output-less restored card reveals or previews whatever now occupies its source path.
   - Fix: resolve pill actions by job ID and validate the output or source stamp immediately before handing a URL to Finder or Quick Look.
   - Refs: PanelCoordinator.swift:336, :445.
9. **[orchestrator] macOS tar treats folder names like `-C` and `@photos` as instructions even after `--`.** Refs: FolderCodec.swift:32, :65.
10. **The 2,000 cap doesn't bound live history or main-actor snapshot work.**
    - Fix: enforce the cap at terminal transitions and undo, and pass a value snapshot to the writer to convert off-main.
    - Refs: JobStore.swift:724, :142.
11. **An in-flight Quick Look request can reopen the preview after the tray is dismissed.**
    - Fix: capture the tray generation and selected job before awaiting, and require both to match, with the tray open, before presenting.
    - Ref: PanelCoordinator.swift:780.
12. **A restored permission failure loses its Choose Folder action.**
    - `.outputNotWritable` round-trips as `.codec`.
    - Fix: persist a typed failure reason and restore it before building the shared action list.
    - Refs: HistoryStore.swift:143, JobCard.swift:324.

## Selftest quality (from the reviewer)
Strengthen `--selftest-history` so each scenario tests what it claims:
- `demo-writes-nothing` must launch the real populated demo path.
- `malformed-entry` must load twice.
- `reused-output` must cover the live race and the Done-pill click.
- `resolved-location` must drive the real Replace and Undo.
- `stale-clear` must go through the store operations that assign generations.

## Orchestrator fixes (#3, #6, #9), with verification
- **#3: `ChildProcessRegistry`** (CodecSupport.swift) holds `Process` objects under one lock and signals only through `terminate()` while `isRunning`. A PID can be reused only after Foundation has reaped the child, and a reaped child reports `isRunning == false`. After shutdown it refuses new launches, and a child launched mid-shutdown is stopped right after `run()`. Tests use isolated instances: `registryStopsARunningChildAndRefusesLaunchesAfterShutdown` and `childLaunchedDuringShutdownIsStoppedRightAfterRun`.
- **#6: CLI interrupt.** The handler stops the tools, calls `engine.cancelAll()`, and lets the jobs unwind; `main` then exits with 128 + signal. A second signal, or 10 s, forces the exit. Verified on a 0.9 GB folder:
  - exit code is 130 at both 2 s (tar phase) and 12 s (xz phase);
  - the output folder is empty;
  - no new `ologn-*.err` files;
  - free disk space dropped 1,012 MB during the job and came back to within 2 MB after the interrupt.

  macOS blocks this shell from listing `TemporaryItems`, so scratch removal was measured through free space.
- **#9: tar operands.** `TarArchive.createArguments` / `operand` spells names that start with `-` or `@` as `./name`, after `--`, in both creation and verification. The test `folderNamesThatTarTreatsAsInstructionsRoundTrip` covers `-C`, `@photos` and `-rf album`: it archives, verifies and extracts each one.

## Verification pass (Astra pass 5) and orchestrator follow-up, 2026-11-20
Astra re-checked Highs 1, 2 and 4: **NOT FIXED** in narrow paths, verdict "Replace/Trash safe to use: no". The orchestrator then fixed those paths:
- **1a: Replace.** The output's identity is re-checked after the original is trashed and immediately before the move. After the move, whatever landed is verified against the engine's stamp: an exact match for a same-volume rename, or size + modification date when the two folders are on different volumes, detected through `volumeIdentifier`. A mismatch moves the file back and rolls back the trash.
- **1b: Undo.** `ReplaceRecord.trashedFingerprint` holds the original's stamp. Undo restores only a Trash file that matches it, and refuses with "Original no longer in Trash" otherwise. Covered by `--selftest-replace` scenario 14, which writes an atomic impostor into the trashed path.
- **2: Folders.** `ReplaceService.replace` itself refuses `.folder` before any file operation. Covered by scenario 15.
- **4: Selftest isolation fails closed.** If the scratch defaults suite can't be created, the selftest exits 3 instead of falling back to `.standard`. The `--selftest` settings round-trip now syncs the scratch suite instead of `.standard`.

Verified by the orchestrator:
- 43 tests pass, 5 of 5 runs.
- All selftests pass on both the ad-hoc and the Developer ID–signed builds, except `--selftest-keys` scenario 2, which needs an unlocked screen.
- The real `app.ologn.mac` defaults are byte-identical across all runs.

These follow-up fixes were re-verified by Astra (pass 6, verification only) using the pass-5 probes. Items 1a, 1b, 2 and 4 are FIXED, with verdict **"Replace/Trash safe to use: yes"**. The probe logs are in `scratchpad/review6/`.
