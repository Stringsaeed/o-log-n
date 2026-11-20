import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum HEICPrep: Sendable {
    case unreadable
    case multi
    case tooLarge
    case below
    case ready(data: Data, quality: Double, needed: Set<String>, reference: ImageBuffer)
}

struct HEICCodec: Codec {
    let kind: FileKind = .heic
    let lane: Lane = .cpu

    func compress(_ ctx: CodecContext) async throws -> CodecOutcome {
        if ctx.mode == .lossless { return .skipped("HEIC is already a delivery image") }
        let ext = ctx.input.pathExtension.lowercased() == "heif" ? "heif" : "heic"
        let type: UTType = ext == "heif" ? UTType("public.heif") ?? .heic : .heic
        let prepared = try await Offload.run { token -> HEICPrep in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            let input = try Files.read(ctx.input)
            guard let source = CGImageSourceCreateWithData(input as CFData, nil) else { return .unreadable }
            if CGImageSourceGetCount(source) > 1 { return .multi }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            guard WorkingMemory.fits(width: width, height: height, bytesPerPixel: 4) else { return .tooLarge }
            guard let image = ImageIOLossy.orientedImage(from: source),
                  let reference = ImagePixels.buffer(cgImage: image) else { return .unreadable }
            let auxiliary = ImageIOLossy.auxiliary(from: source)
            let needed = Set(auxiliary.map { $0.0 as String })
            let found = try search(
                source: source, reference: reference, type: type, auxiliary: auxiliary, ctx: ctx
            ) { token.isCancelled || ctx.isCancelled() }
            guard let found else { return .below }
            return .ready(data: found.data, quality: found.quality, needed: needed, reference: reference)
        }
        switch prepared {
        case .unreadable: return .skipped("unreadable HEIC")
        case .multi: return .skipped("multi-image HEIC")
        case .tooLarge: return .skipped("image too large for Smart")
        case .below: return .skipped("below the quality bar")
        case .ready(let data, let quality, let needed, let reference):
            let copied = ImageIOLossy.auxiliaryTypes(in: data)
            if copied != needed { return .skipped("auxiliary image did not round-trip") }
            guard Gain.accepts(input: ctx.inputBytes, output: Int64(data.count)) else {
                return .skipped("below minimum gain")
            }
            let decodedOK = try await Offload.run { token -> Bool in
                if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
                guard let decoded = ImagePixels.buffer(data: data) else { return false }
                return decoded.width == reference.width && decoded.height == reference.height
            }
            guard decodedOK else { return .skipped("HEIC output did not decode") }
            let temp = try write(data, ctx: ctx, ext: ext)
            return .produced(
                temp: temp, ext: ext, method: "HEIC · \(QualityScale.qTag(quality))",
                lossless: false, note: nil)
        }
    }

    private func search(
        source: CGImageSource,
        reference: ImageBuffer,
        type: UTType,
        auxiliary: [(CFString, CFDictionary)],
        ctx: CodecContext,
        cancel: @escaping @Sendable () -> Bool
    ) throws -> ImageIOLossy.Candidate? {
        let ladder = QualityScale.lossyQualities
        let threshold = QualityScale.ssim(ctx.settings.quality)
        var low = 0
        var high = ladder.count - 1
        var best: ImageIOLossy.Candidate?
        var encodes = 0
        while low <= high, encodes < 4 {
            if cancel() { throw CancellationError() }
            let mid = (low + high) / 2
            encodes += 1
            guard let data = ImageIOLossy.encodeFromSource(
                source: source, type: type, quality: ladder[mid], auxiliary: auxiliary)
            else {
                low = mid + 1
                continue
            }
            let score = SSIM.mean(reference: reference, data: data)
            if score >= threshold {
                best = ImageIOLossy.Candidate(data: data, quality: ladder[mid], ssim: score)
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        if cancel() { throw CancellationError() }
        return best
    }

    private func write(_ data: Data, ctx: CodecContext, ext: String) throws -> URL {
        let url = TempFile.make(in: ctx.scratch, ext: ext)
        do { try data.write(to: url, options: .atomic) }
        catch { throw FailureMap.jobError(error) }
        return url
    }
}
