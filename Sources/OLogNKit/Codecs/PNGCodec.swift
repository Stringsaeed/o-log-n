import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PNGCodec: Codec {
    let kind: FileKind = .png
    let lane: Lane = .cpu

    func compress(_ ctx: CodecContext) async throws -> CodecOutcome {
        let loaded = try await Offload.run { token -> (Data, PNGFile) in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            let original = try Files.read(ctx.input)
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            return (original, try PNGFormat.parse(original))
        }
        let original = loaded.0
        let file = loaded.1
        if file.hasAnimatedMarker || file.interlace != 0 {
            return .skipped("animated/interlaced PNG")
        }
        if ctx.mode == .smart, let smart = try await smart(file, original: original, ctx: ctx) {
            return smart
        }
        return try await lossless(file, ctx: ctx, allowReductions: true)
    }

    private func smart(_ file: PNGFile, original: Data, ctx: CodecContext) async throws -> CodecOutcome? {
        guard WorkingMemory.fits(width: file.width, height: file.height, bytesPerPixel: 4) else { return nil }
        let decided: Data? = try await Offload.run { token in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            guard let rgba = PNGFormat.straightRGBA(file), PNGFormat.isFullyOpaque(rgba) else { return nil }
            let cancel: @Sendable () -> Bool = { token.isCancelled || ctx.isCancelled() }
            let image = PaletteQuantizer.quantize(
                rgba: rgba, width: file.width, height: file.height, cancel: cancel)
            if cancel() { throw CancellationError() }
            let encoded = try PNGFormat.encodeIndexed(
                width: file.width, height: file.height,
                indices: image.indices, palette: [UInt8](image.palette), kept: file.chunks)
            let decoded = try PNGFormat.canonical(try PNGFormat.parse(encoded))
            if PNGFormat.maxAlphaDelta(rgba, decoded) > 2 { return nil }
            guard let reference = ImagePixels.buffer(data: original) else { return nil }
            let score = SSIM.mean(reference: reference, data: encoded)
            let threshold = QualityScale.palette(ctx.settings.quality)
            guard score >= threshold, Gain.accepts(input: ctx.inputBytes, output: Int64(encoded.count)) else {
                return nil
            }
            return encoded
        }
        if let decided {
            let temp = try write(decided, ctx: ctx)
            return .produced(temp: temp, ext: "png", method: "PNG · palette 256", lossless: false, note: nil)
        }
        guard ctx.settings.imageConversion != .keep else { return nil }
        guard let reference = try await Offload.run({ token -> ImageBuffer? in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            return ImagePixels.buffer(data: original)
        }) else { return nil }
        return try await converted(original: original, reference: reference, ctx: ctx)
    }

    private func converted(original: Data, reference: ImageBuffer, ctx: CodecContext) async throws -> CodecOutcome? {
        let avif = UTType(filenameExtension: "avif") ?? .heic
        let type: UTType = ctx.settings.imageConversion == .avif ? avif : .heic
        let ext = ctx.settings.imageConversion == .avif ? "avif" : "heic"
        let label = ctx.settings.imageConversion == .avif ? "AVIF" : "HEIC"
        let found = try await Offload.run { token -> ImageIOLossy.Candidate? in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            guard let source = CGImageSourceCreateWithData(original as CFData, nil),
                  let image = ImageIOLossy.orientedImage(from: source) else { return nil }
            return ImageIOLossy.search(
                image: image,
                reference: reference,
                type: type,
                threshold: QualityScale.ssim(ctx.settings.quality),
                cancel: { token.isCancelled || ctx.isCancelled() })
        }
        guard let found else { return nil }
        guard Gain.accepts(input: ctx.inputBytes, output: Int64(found.data.count)) else { return nil }
        let temp = try write(found.data, ctx: ctx, ext: ext)
        return .produced(
            temp: temp, ext: ext, method: "PNG → \(label) · \(QualityScale.qTag(found.quality))",
            lossless: false, note: nil)
    }

    private func lossless(_ file: PNGFile, ctx: CodecContext, allowReductions: Bool) async throws -> CodecOutcome {
        do {
            return try await encodeLossless(file, ctx: ctx, allowReductions: allowReductions)
        } catch let error as JobError {
            if case .verificationFailed = error, allowReductions {
                return try await encodeLossless(file, ctx: ctx, allowReductions: false)
            }
            throw error
        }
    }

    private func encodeLossless(_ file: PNGFile, ctx: CodecContext, allowReductions: Bool) async throws -> CodecOutcome {
        let produced: (Data, Int) = try await Offload.run { token in
            let cancel: @Sendable () -> Bool = { token.isCancelled || ctx.isCancelled() }
            let encoded = try PNGFormat.encodeLossless(file, allowReductions: allowReductions, cancel: cancel)
            return (encoded.data, encoded.level)
        }
        let temp = try write(produced.0, ctx: ctx)
        do {
            try await Offload.run { token in
                if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
                try PNGFormat.verifyPair(ctx.input, temp)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard Gain.accepts(input: ctx.inputBytes, output: Int64(produced.0.count)) else {
            try? FileManager.default.removeItem(at: temp)
            return .skipped("below minimum gain")
        }
        return .produced(
            temp: temp, ext: "png", method: "PNG · libdeflate \(produced.1)", lossless: true, note: nil)
    }

    private func write(_ data: Data, ctx: CodecContext, ext: String = "png") throws -> URL {
        let url = TempFile.make(in: ctx.scratch, ext: ext)
        do { try data.write(to: url, options: .atomic) }
        catch { throw FailureMap.jobError(error) }
        return url
    }
}
