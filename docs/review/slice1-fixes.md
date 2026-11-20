# Slice 1 fixes

All 20 accepted findings are fixed in the engine, the CLI’s underlying library, and the JPEG shim. Public API changes are additive. `OLogNKit.version` stays `0.1.0`.

## Findings

1. **Folder output inside the source.** Before a lane is taken, a folder job resolves both URLs and rejects a destination equal to the source or nested under it with `JobError.outputNotWritable("destination is inside the source folder")`. Files may still write next to their parent. Test: `folderDestinationInsideSourceIsRejected`. Residual: the check is path-prefix based after symlink resolution, so a hard link of a file inside the folder is not treated as containment.

2. **Stale size in the gain gate.** `SourceFingerprint.capture` records `stat` size, mtime, and inode when processing starts (folder size is the sum of regular files). The gain gate and `Job.inputBytes` use that size. A change before publish fails with `JobError.unreadable("source changed during compression")`. `JobResult.sourceFingerprint` carries the snapshot. Tests: `gainUsesFingerprintSizeWhenSourceShrinksWhileQueued`, `sourceChangeDuringCompressionFails`. Residual: `capture` is blocking IO and must not run on a cooperative thread. Tombstones and results keep the fingerprint for the engine lifetime.

3. **PNG tRNS turned transparent pixels opaque.** `straightRGBA` applies the tRNS key before the opacity test, for 8-bit and 16-bit gray and truecolor. Palette reduction is rejected when any alpha sample moves by more than 2. Test: `smartPNGKeepsTRNSTransparency`. Residual: color type 2 tRNS is applied only at bit depth 8 in the 8-bit reader; 16-bit keys are applied in `fill16`.

4. **Smart video dropped alpha.** Alpha is detected from the format description (`ap4h`, `ap4x`, `muxa`, or `ContainsAlphaChannel`) before `AVAssetReader` starts, and the job is skipped with note `alpha channel`. Test: `smartVideoSkipsProRes4444Alpha`. Residual: a codec that carries alpha without those markers is not detected.

5. **Quarantine xattr lost on read-only sources.** Named xattrs (`com.apple.quarantine`, user tags, where-froms) are copied while the scratch file is still writable. A present xattr that cannot be copied fails with `could not copy <name>`. Dates are applied next, and the final mode is applied last. Test: `quarantineXattrSurvivesReadOnlyJPEG`. Residual: xattrs outside that name list are still not copied.

6. **JPEG shim freed a stale destination buffer.** The transcoder owns a heap buffer. Growth doubles it and keeps every byte already written. `empty_output_buffer` is invoked only when the buffer is full, and libjpeg’s `free_in_buffer` is still a stale local copy at that moment, so the flush must treat the whole allocation as live (the same contract as `jpeg_mem_dest`). The error path frees that buffer once. Test: `jpegTranscodeSurvivesCorruptInput` (a JPEG larger than the 64 KiB initial buffer must keep equal coefficients, and a truncated input must return an error). Residual: the exact double-free crash is not forced.

7. **Unbounded image memory.** Decoded sizes use checked multiplication. A 512 MiB per-job budget (`WorkingMemory`) is checked before RGBA, sample, and SSIM allocations. Over budget, Smart PNG/JPEG falls through to a lossless path that does not need a full pixel buffer; Smart HEIC is skipped as `image too large for Smart`. SSIM uses a 9-row integral ring. Tests: `hostilePNGDimensionsDoNotAllocate`, `ssimRollingMatchesIdenticalImage`. The balanced picks stayed `JPEG · q80 + progressive` for sample 03 and `HEIC · q88` for sample 05. Residual: a 1-bit image can pass the sample budget and still skip the RGBA Smart path.

8. **Disk-full pause did not stop a job already waiting for a lane.** After `acquire`, a paused engine releases the lane and leaves the job queued until `resume()`. `FailureMap` walks `NSUnderlyingErrorKey` (single and array) and `underlyingErrors` for `ENOSPC` / `NSFileWriteOutOfSpaceError`. A video append failure records `writer.error` before cancelling the writer, and a bare `CancellationError` is not treated as a user cancel. Tests: `diskFullPauseHoldsTheNextWaiterUntilResume`, `underlyingENOSPCMapsToDiskFull`. Residual: the AVFoundation append-to-`ENOSPC` path is not forced without filling the disk. `finish` resumes waiters before `lanes.release`, so the test polls briefly for the queued state.

9. **`.updated` could precede `.added`.** Subscriber registration, snapshot replay, and publication share one lock. Replay yields the current job as `.added` only. The stream is unbounded. An `.updated` for an unknown id is dropped. Test: `addedPrecedesUpdatedUnderConcurrentSubscribers` (420 jobs, concurrent consumers, and the `inputBytes == 0` then `> 0` transition).

10. **Intake and verification blocked cooperative threads.** `submit` returns ids immediately (`kind` `.generic`, `inputBytes` 0) and always kicks. Folder walk, sizing, skip checks, codec IO, and verifier subprocesses run in `Offload.run` and poll cancellation. Test: `losslessJPEGBatchLeavesTheHeartbeatResponsive`. The CLI stress of 20 folder copies plus 20 copies of `11_server_logs.json` finished with 40 compressed jobs, max job duration 1.4 s. Residual: `PDFDocument` is opened off the main thread; PDFKit’s main-thread requirement is not separately proven.

11. **`verify` certified unrelated archives.** Zip verification extracts with `ditto -xk` and compares regular-file paths and bytes to the source file or folder, ignoring `.DS_Store` and `__MACOSX` and failing on extras. xz requires one completed stream. Empty input to decode throws. Test: `verifyRejectsUnrelatedZipAndEmptyXZ`.

12. **FLAC verify ignored rate and channel count.** `PCMHash` records `sampleRate` and `channelCount` from the file data format. `pcmEqual` compares frames, hash, channel count, and sample rate within 0.5 Hz. Test: `pcmEqualChecksSampleRateAndChannels`.

13. **Cancel could end as verified `alreadyOptimal`.** The engine checks cancellation immediately after the codec returns and before it interprets the outcome. HEIC search throws `CancellationError` when cancel is set, even if a candidate exists. Test: `cancelDuringCodecIsNotAlreadyOptimal`.

14. **Smart progressive JPEG kept metadata the user asked to strip.** Only the progressive fallback (`JPEG · progressive`, `lossless: false`) runs `JPEGMarkers.applyingSmartPolicy`: drop COM, non-ICC APP2, APP1, and other APPn; keep a thumbnail-free JFIF, ICC, and APP14; insert a one-tag EXIF APP1 when orientation is not 1. The lossy search and the lossless styles do not strip. Test: `smartJPEGProgressiveStripsCOMAndKeepsICCAndOrientation`. Sample 04 smart stayed at 4.36% (`JPEG · progressive`), inside 0.6–6%. Sample 03 smart stayed on the lossy path (`JPEG · q80 + progressive`, 23.68%). Residual: if that fallback misses the SSIM or gain bar, the published file is the lossless path, which does not strip.

15. **Lossless JPEG dropped the JFIF thumbnail.** `markers == 2` turns off the generated JFIF and Adobe headers after `jpeg_copy_critical_parameters` and `jpeg_simple_progression`, and before `jpeg_write_coefficients`, so the original APP0 is copied. Test: `losslessJPEGKeepsJFIFThumbnail`.

16. **Palette PNG wrote iCCP after PLTE.** Indexed writers emit iCCP, sRGB, cHRM, gAMA, cICP, and sBIT before PLTE. `pHYs` stays after PLTE. `rebuild` no longer drops sBIT. Test: `indexedPNGWritesColorChunksBeforePLTE`. Residual: keeping sBIT can add a few bytes. The sample bands did not move.

17. **Packed palette PNGs failed verification.** Indexed samples are returned as the raw packed index. Gray samples below 8 bits are still scaled. Test: `packedPaletteOddWidthsVerify` (1-, 2-, and 4-bit, width 65).

18. **Portrait video was rotated twice.** The writer is configured with the encoded `naturalSize`. `preferredTransform` is copied once. Encoded size and display size are verified separately. The bits-per-pixel gate uses the encoded size. Test: `portraitVideoIsNotRotatedTwice`.

19. **`waitUntilFinished` never returned for a removed job.** The signature is unchanged. `remove` keeps a tombstone of the terminal job. An unknown id returns a `.cancelled` placeholder immediately. Test: `waitUntilFinishedReturnsRemovedAndUnknownJobs`. Residual: tombstones are not evicted.

20. **`JobResult.duration` included lane wait.** The clock starts after the lane is acquired and the pause recheck has passed, before the post-acquire hook. A generic skip does not take the wide lane and is timed from the start of `run`. Test: `skipGateDoesNotWaitBehindWideLane`.

## Checks

- `swift build -c release -Xswiftc -warnings-as-errors` succeeded.
- `swift test` passed three times in a row, each about 2.8 s (38 tests).
- Slice 1 CLI table held in both modes, including sample 03 lossless 1.66%, smart `JPEG · q80 + progressive` 23.68%, sample 04 lossless 1.11%, smart `JPEG · progressive` 4.36%, sample 05 smart `HEIC · q88`.
- `ologn-cli verify` exited 0 for the lossless outputs of 01, 02, 03, 04, 10, and 11, and exited 1 for smart 03. `tar -xf` of the folder archive matched the source.
- Sample shasums match `/tmp/ologn-samples-shasum-before.txt`.
