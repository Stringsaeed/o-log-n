import AppKit
import CoreGraphics
import Foundation
import OLogNKit

/// In-memory fixtures for `--demo`. Thumbnails are CGImages drawn at launch and stored in
/// `DemoThumbnails`. No file is created. The simulated service layer never writes either.
enum Demo {
    struct Media {
        var queued: URL
        var running: URL
        var compressedSource: URL
        var compressedOutput: URL
        var optimal: URL
        var failed: URL
        var cancelled: URL
        var replaced: URL
    }

    struct Fixture {
        var items: [JobItem]
        var saved: Int64
        var toast: String
        var previewURL: URL?
        var doneHeadline: String
        var doneSubline: String
    }

    /// Draws one thumbnail per card into `DemoThumbnails`. The URLs name the pictures.
    /// They are not paths this function creates.
    @MainActor
    static func prepareMedia() -> Media {
        let queued = memoryURL("Harbor.png")
        let running = memoryURL("Coast.mov")
        let source = memoryURL("Pink.png")
        let output = memoryURL("Pink.heic")
        let optimal = memoryURL("Installer.dmg")
        let failed = memoryURL("Protected.pdf")
        let cancelled = memoryURL("Notes.txt")
        let replaced = memoryURL("Scan.heic")
        remember(raster(red: 0.20, green: 0.45, blue: 0.72), queued)
        remember(raster(red: 0.12, green: 0.35, blue: 0.55), running)
        remember(raster(red: 0.93, green: 0.45, blue: 0.55), source)
        remember(raster(red: 0.93, green: 0.45, blue: 0.55), output)
        remember(raster(red: 0.45, green: 0.48, blue: 0.52), optimal)
        remember(raster(red: 0.96, green: 0.94, blue: 0.90), failed)
        remember(raster(red: 0.75, green: 0.72, blue: 0.64), cancelled)
        remember(raster(red: 0.55, green: 0.35, blue: 0.62), replaced)
        return Media(
            queued: queued,
            running: running,
            compressedSource: source,
            compressedOutput: output,
            optimal: optimal,
            failed: failed,
            cancelled: cancelled,
            replaced: replaced)
    }

    private static func memoryURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/ologn-demo/\(name)", isDirectory: false)
    }

    @MainActor
    private static func remember(_ image: NSImage?, _ url: URL) {
        guard let image else { return }
        DemoThumbnails.store(image, for: url)
    }

    /// The path `--demo` and the history selftest both use. Thumbnails stay in memory.
    @MainActor
    static func installPopulatedPreview(into store: JobStore, paused: String? = nil) -> Fixture {
        let built = makeFixture(prepareMedia())
        store.installPreview(built.items, sessionSaved: built.saved, toast: built.toast, paused: paused)
        return built
    }

    static func makeFixture(_ media: Media) -> Fixture {
        let batch = UUID()
        let now = Date()
        let stamp = SourceFingerprint(
            size: 8_400_000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000.123456),
            fileID: 42)
        let outputStamp = SourceFingerprint(
            size: 3_020_000,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_001.654321),
            fileID: 43)

        let queued = item(
            url: media.queued,
            kind: .png,
            bytes: 4_200_000,
            state: .queued,
            batch: batch,
            createdAt: now)

        let running = item(
            url: media.running,
            kind: .video,
            bytes: 84_000_000,
            state: .running(fraction: 0.40),
            batch: batch,
            createdAt: now.addingTimeInterval(-2))

        let compressedResult = JobResult(
            outcome: .compressed,
            kind: .heic,
            method: "q80",
            lossless: false,
            verified: true,
            inputBytes: 8_400_000,
            outputBytes: 3_020_000,
            outputURL: media.compressedOutput,
            note: nil,
            duration: 0.42,
            sourceFingerprint: stamp,
            outputFingerprint: outputStamp)
        var compressed = item(
            url: media.compressedSource,
            kind: .heic,
            bytes: 8_400_000,
            state: .finished(compressedResult),
            batch: batch,
            createdAt: now.addingTimeInterval(-8))
        compressed.outputFingerprint = outputStamp
        compressed.pin = .pinned(media.compressedOutput)

        let optimalResult = JobResult(
            outcome: .alreadyOptimal,
            kind: .generic,
            method: "",
            lossless: true,
            verified: true,
            inputBytes: 1_840_000,
            outputBytes: 1_840_000,
            outputURL: nil,
            note: nil,
            duration: 0.08)
        let optimal = item(
            url: media.optimal,
            kind: .generic,
            bytes: 1_840_000,
            state: .finished(optimalResult),
            batch: nil,
            createdAt: now.addingTimeInterval(-40))

        let failed = item(
            url: media.failed,
            kind: .pdf,
            bytes: 512_000,
            state: .failed(.outputNotWritable("No write permission")),
            batch: nil,
            createdAt: now.addingTimeInterval(-50))

        let cancelled = item(
            url: media.cancelled,
            kind: .generic,
            bytes: 24_000,
            state: .cancelled,
            batch: nil,
            createdAt: now.addingTimeInterval(-70))

        let replacedResult = JobResult(
            outcome: .compressed,
            kind: .heic,
            method: "q80",
            lossless: false,
            verified: true,
            inputBytes: 2_400_000,
            outputBytes: 980_000,
            outputURL: media.replaced,
            note: nil,
            duration: 0.31,
            sourceFingerprint: stamp,
            outputFingerprint: outputStamp)
        var replaced = item(
            url: media.replaced,
            kind: .heic,
            bytes: 2_400_000,
            state: .finished(replacedResult),
            batch: nil,
            createdAt: now.addingTimeInterval(-90))
        replaced.replaced = true
        replaced.replacedLocation = media.replaced
        replaced.pin = .pinned(media.replaced)
        replaced.outputFingerprint = outputStamp
        replaced.replacedNote = "Replaced .png → .heic"

        let saved = compressedResult.savedBytes + replacedResult.savedBytes
        return Fixture(
            items: [queued, running, compressed, optimal, failed, cancelled, replaced],
            saved: saved,
            toast: "Replaced \(media.replaced.lastPathComponent) (original in Trash)",
            previewURL: media.compressedOutput,
            doneHeadline: "−64%",
            doneSubline: "Saved 5.1 MB · \(media.compressedOutput.lastPathComponent)")
    }

    static func benchItems(_ count: Int) -> [JobItem] {
        let now = Date()
        return (0..<count).map { index in
            let url = URL(fileURLWithPath: "/tmp/ologn-bench/file-\(index).txt")
            let result = JobResult(
                outcome: .compressed,
                kind: .generic,
                method: "xz",
                lossless: true,
                verified: true,
                inputBytes: 10_000,
                outputBytes: 4_000,
                outputURL: url,
                note: nil,
                duration: 0.01)
            return item(
                url: url,
                kind: .generic,
                bytes: 10_000,
                state: .finished(result),
                batch: nil,
                createdAt: now.addingTimeInterval(TimeInterval(-index)))
        }
    }

    private static func item(
        url: URL,
        kind: FileKind,
        bytes: Int64,
        state: JobState,
        batch: UUID?,
        createdAt: Date
    ) -> JobItem {
        let job = Job(
            id: JobID(),
            request: JobRequest(source: url, mode: .smart, settings: EngineSettings(), batchID: batch),
            kind: kind,
            inputBytes: bytes,
            createdAt: createdAt,
            state: state)
        return JobItem(job: job)
    }

    private static func raster(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSImage? {
        let side = 128
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: 36, y: 36, width: 56, height: 56))
        guard let painted = ctx.makeImage() else { return nil }
        return NSImage(cgImage: painted, size: NSSize(width: side, height: side))
    }
}
