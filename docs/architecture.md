# o-log-n — Architecture (v1 contract)

Status: binding for implementer and reviewer. Where this file conflicts with `docs/research/codecs.md` or `docs/design/ux.md`, **this file wins**; everything not mentioned here stands as written there (ux.md owns sizes, copy, motion, colours). The scaffold builds (`swift build`, probed). Verified on macOS 27.2 / Xcode 27.1 / Swift 6.4 / arm64 (8 P + 4 E cores) on 2026-11-19. "Probed" = I ran it on this Mac; "codecs.md" = taken from that file, not re-run. Probe sources lived in an ephemeral scratch dir; everything needed from them is inlined below.

## 1. Decisions and overrides

| # | Topic | Final call | Reason (one line) |
|---|---|---|---|
| D1 | Meaning of "lossless" | **Decoding the output yields exactly the pixels / samples / bytes that decoding the input yields.** Container, extension and file bytes may change; metadata is kept in Lossless mode. | "Bit-exact file" is impossible for any real gain; content-exact is checkable and is what users mean. |
| D2 | ux copy "Bit-exact" | Subcaption becomes `Exact quality`; hover copy `Drop exact` stays. | FLAC / re-filtered PNG / Huffman-optimised JPEG are not bit-exact files. |
| D3 | JPEG lossless (overrides codecs §2c) | **Keep the source scan type** (baseline stays baseline, progressive stays progressive), optimise Huffman tables, keep all markers. Expect 1–2 %, not 4–10 %. | Probed: baseline→progressive is coefficient-identical (`djpeg` md5 equal) but **ImageIO renders it differently** (22 % of bytes differ, max diff 39/255; cause not investigated — presumably a different decode path for progressive). Baseline-optimised is ImageIO pixel-identical. |
| D4 | JPEG progressive | Used only in Smart mode (after the lossy encode, or as the fallback on low-quality JPEGs), gated by the SSIM check on the final bytes. | Smart tolerates sub-threshold rendering change; Lossless does not. |
| D5 | PDF lossless (overrides codecs §2h) | **No lossless PDF method in v1 → `alreadyOptimal`.** | Probed: `ImageFlateCompress` QuartzFilter saved 0.07 % and is not provably lossless. |
| D6 | HEIC lossless, video lossless | `alreadyOptimal` immediately (no remux, no box cleanup). | codecs.md measured 0–0.02 %; not worth a code path or a verification story. |
| D7 | Audio lossless | PCM WAV/AIFF/CAF (16/24-bit int, ≤ 8 ch) → **`.flac`**; extension change accepted. Float / 32-bit PCM → `alreadyOptimal`. Lossy inputs (mp3/aac/ogg/opus) → `alreadyOptimal` in both modes. | Sample-exact and verified; non-audio chunks (bext, cue, LIST) are dropped — stated in the method note. |
| D8 | Generic single file | **`.xz`** default (`name.ext.xz`), produced by the public `Compression` framework (`COMPRESSION_LZMA`) in parallel 4 MiB chunks, written as concatenated xz streams. | Probed at 4 MiB chunks: 95.35 % on the JSON sample in 517 ms (1 MiB chunks: 95.44 % / 149 ms; single-shot: 95.17 % / 1.5 s). Opens in Archive Utility and `xz`. See R-f for the three costs. |
| D9 | Folder container | **`.tar.xz` default**; `.zip` is a setting (`ArchiveFormat.zip`, applies to single generic files too); **`.aar` is not offered.** | Probed: 86.8 % vs 80.7 % (zip). tar.xz opens natively on macOS (probed) and Linux; Windows 11 23H2+ support, and Windows tools' handling of multi-stream xz, are from recall — **unverified**. zip is one setting away; .aar is Apple-only. Open question Q2. |
| D10 | Folder drop semantics (overrides ux Flow C) | A dropped folder (or bundle) is **one job → one archive**. Per-file optimisation inside folders is out of scope. | "Compress this folder" must give one shareable file; recursive in-place rewriting is a different product. Multi-file drops still form a batch. |
| D11 | Output naming | Media: `<stem><suffix>.<outExt>` (suffix default `-min`, also when the extension changes: `song.wav → song-min.flac`). Archives: `<full name>.xz`, `<folder>.tar.xz`, `<name>.zip`. Collision → `-2`, `-3`, … before the extension. Never overwrite. | One rule, recognisable outputs, Replace-Original can strip the suffix. |
| D12 | Output location | Next to the original (default) or a chosen folder (flat, same naming). Unwritable destination → `JobError.outputNotWritable`; no silent redirect. | Predictable; the UI offers "Choose Folder…". |
| D13 | Dropzone default (overrides ux §2.2) | **Always-visible puck** (`DropzonePresence.always`): ux's 40×40 squircle, right-centre of the primary display (`NSScreen.screens[0]`), expands in place to the split capsule when a file drag starts anywhere or enters the puck. `onDrag` (ux's top-centre summon) and `off` are settings. | User: "the app should show a small dropzone". Also robust: the puck is a real drop target even if global drag detection fails (R-a). |
| D14 | Display name | **`o-log-n`** everywhere (menu: `Quit o-log-n`). "Logn" is open question Q1, not a decision. | Brief. |
| D15 | Method labels | Engine labels only (§3.4): e.g. `PNG · libdeflate 12`. Never `oxipng`, `pngquant`, `MozJPEG`, `zopfli`. | ux.md names tools we do not ship. |
| D16 | Format-convert pill | `Keep Format` (default), `Images → HEIC`, `Images → AVIF`. **No WebP.** | ImageIO cannot write WebP (codecs.md). |
| D17 | Self-drag pasteboard type | `app.ologn.mac.self-drag` | ux.md spells it two ways under the wrong prefix. |
| D18 | Metadata | Lossless: keep everything. Smart: strip non-rendering metadata when `stripMetadataInSmart` (default true) but **always keep ICC profile and orientation**. | Stripping orientation rotates photos. |
| D19 | Tray vertical anchor | `screen.frame.minY + 12`, over the Dock, level `dock + 2` (as ux §2.3). Width/x from `visibleFrame`. Ultrawide cursor-centring rule dropped. | Keeps the tray at the true bottom 25 %; one formula. |
| D20 | Minimum gain | Keep output only if `saved ≥ max(512 B, 0.5 % of input)`; otherwise delete it and report `alreadyOptimal`. | codecs §2i. |
| D21 | Sandbox | Not sandboxed in v1. | Writes next to originals and spawns `/usr/bin/tar`. |

## 2. Feasibility checks

| # | Item | Result | What remains |
|---|---|---|---|
| R-a | Global drag detection: `NSEvent.addGlobalMonitorForEvents([.leftMouseDown,.leftMouseDragged,.leftMouseUp])` + `NSPasteboard(name: .drag)` | **Partly probed.** Monitor installs (non-nil); drag pasteboard `changeCount` and `types` readable (`public.file-url` visible); `accessBehavior == 2`. | **Live check L1** from the bundled `.app`: the probe host already had Accessibility trust (`AXIsProcessTrusted == true`), so "works without Accessibility" is unproven, and no events can be generated headlessly. Read only `changeCount` and `types`, never contents (contents arrive via the drop). If L1 fails, `onDrag` mode is disabled in Settings; `always` mode is unaffected. |
| R-b | PDF via QuartzFilter | **Probed, pass.** `QuartzFilter` is a public class (`Quartz` → `QuartzFilters.framework/Headers/QuartzFilter.h`: `init(properties:)`, `init(url:)`). The write key is the string `"QuartzFilter"`, documented only in a comment in `PDFDocument.h` (no constant). The properties schema is undocumented (it is the `.qfilter` plist). Sample 06 with two annotations and a title added (8,663,152 B) → 572,053 B (93.4 %) in 254 ms at 220 dpi / q 0.82; works off the main thread; page count, text length, 2 annotations (1 link) and title survived. | Outline survival **not tested** (probe input had none) → enforced by verification (§3.4 PDF). Fallback order: in-memory filter → `QuartzFilter(url: /System/Library/Filters/Reduce File Size.qfilter)` → `alreadyOptimal`. |
| R-c | Vendoring libdeflate + libjpeg-turbo as SwiftPM C targets, no CMake | **Probed, pass** (debug + release). libdeflate L12 round-trip OK; JPEG shim reproduced codecs.md byte counts exactly (03: 1,332,220 progressive / 1,426,750 baseline-optimised). SIMD off costs ~1.3× on transcode (98–127 ms vs 81 ms) — accepted. Recipe in §2.1. | Coefficient-equality function in the shim is specified but was not probed. |
| R-d | Carbon hotkey in Swift 6 | **Compiles warning-free in Swift 6 mode; `RegisterEventHotKey(⌃⌥Space)` returned `noErr`.** Pattern in §4.4. | **Live check L2**: handler actually fires. |
| R-e | Non-activating key panel | **Partly probed.** `NSPanel([.borderless,.nonactivatingPanel])` with `canBecomeKey == true`: after `makeKeyAndOrderFront`, `isKeyWindow == true` and the frontmost app stayed Chrome. But `NSApp.isActive` read `true`, contradicting ux §7. `.glassEffect` in an `NSHostingView` inside it compiled and ran. | **Live check L3**: key events reach the tray, the other app's window does not dim, its text caret keeps focus appearance. |
| R-f | xz / tar.xz writer | **Probed.** (1) The SDK has `liblzma.tbd` but **no `lzma.h`** (also no `archive.h`) → liblzma is not a supported API; rejected (it does link and work with borrowed headers — last-resort fallback only). (2) `COMPRESSION_LZMA` emits real `.xz` (magic `fd377a585a00`). Chunked + concatenated: 12.46 MB JSON → 579,364 B / 517 ms (4 MiB chunks) vs 602,032 B / 1,511 ms single-shot. (3) Multi-stream outputs: **Archive Utility** extracted both a 12-stream `.xz` and a 2-stream `.tar.xz` byte-identical; `xz -dc` decoded the `.xz` identical; bsdtar listed the `.tar.xz` (256 entries, same as the plain tar) — bsdtar cannot open a bare `.xz` at all. (4) A bsdtar-made tar of sample 12 (8,452,096 B, on disk) through the chunked encoder at 8 MiB chunks → 1,053,164 B (bsdtar's own `-J`: 1,051,052 B). The stdout-pipe variant (`tar -cf - …`) was only byte-counted (8,458,240 B), not run end to end. | Costs to accept: (i) xz integrity check is `None`, not CRC64 — our own verify pass covers write-time; (ii) output is multi-stream; (iii) `compression_stream` decode stops at each stream end, so the decoder **must re-init per stream while input remains**. AppleArchive was **not probed**; `.aar` numbers in codecs.md are unverified and unused. |

Other SDK facts checked: `glassEffect` (SwiftUICore swiftinterface), `GlassEffectContainer`, `NSGlassEffectView.h`, `SMAppService.mainApp` all present. `AVAssetReader` has `outputProvider…` in ObjC headers; the writer-side Swift spelling was not located — **use whichever compiles** (classic `copyNextSampleBuffer` / `requestMediaDataWhenReady` is acceptable).

### 2.1 Vendoring recipe (exact)

Sources (fetched 2026-11-19; GitHub tag archives):
- libdeflate **v1.26**, MIT — `https://github.com/ebiggers/libdeflate/archive/refs/tags/v1.26.tar.gz`, sha256 `bba03fffc5538576213675ce6968fcff6ce2e67d82e4d5febea2d05f9f13cf85`
- libjpeg-turbo **3.2.1**, IJG + BSD-3-Clause — `https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.2.1.tar.gz`, sha256 `6f5819c51649bce2571a23b1b0cd41eae2f57fc3f8908c7ec9e7047efb65ca13`

```
Vendor/libdeflate/        COPYING, libdeflate.h, common_defs.h, lib/** (unmodified, incl. arm/ x86/ riscv/)
                          include/libdeflate.h      ← one line:  #include "../libdeflate.h"
Vendor/libjpeg-turbo/     LICENSE.md, README.ijg
                          src/   ← upstream src/j*.c, src/j*.h, src/wrapper/**  (delete jcstest.c, jdatadst-tj.c, jdatasrc-tj.c)
                          src/jconfig.h, src/jconfigint.h, src/jversion.h   ← hand-written, below
                          ologn/ologn_jpeg.c, ologn/include/ologn_jpeg.h    ← our shim (only public header)
Vendor/README.md          versions, URLs, sha256, "SIMD disabled", list of local files
```
```swift
.target(name: "CLibDeflate", path: "Vendor/libdeflate", exclude: ["COPYING"], sources: ["lib"], publicHeadersPath: "include"),
.target(name: "CJPEGTurbo", path: "Vendor/libjpeg-turbo", exclude: ["LICENSE.md", "README.ijg"],
        sources: [/* the 101 files below */, "ologn/ologn_jpeg.c"], publicHeadersPath: "ologn/include",
        cSettings: [.headerSearchPath("src")]),
// OLogNKit: dependencies: ["CLibDeflate", "CJPEGTurbo"]
```
JPEG `sources` = upstream `set(JPEG_SOURCES …)` + the three arithmetic files; **list files explicitly** (the un-suffixed templates such as `src/jdcoefct.c` must not be compiled directly — only via `src/wrapper/<name>-<bits>.c`):
- Direct (`src/<name>.c`, 30): `jcapimin jchuff jcicc jcinit jclhuff jcmarker jcmaster jcomapi jcparam jcphuff jctrans jdapimin jdatadst jdatasrc jdhuff jdicc jdinput jdlhuff jdmarker jdmaster jdphuff jdtrans jerror jfdctflt jmemmgr jmemnobs jpeg_nbits jaricom jcarith jdarith`
- Wrappers `-8,-12,-16` (`src/wrapper/<name>-<bits>.c`, 15 names): `jcapistd jccolor jcdiffct jclossls jcmainct jcprepct jcsample jdapistd jdcolor jddiffct jdlossls jdmainct jdpostct jdsample jutils` — note `jutils` is easy to miss (link fails with `_jround_up`, `_jpeg_natural_order`).
- Wrappers `-8,-12` only (13 names): `jccoefct jcdctmgr jdcoefct jddctmgr jdmerge jfdctfst jfdctint jidctflt jidctfst jidctint jidctred jquant1 jquant2` (count check: 30 + 15×3 + 13×2 = 101).

```c
/* src/jconfig.h */
#define JPEG_LIB_VERSION 62
#define LIBJPEG_TURBO_VERSION 3.2.1
#define LIBJPEG_TURBO_VERSION_NUMBER 3002001
#define C_ARITH_CODING_SUPPORTED 1
#define D_ARITH_CODING_SUPPORTED 1
#define MEM_SRCDST_SUPPORTED 1
#ifndef BITS_IN_JSAMPLE
#define BITS_IN_JSAMPLE 8
#endif
/* src/jconfigint.h  (WITH_SIMD deliberately never defined) */
#define BUILD "ologn"
#define HIDDEN __attribute__((visibility("hidden")))
#undef inline
#define INLINE inline __attribute__((always_inline))
#define THREAD_LOCAL __thread
#define PACKAGE_NAME "libjpeg-turbo"
#define VERSION "3.2.1"
#define SIZEOF_SIZE_T 8
#define HAVE_BUILTIN_CTZL
#if defined(__has_attribute) && __has_attribute(fallthrough)
#define FALLTHROUGH __attribute__((fallthrough));
#else
#define FALLTHROUGH
#endif
#ifndef BITS_IN_JSAMPLE
#define BITS_IN_JSAMPLE 8
#endif
#undef C_ARITH_CODING_SUPPORTED
#undef D_ARITH_CODING_SUPPORTED
#undef WITH_SIMD
#if BITS_IN_JSAMPLE == 8
#define C_ARITH_CODING_SUPPORTED 1
#define D_ARITH_CODING_SUPPORTED 1
#define SIMD_ARCHITECTURE NONE
#endif
/* src/jversion.h = upstream jversion.h.in with @COPYRIGHT_YEAR@ → 1991-2026 */
```
Shim (C, because libjpeg errors use `setjmp/longjmp`, which Swift must never cross):
```c
/* progressive: 1 = progressive, 0 = sequential, -1 = keep source scan type.
   markers: 0 = none, 1 = ICC (APP2) only, 2 = all APPn + COM.  Returns 0 on success; *out is malloc'd (caller free()s). */
int ologn_jpeg_transcode(const uint8_t *in, size_t in_len, uint8_t **out, size_t *out_len,
                         int progressive, int markers, char err[200]);
/* 1 = same dimensions, components, sampling factors, quant tables and every DCT coefficient; 0 = differ; <0 = decode error. */
int ologn_jpeg_coefficients_equal(const uint8_t *a, size_t a_len, const uint8_t *b, size_t b_len, char err[200]);
```
Transcode sequence: `jpeg_std_error` + `error_exit` that copies the message and `longjmp`s → `jpeg_mem_src` → `jpeg_save_markers` (per `markers`) → `jpeg_read_header` → `jpeg_read_coefficients` → `jpeg_copy_critical_parameters` → `optimize_coding = TRUE` → `jpeg_simple_progression` if progressive → `jpeg_mem_dest` → `jpeg_write_coefficients` → re-emit saved markers (skip JFIF APP0 / Adobe APP14 the library already wrote) → finish/destroy both. `scripts/bundle.sh` must copy `Vendor/*/COPYING|LICENSE.md|README.ijg` into `Contents/Resources/Licenses/` (IJG and BSD require attribution in binaries).

## 3. Engine — `OLogNKit`

No UI imports. Imports allowed: Foundation, Compression, ImageIO, CoreGraphics, UniformTypeIdentifiers, AVFoundation, VideoToolbox, AudioToolbox, PDFKit, Quartz, Accelerate, CryptoKit, CLibDeflate, CJPEGTurbo.

### 3.1 Public API (exact; the app and CLI build against this)
```swift
public enum CompressionMode: String, Sendable, Codable, CaseIterable { case smart, lossless }
public enum QualityPreset: String, Sendable, Codable, CaseIterable { case compact, balanced, studio }
public enum ArchiveFormat: String, Sendable, Codable, CaseIterable { case xz, zip }          // xz ⇒ .xz / .tar.xz
public enum ImageConversion: String, Sendable, Codable, CaseIterable { case keep, heic, avif } // Smart mode only
public enum OutputLocation: Sendable, Codable, Hashable { case nextToOriginal, folder(URL) }
public enum FileKind: String, Sendable, Codable, CaseIterable { case png, jpeg, heic, pdf, video, audio, folder, generic }

public struct EngineSettings: Sendable, Codable, Equatable {
    public var quality: QualityPreset = .balanced
    public var archiveFormat: ArchiveFormat = .xz
    public var imageConversion: ImageConversion = .keep
    public var output: OutputLocation = .nextToOriginal
    public var suffix: String = "-min"
    public var stripMetadataInSmart: Bool = true
    public var preserveDates: Bool = true
    public var maxCPUJobs: Int? = nil            // nil ⇒ P-core count (sysctl hw.perflevel0.physicalcpu, fallback activeProcessorCount)
    public init() {}
}
public struct JobID: Hashable, Sendable, Codable { public let raw: UUID; public init() }
public struct JobRequest: Sendable, Equatable {
    public var source: URL; public var mode: CompressionMode; public var settings: EngineSettings; public var batchID: UUID?
    public init(source: URL, mode: CompressionMode, settings: EngineSettings, batchID: UUID? = nil)
}
public struct JobResult: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable { case compressed, alreadyOptimal }
    public let outcome: Outcome
    public let kind: FileKind
    public let method: String          // §3.4 label, e.g. "PNG · libdeflate 12"
    public let lossless: Bool          // true if the method actually used is content-exact (a Smart job may end lossless)
    public let verified: Bool          // lossless ⇒ always true; lossy ⇒ structural checks passed
    public let inputBytes: Int64
    public let outputBytes: Int64      // == inputBytes when alreadyOptimal
    public let outputURL: URL?         // nil when alreadyOptimal
    public let note: String?           // reason for alreadyOptimal, or caveat ("non-audio chunks dropped")
    public let duration: TimeInterval
    public var savedBytes: Int64 { get }; public var savedFraction: Double { get }   // 0…1
}
public enum JobError: Error, Sendable, Codable, Equatable {
    case unreadable(String), outputNotWritable(String), diskFull, verificationFailed(String), codec(String)
}
public enum JobState: Sendable, Equatable {
    case queued, running(fraction: Double), finished(JobResult), failed(JobError), cancelled
    public var isTerminal: Bool { get }
}
public struct Job: Identifiable, Sendable, Equatable {
    public let id: JobID; public let request: JobRequest; public let kind: FileKind
    public let inputBytes: Int64; public let createdAt: Date; public var state: JobState
}
public enum EngineEvent: Sendable { case added(Job), updated(Job), removed(JobID), paused(reason: String), resumed }

public actor CompressionEngine {
    public init()
    /// New subscription per call; first replays `.added` for every existing job. Progress `.updated` is coalesced to ≤ 15 Hz per job; fractions are monotonic.
    public nonisolated func events() -> AsyncStream<EngineEvent>
    /// One job per URL (a directory is one `.folder` job). Returns immediately; order preserved.
    @discardableResult public func submit(_ urls: [URL], mode: CompressionMode, settings: EngineSettings, batchID: UUID? = nil) -> [JobID]
    public func cancel(_ id: JobID)
    public func cancelAll()
    public func remove(_ id: JobID)                  // terminal jobs only; never touches files
    public func resume()                             // after `.paused` (disk full)
    public func jobs() -> [Job]
    public func waitUntilFinished(_ id: JobID) async -> Job   // returns the job in a terminal state
}
public enum Router {                                  // content first, extension second
    public static func kind(of url: URL) throws -> FileKind
}
public enum LosslessVerifier {                        // used by engine, tests, `ologn-cli verify`
    public static func verify(original: URL, output: URL) async throws   // throws JobError.verificationFailed
}
public enum PanelGeometry {                           // pure functions; lives here only so tests can reach it
    public static func trayFrame(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect
    public static func dropzoneFrame(screenFrame: CGRect, visibleFrame: CGRect, anchor: DropzoneAnchor) -> CGRect
}
public enum DropzoneAnchor: String, Sendable, Codable, CaseIterable { case topCenter, rightCenter, leftCenter }
```
Unsupported or unknown content never errors: it routes to `.generic`. `JobError.unreadable` is for missing/unreadable/corrupt input.

### 3.2 Internal structure
```swift
enum Lane { case cpu, wide, media }      // cpu: limit maxCPUJobs; wide: 1 (job is internally parallel); media: 2
struct CodecContext: Sendable {
    let input: URL; let inputBytes: Int64; let mode: CompressionMode; let settings: EngineSettings
    let scratch: URL                     // per-job temp dir on the destination volume
    let progress: @Sendable (Double) -> Void; let isCancelled: @Sendable () -> Bool
}
enum CodecOutcome: Sendable {
    case produced(temp: URL, ext: String, method: String, lossless: Bool, note: String?)   // already verified by the codec
    case skipped(reason: String)                                                           // → alreadyOptimal
}
protocol Codec: Sendable { var kind: FileKind { get }; var lane: Lane { get }
    func compress(_ ctx: CodecContext) async throws -> CodecOutcome }
```
- **Router**: read the first 64 bytes. `89 50 4E 47`→png; `FF D8 FF`→jpeg; `%PDF-`→pdf; ISO-BMFF `ftyp` brand: `heic heix hevc mif1 msf1`→heic, `M4A `→audio, any other brand→audio if `UTType(filenameExtension:)` conforms to `.audio`, otherwise video; `RIFF….WAVE`, `FORM….AIFF/AIFC`, `caff`, `fLaC`→audio; directory→folder; else extension via UTType (`.movie`→video, `.audio`→audio); else generic. Lanes: png/jpeg/heic/pdf/audio→cpu, generic/folder→wide, video→media.
- **Skip gate (generic only, < 2 ms)**: skip if magic or extension is a compressed container (`zip gz tgz xz txz zst br 7z aar rar bz2 dmg pkg xip`, plus `PK\x03\x04`, `1F 8B`, `FD 37 7A 58`, `28 B5 2F FD`, `7z\xBC\xAF`, `BZh`, `Rar!`), or if files ≥ 256 KiB have **all three** 64 KiB windows (offset 4096, middle, end) with Shannon entropy > 7.92 bits/byte **and** LZ4 (`COMPRESSION_LZ4`) ratio > 0.98. Media kinds use their own gates (§3.4).
- **Smart chain**: a Smart job tries the lossy method; if it is skipped or fails its quality/size gate, the codec runs the lossless method itself and reports `lossless: true`. Lossless jobs never run lossy code.
- **Concurrency**: `CompressionEngine` owns state; each job is a child `Task` that awaits its lane (FIFO async semaphore), then runs the codec. CPU-bound bodies run off the cooperative pool through one helper `offload { cancelToken in … }` (`DispatchQueue.global(qos: .userInitiated)` + continuation + `withTaskCancellationHandler`). Codecs poll `isCancelled` at least every ~100 ms of work (per PNG trial, per xz chunk, per video sample batch). `wide` jobs use `DispatchQueue.concurrentPerform` over chunks.
- **Failed lossless verification**: never ship the file. PNG retries once with reductions disabled (re-filter + re-deflate only); any other codec, or a second PNG failure, ends the job as `.failed(.verificationFailed(detail))` with no output. It is a bug signal, not `alreadyOptimal`.
- **Cancellation**: state → `.cancelled`, scratch dir removed, no output file, original untouched.
- **Disk full** (`ENOSPC` / `NSFileWriteOutOfSpaceError`): job → `.failed(.diskFull)`, engine stops starting new jobs and emits `.paused`; `resume()` restarts the queue.

### 3.3 Output writer (single code path for all codecs)
1. Destination dir = original's parent, or `settings.output` folder. Scratch = `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destinationDir, create: true)`; failure → `.outputNotWritable`.
2. Codec writes `scratch/<uuid>.<ext>` and returns it **after** verifying it.
3. Gate D20. If it fails: delete, `alreadyOptimal` (note = reason). A lossless job whose codec returns `produced` without having verified is a bug; the engine re-runs `LosslessVerifier` in debug builds.
4. Metadata on media outputs (not archives): POSIX permissions; creation + modification dates when `preserveDates`; xattrs `com.apple.metadata:_kMDItemUserTags`, `com.apple.metadata:kMDItemWhereFroms`, `com.apple.quarantine` if present.
5. Final name per D11; move with `renamex_np(src, dst, RENAME_EXCL)`; on `EEXIST` bump the counter and retry. Never `replaceItem`, never overwrite.
6. Remove scratch. The original is opened read-only throughout and is never modified, moved or deleted by the engine.

### 3.4 Codecs
Quality presets (compact / balanced / studio): SSIM threshold **0.970 / 0.980 / 0.990**; palette-PNG threshold **0.950 / 0.970 / 0.980**; video VT quality **0.55 / 0.65 / 0.75** (an output that is not smaller simply fails D20); AAC stereo **128 / 192 / 256 kbps** (mono: half); PDF **150 dpi q0.70 / 220 dpi q0.82 / 300 dpi q0.90**. `Metrics.ssim` = mean SSIM over 8×8 luma windows, step 4, full resolution (Accelerate); both images decoded by ImageIO into the same sRGB RGBA8 context with orientation applied. **Calibration is a Slice 1 step**: codecs.md's numbers come from a different SSIM implementation and samples 03 and 05 sit within ~0.005 of the balanced threshold, so adjust the balanced threshold (and shift the other two by the same amount) until `balanced` picks q 0.80 for sample 03 and q 0.88 for sample 05; record the final values in this file.

| Kind | Lossless method (label) | Smart method (label) | Skip rules | Verification |
|---|---|---|---|---|
| png | **Own byte-level pipeline, no ImageIO**: parse chunks → inflate IDAT (libdeflate) → unfilter → exact reductions (8-bit only, and only if no `tRNS/bKGD/sBIT/hIST`): opaque RGBA→RGB, ≤256 colours→palette+`tRNS` (no RGB→gray: it would orphan an RGB `iCCP`) → filter candidates {per-row min-sum-abs 0–4, all-None}; pick by a level-6 trial; final libdeflate **level 12** (level 9 if raw > 64 MiB) → one IDAT. Keep all ancillary chunks. `PNG · libdeflate 12` | Straight RGBA8 from the same decoder → Oklab median-cut 256 + 3 k-means passes + serpentine Floyd–Steinberg (0.7, off in flat regions) → indexed, filter None, level 12 (codecs §2b); strip text/time/EXIF chunks per D18. `PNG · palette 256`. If SSIM < threshold: `imageConversion ≠ keep` → ImageIO lossy search to HEIC/AVIF (`PNG → HEIC · q82`); else lossless pipeline. | APNG (`acTL`) or interlaced → skipped ("animated/interlaced PNG"). | Decode both with own decoder → canonical RGBA8/16 `memcmp`; **and** ImageIO-decoded pixels equal. |
| jpeg | Shim `transcode(progressive: -1, markers: 2)`. `JPEG · Huffman-optimised` | ImageIO encode from the decoded `CGImage` (orientation + ICC kept; all metadata kept if `stripMetadataInSmart == false` via `CGImageDestinationAddImageFromSource`), lowest q in `[0.50 0.60 0.65 0.70 0.75 0.80 0.85 0.88 0.92]` with SSIM ≥ threshold (binary search, ≤ 4 encodes), then shim `transcode(progressive: 1, markers: 2)`; re-check SSIM on the final bytes, else keep the sequential bytes. `JPEG · q80 + progressive`. If lossy is skipped or loses to it: shim `transcode(progressive: 1, markers: 2)` on the original with the same SSIM re-check (`JPEG · progressive`, reported **`lossless: false`** because it does not pass the ImageIO-pixel half of the verifier), else the lossless method. | Lossy skipped if bits/pixel < 1.35 or estimated quality ≤ 72 (luma DQT) or CMYK. Whole file skipped if it has an `MPF\0` APP2 marker (multi-picture / gain-map JPEG: a transcode would drop the second image; rule is from the format, **unprobed**). | `ologn_jpeg_coefficients_equal == 1` **and** ImageIO pixels equal. Never ImageIO pixels alone across scan types (D3). |
| heic | — (D6) | ImageIO same-format, same q search. Copy auxiliary data (HDR gain map, depth, mattes) with `CGImageSourceCopyAuxiliaryDataInfoAtIndex` → `CGImageDestinationAddAuxiliaryDataInfo` (**unprobed** — if it does not round-trip, such files are skipped). `HEIC · q88` | Image count > 1, or any auxiliary data that fails to copy → skipped. | Decodes; same pixel size and orientation; aux-data types equal. |
| pdf | — (D5) | `PDFDocument.write(to:withOptions:[PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])`, filter = `QuartzFilter(properties:)` below. `PDF · images 220 dpi q82` | Encrypted or locked → skipped. | Output opens; equal page count, `string.count`, total annotation count, outline child count, title; else reject → next fallback (R-b). |
| video | — (D6) | `AVAssetReader` → `AVAssetWriter`, HEVC (`hvc1`), `kVTCompressionPropertyKey_Quality` = preset and **no bitrate target** (codecs.md measured Quality alone: 0.65 → 56.8 % on sample 07; its Quality + `AverageBitRate` cap was a recommendation, never measured, and could dominate the result); same dimensions, frame timing, `preferredTransform`, colour properties; 10-bit source → Main10; audio tracks passthrough; asset metadata copied; same container extension. `HEVC · q0.65` | Bits per pixel per frame < 0.045 (HEVC/AV1) or < 0.065 (H.264); tracks other than video + audio (subtitles, timecode, alpha) → skipped; not readable by AVFoundation → generic. | Playable; duration within 0.1 s; same dimensions and audio track count. |
| audio | `ExtAudioFile` → FLAC (omit `AVLinearPCMBitDepthKey`, use `AVEncoderBitDepthHintKey`; codecs §2g). `FLAC`, note "non-audio chunks dropped" | PCM or lossless source → AAC-LC `.m4a`. `AAC 192k` | D7. | Lossless: decode both to interleaved Int32 PCM, equal frame count and SHA-256. Smart: duration within 0.05 s, same channel count and sample rate. |
| generic | `XZ.encode`: 4 MiB chunks, `compression_encode_buffer(COMPRESSION_LZMA)` in parallel, streams concatenated in order, written incrementally (memory ≤ lane width × chunk). `xz (LZMA2)`. With `.zip`: `/usr/bin/ditto -c -k --norsrc --noextattr --noqtn <file> <zip>` (`zip`). | same | Skip gate §3.2. | xz: streaming decode (re-init per stream) → SHA-256 equals input's. zip: `/usr/bin/unzip -tq` exits 0. |
| folder | `/usr/bin/tar -cf - --no-mac-metadata --exclude .DS_Store -C <parent> <name>` → stdout pipe → `XZ.encode`, SHA-256 of the tar stream taken on the way in. `tar.xz`. With `.zip`: `ditto -c -k --norsrc --noextattr --noqtn --keepParent`. `inputBytes` = sum of regular-file sizes. Progress = tar bytes consumed / `inputBytes`, capped at 0.99. | same | Empty folder → skipped. | xz layer: decode → SHA-256 equals the tar stream's. zip: `unzip -tq`. tar exit status must be 0. |

QuartzFilter properties (balanced; substitute dpi and quality per preset):
```swift
["Domains": ["Applications": true, "Printing": true], "FilterType": 1, "Name": "o-log-n",
 "FilterData": ["ColorSettings": ["ImageSettings": ["ImageCompression": "ImageJPEGCompress", "Compression Quality": 0.82,
   "ImageScaleSettings": ["ImageResolution": 220, "ImageScaleInterpolate": true, "ImageSizeMax": 3200, "ImageSizeMin": 0]]]]]
```
Subprocess rules (`tar`, `ditto`, `unzip`): absolute paths, argument arrays (no shell), `terminate()` on cancel, non-zero exit → `JobError.codec(stderr tail)`.

## 4. App — `OLogNApp`

AppKit shell + SwiftUI content. `NSApp.setActivationPolicy(.accessory)`; never call `NSApp.activate` except for `NSOpenPanel`. `main.swift` creates `AppDelegate` (`@MainActor`), which owns everything below.

### 4.1 Shell objects
| Object | Spec |
|---|---|
| `StatusItemController` | `NSStatusItem(variableLength)`, template image. Left click → toggle tray; right / ⌃-click → `NSMenu` per ux §2.1 with "o-log-n" naming. Progress arc and drop-on-status-item are Slice 3. |
| `TrayPanel: NSPanel` | `[.borderless, .nonactivatingPanel]`, `canBecomeKey = true`, `canBecomeMain = false`, `isFloatingPanel = true`, `becomesKeyOnlyIfNeeded = true`, `hidesOnDeactivate = false`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true`, `level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)` (= 22; main menu is 24), `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`. Summon: set frame → `makeKeyAndOrderFront(nil)` (no app activation). Dismiss: `orderOut` after the close animation. The panel frame never animates; the SwiftUI content animates offset/opacity inside it. |
| `DropzonePanel: NSPanel` | Same mask and flags, but `canBecomeKey = false`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]` (deliberately not over fullscreen Spaces), fixed 304×96 frame. Content view is `DropHostingView: NSHostingView` that (a) returns `nil` from `hitTest` outside the current pill rect (click-through), (b) is the `NSDraggingDestination` (`registerForDraggedTypes([.fileURL])`): half from pointer x, flipped when `NSEvent.modifierFlags.contains(.option)`, ⇧ opens the tray; URLs via `readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])`. |

### 4.2 Geometry (`PanelGeometry`, unit-tested)
`screen` = the `NSScreen` whose `frame` contains `NSEvent.mouseLocation`, else `NSScreen.screens[0]`. `F = screen.frame`, `V = screen.visibleFrame`.
- **Tray**: `h = round(min(max(F.height × 0.255, 248), 360))`; `w = min(V.width − 24, 1360)`; `x = round(V.midX − w/2)`; `y = F.minY + 12`. Uses `frame` vertically (covers the Dock), `visibleFrame` horizontally (respects a side Dock). Example, this Mac (`F` 1800×1169, `V` y=65 h=1065): `(220, 12, 1360, 298)`.
- **Dropzone** (panel 304×96, pill aligned to the anchored edge with a 6 pt inset): `topCenter`: `x = round(F.midX − 152)`, `y = V.maxY − 4 − 96`. `rightCenter`: `x = V.maxX − 4 − 304`, `y = round(V.midY − 48)`. `leftCenter`: `x = V.minX + 4`, same y. `always` presence uses `AppSettings.anchor` (default `rightCenter`) on the primary display (`NSScreen.screens[0]`, not `NSScreen.main`); `onDrag` presence always uses `topCenter` on the cursor's screen.

### 4.3 State
```swift
struct AppSettings: Codable, Equatable {          // UserDefaults key "settings.v1" (JSON)
    var engine = EngineSettings(); var defaultMode = CompressionMode.smart
    var presence = DropzonePresence.always; var anchor = DropzoneAnchor.rightCenter
    var hotkeyKeyCode: UInt32 = 49 /* kVK_Space */; var hotkeyModifiers: UInt32 = 0x1800 /* controlKey | optionKey */
    var launchAtLogin = false; var haptics = true; var sound = false; var historyDays = 7
}
enum DropzonePresence: String, Codable, CaseIterable { case always, onDrag, off }
@MainActor @Observable final class JobStore {     // the only bridge to the engine
    private(set) var items: [JobItem]              // newest first; JobItem = Job + batchID + replaced flag + trashedURL
    private(set) var active: Int; private(set) var savedBytesSession: Int64; private(set) var pausedReason: String?
    func submit(_ urls: [URL], mode: CompressionMode)          // one batchID per call
    func cancel(_ id: JobID); func cancelAll(); func remove(_ id: JobID); func clearFinished(); func retry(_ id: JobID)
    func replaceOriginal(_ id: JobID) throws; func undoLastReplace() throws
}
```
`JobStore` runs one `Task` over `engine.events()` and mutates `items` on the main actor. Views read the store; nothing else in the app touches `CompressionEngine`. Settings changes apply to jobs submitted afterwards.

### 4.4 Services
- **DragMonitor**: global monitor `[.leftMouseDown, .leftMouseDragged, .leftMouseUp]`. On down: record location and `NSPasteboard(name: .drag).changeCount`. On dragged, once displacement ≥ 24 pt, re-check at most every 50 ms until it fires: `changeCount` changed **and** `types` contains `.fileURL` **and** not `app.ologn.mac.self-drag` → `onFileDragBegan`. On up → `onDragEnded` after 150 ms. Never reads pasteboard contents. Runs in `always` and `onDrag` presence.
- **HotkeyService** (`@MainActor final class`, Carbon): `InstallEventHandler(GetEventDispatcherTarget(), handler, 1, &spec /* kEventClassKeyboard, kEventHotKeyPressed */, nil, &handlerRef)` with a **non-capturing** closure that calls `MainActor.assumeIsolated { HotkeyService.shared.fire() }` and returns `noErr`; then `RegisterEventHotKey(keyCode, mods, EventHotKeyID(signature: 0x4F4C474E, id: 1), GetEventDispatcherTarget(), 0, &ref)`. Non-zero status → surface "Shortcut unavailable" in Settings. Re-register on settings change.
- **Tray keyboard**: one `NSEvent.addLocalMonitorForEvents(.keyDown)` installed while the tray is open implements ux §5.2; if `panel.firstResponder is NSTextView`, pass the event through. Do not rely on SwiftUI `.keyboardShortcut` in a non-active app.
- **Click-outside**: global `[.leftMouseDown, .rightMouseDown]` monitor closes the tray (suspended while `NSOpenPanel` / Quick Look is up); also close on `windowDidResignKey`.
- **Replace / undo** (in `JobStore`): `FileManager.trashItem(at: original, resultingItemURL: &trashed)`, then move the output to the original's path (same extension) or `<stem>.<outExt>` in the same folder (extension changed; uniquify, never overwrite). Archives: original to Trash, archive keeps its name. Undo stack is in-memory for the session: move the output back to its suffixed name, move `trashed` back; if `trashed` is gone → inline "Original no longer in Trash".
- **Quick Look**: `QLPreviewPanel.shared()` with `TrayPanel` implementing `acceptsPreviewPanelControl / beginPreviewPanelControl / endPreviewPanelControl`. Live check L6.
- **Launch at login**: `SMAppService.mainApp.register()` / `unregister()`; show `status` errors inline. Live check L7 (ad-hoc signature may be refused).
- **Glass**: ux §2.5 `AdaptiveGlassSurface` (`.glassEffect` / Reduce-Transparency fallback). History: `~/Library/Application Support/o-log-n/history.json` (finished `JobItem`s, pruned by `historyDays` and by missing output files).
- **`--selftest`**: `OLogN --selftest` builds both panels on the primary display without showing them, registers and unregisters the hotkey, installs and removes the drag monitor, compresses a generated 1 MiB text file through `JobStore`, prints one JSON line `{"trayFrame":[x,y,w,h],"dropzoneFrame":[…],"hotkeyStatus":0,"dragMonitor":true,"job":"compressed"}` and exits 0 (non-zero on any failure).

## 5. CLI — `ologn-cli`

No third-party argument parser.
```
ologn-cli compress <paths…> [--mode smart|lossless] [--quality compact|balanced|studio] [--archive xz|zip]
                            [--convert keep|heic|avif] [--out <dir>] [--suffix <s>] [--jobs <n>] [--json]
ologn-cli verify <original> <output>     # LosslessVerifier; exit 0 = content-identical, 1 = not, 2 = usage / unsupported pair
ologn-cli kind <path>                    # prints the Router kind
```
`compress` defaults: `--mode smart`. Exit 0 if no job failed, 1 if any failed, 2 on usage error. Human output: one line per job (`name  12.4 MB → 0.6 MB  −95.4%  xz (LZMA2)  0.52s`). `--json`: a single JSON array on stdout, one object per input in argument order:
```json
{"input": "/abs/in.png", "output": "/abs/in-min.png", "kind": "png", "mode": "lossless", "outcome": "compressed",
 "method": "PNG · libdeflate 12", "lossless": true, "verified": true, "inputBytes": 1467040, "outputBytes": 957975,
 "savedPercent": 34.70, "durationMs": 2350, "note": null, "error": null}
```
`outcome` ∈ `compressed | alreadyOptimal | failed | cancelled`; `output` is `null` unless `compressed`.

## 6. Slices and acceptance

`S` = `<scratch>/bench/samples` (orchestrator checks only; **tests never reference it**). Run CLI checks with `--out "$(mktemp -d)" --json`.

### Slice 1 — engine + CLI + tests + vendored libs
Create: `Vendor/**` (§2.1); `Package.swift` (two C targets, Kit deps); `Sources/OLogNKit/`: `Model.swift`, `EngineSettings.swift`, `CompressionEngine.swift`, `Lanes.swift`, `Offload.swift`, `Router.swift`, `SkipGate.swift`, `OutputWriter.swift`, `LosslessVerifier.swift`, `PanelGeometry.swift`, `Metrics/SSIM.swift`, `Codecs/{PNGFormat,PNGCodec,PaletteQuantizer,JPEGCodec,ImageIOLossy,HEICCodec,PDFCodec,VideoCodec,AudioCodec,XZ,GenericCodec,FolderCodec}.swift`; `Sources/ologn-cli/main.swift`; `Tests/OLogNKitTests/{Fixtures,PNG,JPEG,Audio,Generic,Folder,PDF,Video,Router,OutputWriter,Engine,Geometry}Tests.swift`; update `scripts/bundle.sh` (licenses).

Checks:
1. `swift build -c release` and `swift test` exit 0 with no warnings from our Swift targets; `scripts/bundle.sh` still succeeds.
2. Tests generate fixtures in a temp dir (PNG/JPEG via ImageIO, WAV by writing a PCM header, text, random bytes, a small folder, a PDF with an embedded noise image via `CGPDFContext`, a 1 s 640×360 H.264 clip via `AVAssetWriter`) and assert **invariants, not ratios**: lossless outputs pass `LosslessVerifier`; output < input; original's SHA-256 unchanged; running twice yields `-min` then `-min-2` and overwrites nothing; random bytes → `alreadyOptimal` with no file created; cancelling mid-job leaves no output and no scratch dir; multi-stream xz decodes to the input; Router classifies every fixture; `PanelGeometry.trayFrame(F: 0,0,1800,1169; V: 0,65,1800,1065) == (220,12,1360,298)`; progress fractions are monotonic and end in a terminal state.
3. CLI on samples — `outcome`, output extension, `savedPercent` range. Ranges marked ✓ are from numbers I reproduced; the rest are from codecs.md with slack.

| Input | `--mode lossless` | `--mode smart` |
|---|---|---|
| `01_screenshot_ui.png` | `.png` 28–38 %, < 6 s | `.png` 65–85 % (`lossless: false`) |
| `02_photo.png` | `.png` 20–30 % | `.png` 20–30 % with `lossless: true` (palette rejected by SSIM); with `--convert heic`: `.heic` ≥ 80 % |
| `03_camera_q92.jpg` | `.jpg` 1.0–2.5 % ✓ (1.66 %) | `.jpg` 15–55 % |
| `04_lowq_q55.jpg` | `.jpg` 0.6–2.0 % ✓ (1.11 %) | `.jpg` 0.6–6 % (lossy skipped by gate) |
| `05_photo_heic.heic` | `alreadyOptimal` | `.heic` 15–60 % |
| `06_document_with_images.pdf` | `alreadyOptimal` | `.pdf` 85–97 % ✓ (93.4 %) |
| `07_video_1080p_15s.mp4` | `alreadyOptimal` | `.mp4` 40–75 %, < 8 s |
| `08_natural_clip.mov`, `09_video_already_compressed.mp4` | `alreadyOptimal` | `alreadyOptimal`, each < 1 s |
| `10_audio_stereo.wav` | `.flac` 45–55 % | `.m4a` 80–93 % |
| `11_server_logs.json` | `.json.xz` 94–97 % ✓ (95.4 %), < 2 s | same |
| `12_source_folder` | `.tar.xz` 84–89 % ✓ (86.8 %); `--archive zip`: `.zip` 78–83 % ✓ | same |
| `13_already_compressed.zip` | `alreadyOptimal`, < 0.5 s | same |

4. Round-trips by command: `ologn-cli verify` exits 0 for the lossless outputs of 01, 02, 03, 04, 10, 11. `/usr/bin/tar -xf out.tar.xz -C $T && diff -r $T/12_source_folder $S/12_source_folder` is empty. `ologn-cli verify $S/03_camera_q92.jpg <smart output>` exits 1. No file under `$S` is created, modified or removed (compare `find $S -type f | xargs shasum` before and after).

### Slice 2 — app shell, dropzone, tray wired to the engine
Create under `Sources/OLogNApp/`: `main.swift`, `AppDelegate.swift`, `AppSettings.swift`, `JobStore.swift`, `StatusItemController.swift`, `Panels/{TrayPanel,DropzonePanel,DropHostingView,PanelCoordinator}.swift`, `Services/{DragMonitor,HotkeyService,ReplaceService}.swift`, `Views/{TrayView,ControlBar,IntakeWell,JobCard,DropzoneView,Glass,Tokens}.swift`. Scope: every state in ux §3 rendered with correct copy and static layout; drop on either half; ⌥ flip; tray via hotkey and status item; job cards with live progress; Reveal, Copy, Replace + ⌘Z, Cancel/Remove; ⌘V / ⌘O intake; click-outside and Esc dismiss. Springs may be default animations.

Checks: `swift build -c release`; `scripts/bundle.sh` prints `build/o-log-n.app`; `codesign -v build/o-log-n.app` exits 0; `build/o-log-n.app/Contents/MacOS/OLogN --selftest` exits 0 with `hotkeyStatus: 0`, `job: "compressed"`, and `trayFrame` equal to `PanelGeometry` for the primary display; `open build/o-log-n.app && sleep 2 && pgrep -x OLogN` succeeds, then `pkill -x OLogN` (`--selftest` requires that no other instance is running, or the hotkey is taken); `plutil -extract LSUIElement raw build/o-log-n.app/Contents/Info.plist` prints `true`. Live checklist (implementer runs and reports each as pass/fail in the PR notes):
- **L1** With Accessibility *not* granted to o-log-n, dragging a Finder file expands the puck; dragging text or a window does not.
- **L2** ⌃⌥Space toggles the tray from another app, including over a fullscreen Space.
- **L3** With the tray open, ↑/↓/Esc/⌘V work while the previous app stays frontmost and undimmed.
- **L4** Drop on left half → Smart job; right half → Lossless; ⌥ flips; clicks 2 pt outside the pill reach the window below.
- **L5** Replace Original moves the original to Trash; ⌘Z restores both files.

### Slice 3 — polish
Create: `Services/{QuickLook,LoginItem,Haptics,HistoryStore}.swift`, `Views/{SettingsDeck,BatchHeader,UndoToast}.swift`; edit views for motion. Scope: ux §4 springs, tickers at 15 Hz, haptics; inline Settings deck bound to `AppSettings` (all rows of ux §2.3 Zone C that map to a field in §4.3; unmapped rows are omitted); history persistence; status-item progress arc and drop target; batch header; disk-full banner; Quick Look; launch at login; VoiceOver labels and custom actions (ux §6); Reduce Motion / Reduce Transparency / Increase Contrast paths.

Checks: Slice 1 and 2 checks still pass. From Slice 3 on, `--selftest` also persists its job to history and round-trips `AppSettings` through UserDefaults, so after running it: `~/Library/Application Support/o-log-n/history.json` parses as JSON with ≥ 1 entry and `defaults read app.ologn.mac settings.v1` succeeds. Live: **L6** Space previews the selected output; **L7** launch-at-login toggle registers (or shows the system error inline); **L8** with Reduce Motion on, no slide or scale occurs; with Reduce Transparency on, no glass is drawn; VoiceOver reads a job card per ux §6.1.

## 7. Out of scope for v1
Per-file optimisation inside folders; `.aar`; lossless PDF, HEIC and video paths; dedicated WebP/AVIF/TIFF/BMP/GIF/RAW/SVG handling (they route to generic); WebP output; file promises (drags that carry no file URL, e.g. some Mail/browser drags); clipboard bitmap intake beyond file URLs and PNG/TIFF data; NEON/SIMD in libjpeg-turbo; CRC64-checked or single-stream xz; App Sandbox / App Store build; notarisation; custom hotkey recorder UI beyond the default plus reset; sound effects; per-display dropzone positions and the ultrawide centring rule; localisation.

## 8. Open questions for the user
All four were answered on 2026-11-19 — see §10, which overrides the earlier defaults.

## 9. Implementation notes (Slice 1)

### SSIM calibration

The balanced threshold already selected the required rungs, so the three SSIM thresholds were not shifted. Palette thresholds are a separate scale and were left where §3.4 set them.

| Preset | SSIM | Palette SSIM |
|---|---|---|
| compact | 0.970 | 0.950 |
| balanced | 0.980 | 0.970 |
| studio | 0.990 | 0.980 |

Measured balanced picks on the release CLI (binary search, at most 4 encodes, the ladder in §3.4). A rung is "measured" by which way the search stepped:

- Sample 03 `03_camera_q92.jpg`: **q 0.80**. Method `JPEG · q80 + progressive`, 23.68% saved (1,107,198 bytes). q 0.75 scored under 0.980; q 0.80 met it. The progressive transcode of that encode also met 0.980, so the shipped bytes are progressive.
- Sample 05 `05_photo_heic.heic`: **q 0.88**. Method `HEIC · q88`, 23.09% saved (1,099,017 bytes). q 0.85 scored under 0.980; q 0.88 met it.

Sample 04's lossy ladder is skipped by the quality gate (estimated quality ≤ 72). Smart then keeps the progressive coefficient copy, `JPEG · progressive`, `lossless: false`, 4.34% saved, inside the 0.6–6% band in §6.

### Deviations

- Folder tar is written to a file in the scratch directory and then xz-compressed. §3.4 says stdout pipe. An unread pipe stalls `tar`, and the file is the byte stream whose SHA-256 the verifier recomputes with the same `tar` arguments. The xz layer is still concatenated 4 MiB `COMPRESSION_LZMA` streams with integrity check None.
- Sample 09 is HEVC `hev1` and `AVURLAsset.isPlayable` is false while `isReadable` is true. The video codec uses `isReadable`, which is the §3.4 rule "not readable by AVFoundation → generic". The bpp gate then returns `alreadyOptimal`. Treating "not playable" as generic produced a 3.32% `.xz` and missed the §6 row.

### Known gaps

- The libjpeg shim's `setjmp` locals are not `volatile`. That matters only on the error return, which copies the message out before `longjmp`.
- Vendored libjpeg-turbo and libdeflate still warn `-Wshorten-64-to-32`. Swift targets are built `-warnings-as-errors` and are clean. `WITH_SIMD` stays undefined, per §2.1.
- `UTType.avif` is not a member on this SDK. `--convert avif` uses `UTType(filenameExtension: "avif")` and falls back to HEIC only if that lookup fails. No sample is AVIF.
- Slice 2 (the app UI) is unchanged apart from the scaffold that already imported the kit.

### Orchestrator fixes after Slice 1
- Test fixtures blocked a cooperative thread (`DispatchSemaphore` around `AVAssetWriter.finishWriting`). Under parallel Swift Testing this starved the pool and deadlocked the suite. `Fixtures.make()` is now `async` and uses `await writer.finishWriting()`. **Rule for all slices: never block a Swift-concurrency thread.** That covers semaphores, `Thread.sleep`, `waitUntilExit` and `group.wait` outside `Offload.run`.

- **Fix round 1** (all 20 Slice 1 review findings) was merged from an isolated copy. Details: `docs/review/slice1-findings.md` and `docs/review/slice1-fixes.md`.
- **Lost wakeup in pause/resume, found by the orchestrator.** A job that saw `paused` right after acquiring its lane released the lane (an `await`) *before* clearing `tasks[id]`. A `resume()` that ran during that suspension skipped it, which stranded the job in `.queued`. It now parks (`tasks[id] = nil`) before the release. Separately, `diskFullPauseHoldsTheNextWaiterUntilResume` assumed `ids[0]` won the lane first; it now finds whichever job failed. The suite passed 30/30 consecutive parallel runs after the fix (previously about 1 in 6 hung).

### Ship-readiness review (Fable 5.2, 2026-11-20), fixed by the orchestrator
- **Memory grew with input on xz paths.** Measured before the fix: 1.95 GB peak footprint for a 0.84 GB file, and 3.3 GB for a 1.3 GB folder. Cause: the per-chunk `FileHandle` reads and writes in `XZ.encodeChunks`, `FileHash.sha256` and the decode sink never drained their autoreleased data. Fix: one `autoreleasepool` per batch or chunk. Measured after: peak footprint is **flat at about 786 MB** for 0.25 GB, 1.05 GB and 2.1 GB files and for a 3.2 GB folder. That bound is about 12 concurrent LZMA encoders; lowering the `XZ` batch width would trade speed for a lower bound. Max RSS still grows on large outputs only because `decodeHash` memory-maps the output file, and those pages are clean and reclaimable.
- **A folder whose name starts with `-` was parsed by tar as options.** The codec and the verifier's re-tar now pass `--` before the name. Covered by the test `folderNamedLikeAnOptionArchivesAndVerifies`; a 3.2 GB `-rf folder` round-trips identically.
- **Child tools outlived quit and ⌃C.** `ChildProcesses` (public) tracks the PIDs spawned by `Command.run`. The app calls `terminateAll()` in `applicationWillTerminate`, and the CLI does the same on SIGINT/SIGTERM (exit 130/143). Verified: after ⌃C, `ditto` is gone and no partial output remains.
- **Selftests leaked a temp app-support directory and a `UserDefaults` suite plist** on every run. The suite is now an absolute path inside the temp directory, because cfprefsd re-created a deleted `~/Library/Preferences` plist. Both are removed at exit through `SelfTestIsolation.cleanUpAtExit()`, which is registered from a nonisolated context; a closure formed in a `@MainActor` method trapped when `exit()` ran it off-main. Some `ologn-history-*`/`ologn-support-*` temp directories still leak per run, in `$TMPDIR` only.
- **xz throughput is linear at about 20 MB/s** on high-entropy text (0.53 / 1.05 / 2.1 GB → 25 / 51 / 105 s). The encoder keeps only about 4.5 of 12 cores busy, because read → compress batch → write is serial. Pipelining it is about a 2× opportunity.
- **Still open** (documented, not blockers): folder archives omit xattrs, resource forks and `.DS_Store` even though they are labelled lossless (file content and tree are exact); the scratch directory is left behind whenever the app quits or the CLI is interrupted mid-job (children are stopped, but in-flight scratch, e.g. a folder-sized `payload.tar`, is not removed); error text for read-only sources is raw errno; the collision suffix for archives lands as `name.ext-2.xz`.

### Final review (Astra pass 4) and last round, 2026-11-20
All 12 findings in `docs/review/final-findings.md` are fixed. Details are in `docs/review/final-fixes.md` and in the orchestrator section of `final-findings.md`.
- `JobResult.outputFingerprint` is stamped right after publish. Every file action checks the engine's stamp; destructive actions check it again on the file queue just before acting.
- Folder Replace is disabled in v1.
- Every selftest is isolated before it runs any scenario.
- The demo writes nothing.
- The CLI unwinds on ⌃C.
- The child-process registry owns its children.
- tar is given `./` for `-`/`@` names.

The orchestrator verified:
- 43 tests pass, 5 out of 5 runs.
- All selftests pass, except `--selftest-keys` scenario 2 and the Quick Look generation scenario, which need an unlocked screen.
- The tray opens in 63.5 ms.
- The real `history.json` and `app.ologn.mac` defaults are byte-identical across all runs.
- The signed hardened-runtime DMG verifies.

Known gap: `discard` checks the stamp and then trashes the file, so a process can still swap the inode in that window. **Review status:** Astra's pass-4 verdict was "Beta-ready: no" and Fable's ship-readiness verdict was "not yet". Their findings are fixed. Astra's verification-only pass 6 confirmed the Replace/Undo/Trash and selftest-isolation fixes ("Replace/Trash safe to use: yes"), but there has been no new full review since.

## 10. User decisions (2026-11-19). These override §1 where they differ.
| # | Decision | Effect |
|---|---|---|
| U1 | **Display name is `Logn`.** | User-facing strings, `CFBundleName`/`CFBundleDisplayName`, the bundle file `build/Logn.app`, menu items (`Quit Logn`), Application Support folder `~/Library/Application Support/Logn/`, and the QuartzFilter `Name`. **Unchanged internal identifiers:** module names (`OLogNKit`, `OLogNApp`), `ologn-cli`, bundle id `app.ologn.mac`, executable `Contents/MacOS/OLogN`, self-drag type `app.ologn.mac.self-drag`, UserDefaults key `settings.v1`. Replaces D14. |
| U2 | **Archive format is a user option** (already `EngineSettings.archiveFormat`). | Default stays `.xz` / `.tar.xz`; `.zip` is selectable in the tray's control bar and Settings deck, labelled `Smallest (.tar.xz)` / `Opens everywhere (.zip)`. Confirms D9. |
| U3 | **Lossless JPEG offers both styles.** | Implemented by the orchestrator: `EngineSettings.jpegLossless: JPEGLosslessStyle` with values `.pixelExact` (default; D3 behaviour, `JPEG · Huffman-optimised`) and `.progressive` (`JPEG · progressive (DCT-exact)`, `lossless: true`, with a note). The CLI flag is `--jpeg-lossless pixelExact\|progressive`. `LosslessVerifier` always requires coefficient equality, and requires ImageIO pixel equality only when both files have the same scan type. Measured: sample 03 saves 8.2% and 04 saves 4.3%, with `djpeg` output identical. The Settings deck gets the row `Lossless JPEG: [Identical pixels · 1–2%] [Progressive · 4–10%]`. Answers Q3. |
| U4 | **The dropzone appears only while dragging.** | `AppSettings.presence` defaults to `.onDrag`: the ux.md top-centre split capsule, summoned by `DragMonitor` on the cursor's screen. `.always` (the D13 puck, anchor `rightCenter`) and `.off` remain settings. Because `.onDrag` depends on global drag detection (R-a / L1), the **status item must also accept file drops** (in Slice 2, not Slice 3) as a guaranteed fallback. If L1 fails without Accessibility permission, Slice 2 must report it, and the app must fall back to `.always` at runtime with an inline note in Settings. Replaces D13. |

