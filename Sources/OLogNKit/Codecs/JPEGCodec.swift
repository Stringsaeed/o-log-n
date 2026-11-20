import CJPEGTurbo
import CoreGraphics
import Foundation
import ImageIO

struct JPEGCodec: Codec {
    let kind: FileKind = .jpeg
    let lane: Lane = .cpu

    func compress(_ ctx: CodecContext) async throws -> CodecOutcome {
        let input = try await Offload.run { token -> Data in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            return try Files.read(ctx.input)
        }
        if JPEGInspect.hasMPF(input) { return .skipped("multi-picture JPEG") }
        let info = JPEGInspect.parse(input)
        if ctx.mode == .lossless {
            return try await lossless(input, ctx: ctx, info: info)
        }
        let threshold = QualityScale.ssim(ctx.settings.quality)
        if let lossy = try await lossy(input, ctx: ctx, info: info, threshold: threshold) {
            return lossy
        }
        let progressive = try await Offload.run { token -> Data in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            var output = try JPEGBridge.transcode(input, progressive: 1, markers: 2)
            if ctx.settings.stripMetadataInSmart {
                output = JPEGMarkers.applyingSmartPolicy(output)
            }
            return output
        }
        let progressiveScore = try await Offload.run { token -> Double in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            guard WorkingMemory.fits(width: info.width, height: info.height, bytesPerPixel: 4) else { return 0 }
            return ImagePixels.buffer(data: input).map { SSIM.mean(reference: $0, data: progressive) } ?? 0
        }
        if progressiveScore >= threshold,
           Gain.accepts(input: ctx.inputBytes, output: Int64(progressive.count))
        {
            let temp = try write(progressive, ctx: ctx, ext: jpegExtension(ctx.input))
            return .produced(
                temp: temp, ext: jpegExtension(ctx.input), method: "JPEG · progressive",
                lossless: false, note: nil)
        }
        return try await lossless(input, ctx: ctx, info: info)
    }

    /// Coefficients must always match. Pixels (as ImageIO decodes them) must also match when both files
    /// use the same scan type; across scan types ImageIO renders coefficient-identical data differently (D3).
    static func verifyFiles(_ original: URL, _ output: URL) throws {
        let a = try Files.read(original)
        let b = try Files.read(output)
        guard JPEGBridge.coefficientsEqual(a, b) else {
            throw JobError.verificationFailed("jpeg coefficients differ")
        }
        guard JPEGInspect.isProgressive(a) == JPEGInspect.isProgressive(b) else { return }
        guard let left = ImagePixels.buffer(data: a), let right = ImagePixels.buffer(data: b), left == right else {
            throw JobError.verificationFailed("jpeg pixels differ")
        }
    }

    private func lossless(_ input: Data, ctx: CodecContext, info: JPEGInspect.Info) async throws -> CodecOutcome {
        _ = info
        if ctx.settings.jpegLossless == .progressive, !JPEGInspect.isProgressive(input),
           let outcome = try await losslessProgressive(input, ctx: ctx)
        {
            return outcome
        }
        let output = try await Offload.run { token -> Data in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            return try JPEGBridge.transcode(input, progressive: -1, markers: 2)
        }
        let temp = try write(output, ctx: ctx, ext: jpegExtension(ctx.input))
        try await Offload.run { token in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            try JPEGCodec.verifyFiles(ctx.input, temp)
        }
        guard Gain.accepts(input: ctx.inputBytes, output: Int64(output.count)) else {
            try? FileManager.default.removeItem(at: temp)
            return .skipped("below minimum gain")
        }
        return .produced(
            temp: temp, ext: jpegExtension(ctx.input), method: "JPEG · Huffman-optimised",
            lossless: true, note: nil)
    }

    /// Opt-in lossless style: progressive re-scan, DCT-coefficient-exact. Returns nil to fall back to the
    /// pixel-exact path when it does not clear the minimum gain.
    private func losslessProgressive(_ input: Data, ctx: CodecContext) async throws -> CodecOutcome? {
        let output = try await Offload.run { token -> Data in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            return try JPEGBridge.transcode(input, progressive: 1, markers: 2)
        }
        guard Gain.accepts(input: ctx.inputBytes, output: Int64(output.count)) else { return nil }
        let temp = try write(output, ctx: ctx, ext: jpegExtension(ctx.input))
        do {
            try await Offload.run { token in
                if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
                try JPEGCodec.verifyFiles(ctx.input, temp)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return .produced(
            temp: temp, ext: jpegExtension(ctx.input), method: "JPEG · progressive (DCT-exact)",
            lossless: true, note: "identical DCT coefficients; some decoders render it very slightly differently")
    }

    private func lossy(
        _ input: Data, ctx: CodecContext, info: JPEGInspect.Info, threshold: Double
    ) async throws -> CodecOutcome? {
        let pixels = max(info.width * info.height, 1)
        let bpp = Double(input.count) * 8 / Double(pixels)
        if info.components >= 4 || bpp < 1.35 || info.estimatedQuality <= 72 { return nil }
        guard WorkingMemory.fits(width: info.width, height: info.height, bytesPerPixel: 4) else { return nil }
        let keepMetadata = !ctx.settings.stripMetadataInSmart
        let candidate = try await Offload.run { token -> (data: Data, method: String)? in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            guard let source = CGImageSourceCreateWithData(input as CFData, nil),
                  let image = ImageIOLossy.orientedImage(from: source),
                  let reference = ImagePixels.buffer(cgImage: image)
            else { return nil }
            let cancel: @Sendable () -> Bool = { token.isCancelled || ctx.isCancelled() }
            let found: ImageIOLossy.Candidate?
            if keepMetadata {
                found = Self.searchFromSource(source: source, reference: reference, threshold: threshold, cancel: cancel)
            } else {
                found = ImageIOLossy.search(
                    image: image, reference: reference, type: .jpeg, threshold: threshold, cancel: cancel)
            }
            guard let found else { return nil }
            let progressive = try JPEGBridge.transcode(found.data, progressive: 1, markers: 2)
            let progressiveScore = SSIM.mean(reference: reference, data: progressive)
            let tag = QualityScale.qTag(found.quality)
            if progressiveScore >= threshold {
                return (progressive, "JPEG · \(tag) + progressive")
            }
            return (found.data, "JPEG · \(tag)")
        }
        guard let candidate else { return nil }
        guard Gain.accepts(input: ctx.inputBytes, output: Int64(candidate.data.count)) else { return nil }
        let temp = try write(candidate.data, ctx: ctx, ext: jpegExtension(ctx.input))
        return .produced(
            temp: temp, ext: jpegExtension(ctx.input), method: candidate.method,
            lossless: false, note: nil)
    }

    private static func searchFromSource(
        source: CGImageSource, reference: ImageBuffer, threshold: Double, cancel: @escaping @Sendable () -> Bool
    ) -> ImageIOLossy.Candidate? {
        let ladder = QualityScale.lossyQualities
        var low = 0
        var high = ladder.count - 1
        var best: ImageIOLossy.Candidate?
        var encodes = 0
        while low <= high && encodes < 4 {
            if cancel() { return best }
            let mid = (low + high) / 2
            encodes += 1
            guard let data = ImageIOLossy.encodeFromSource(
                source: source, type: .jpeg, quality: ladder[mid], auxiliary: [])
            else {
                low = mid + 1
                continue
            }
            let score = SSIM.mean(reference: reference, data: data)
            if score >= threshold {
                best = .init(data: data, quality: ladder[mid], ssim: score)
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return best
    }

    private func write(_ data: Data, ctx: CodecContext, ext: String) throws -> URL {
        let url = TempFile.make(in: ctx.scratch, ext: ext)
        do { try data.write(to: url, options: .atomic) }
        catch { throw FailureMap.jobError(error) }
        return url
    }

    private func jpegExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext == "jpeg" ? "jpeg" : "jpg"
    }
}

enum JPEGBridge {
    static func message(_ bytes: [CChar]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func transcode(_ data: Data, progressive: Int32, markers: Int32) throws -> Data {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw JobError.unreadable("empty jpeg")
            }
            var out: UnsafeMutablePointer<UInt8>?
            var outLength = 0
            var err = [CChar](repeating: 0, count: 200)
            let rc = ologn_jpeg_transcode(base, raw.count, &out, &outLength, progressive, markers, &err)
            defer { free(out) }
            guard rc == 0, let out, outLength > 0 else {
                throw JobError.codec(Self.message(err))
            }
            return Data(bytes: out, count: outLength)
        }
    }

    static func coefficientsEqual(_ a: Data, _ b: Data) -> Bool {
        a.withUnsafeBytes { aRaw in
            b.withUnsafeBytes { bRaw in
                guard let aBase = aRaw.bindMemory(to: UInt8.self).baseAddress,
                      let bBase = bRaw.bindMemory(to: UInt8.self).baseAddress
                else { return false }
                var err = [CChar](repeating: 0, count: 200)
                return ologn_jpeg_coefficients_equal(aBase, aRaw.count, bBase, bRaw.count, &err) == 1
            }
        }
    }
}

enum JPEGInspect {
    struct Info {
        var width: Int
        var height: Int
        var components: Int
        var estimatedQuality: Int
    }

    /// True when the first frame header is SOF2 (progressive DCT, Huffman) or SOF10 (progressive, arithmetic).
    static func isProgressive(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var index = 2
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
        while index + 3 < bytes.count {
            while index < bytes.count && bytes[index] == 0xFF { index += 1 }
            guard index < bytes.count else { break }
            let marker = bytes[index]
            index += 1
            if marker == 0xDA || marker == 0xD9 { break }
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { continue }
            guard index + 1 < bytes.count else { break }
            let length = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
            guard length >= 2, index + length <= bytes.count else { break }
            if marker == 0xC2 || marker == 0xCA { return true }
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC { return false }
            index += length
        }
        return false
    }

    static func parse(_ data: Data) -> Info {
        let bytes = [UInt8](data)
        var width = 0
        var height = 0
        var components = 0
        var luma: [Int] = []
        var index = 2
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            return Info(width: 0, height: 0, components: 0, estimatedQuality: 100)
        }
        while index + 3 < bytes.count {
            while index < bytes.count && bytes[index] == 0xFF { index += 1 }
            guard index < bytes.count else { break }
            let marker = bytes[index]
            index += 1
            if marker == 0xDA || marker == 0xD9 { break }
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { continue }
            guard index + 1 < bytes.count else { break }
            let length = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
            guard length >= 2, index + length <= bytes.count else { break }
            let payload = index + 2
            let payloadCount = length - 2
            if marker == 0xDB {
                luma = lumaTable(bytes, payload, payloadCount) ?? luma
            } else if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                if payloadCount >= 6 {
                    height = (Int(bytes[payload + 1]) << 8) | Int(bytes[payload + 2])
                    width = (Int(bytes[payload + 3]) << 8) | Int(bytes[payload + 4])
                    components = Int(bytes[payload + 5])
                }
            }
            index += length
        }
        let quality = luma.isEmpty ? 100 : estimateQuality(natural: unzigzag(luma))
        return Info(width: width, height: height, components: components, estimatedQuality: quality)
    }

    static func hasMPF(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }
        var index = 2
        while index + 3 < bytes.count {
            while index < bytes.count && bytes[index] == 0xFF { index += 1 }
            guard index < bytes.count else { return false }
            let marker = bytes[index]
            index += 1
            if marker == 0xDA || marker == 0xD9 { return false }
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { continue }
            guard index + 1 < bytes.count else { return false }
            let length = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
            guard length >= 2, index + length <= bytes.count else { return false }
            if marker == 0xE2, length >= 6,
               bytes[index + 2] == 0x4D, bytes[index + 3] == 0x50,
               bytes[index + 4] == 0x46, bytes[index + 5] == 0x00
            {
                return true
            }
            index += length
        }
        return false
    }

    private static func lumaTable(_ bytes: [UInt8], _ start: Int, _ count: Int) -> [Int]? {
        var cursor = 0
        var fallback: [Int]?
        while cursor + 65 <= count {
            let id = Int(bytes[start + cursor] & 0x0F)
            let precision = Int(bytes[start + cursor] >> 4)
            cursor += 1
            let values = 64 * (precision == 0 ? 1 : 2)
            guard cursor + values <= count else { return fallback }
            var table: [Int] = []
            table.reserveCapacity(64)
            if precision == 0 {
                for offset in 0..<64 { table.append(Int(bytes[start + cursor + offset])) }
            } else {
                for offset in 0..<64 {
                    let hi = Int(bytes[start + cursor + offset * 2])
                    let lo = Int(bytes[start + cursor + offset * 2 + 1])
                    table.append((hi << 8) | lo)
                }
            }
            if id == 0 { return table }
            fallback = table
            cursor += values
        }
        return fallback
    }

    private static let naturalOrder = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    private static func unzigzag(_ zigzag: [Int]) -> [Int] {
        var natural = [Int](repeating: 0, count: 64)
        for index in 0..<min(64, zigzag.count) {
            natural[naturalOrder[index]] = zigzag[index]
        }
        return natural
    }

    private static let ijgLuma = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]

    /// ImageIO luma DQTs in zigzag (file) order, measured on this OS.
    private static let imageIO: [(Int, [Int])] = [
        (50, ints("6,6,6,6,6,6,10,6,6,10,14,10,10,10,14,18,14,14,14,14,18,23,18,18,18,18,18,23,28,23,23,23,23,23,23,28,28,28,28,28,28,28,28,34,34,34,34,34,34,39,39,39,39,39,44,44,44,44,44,44,44,44,44,44")),
        (55, ints("4,4,4,4,4,4,8,4,4,8,11,8,8,8,11,15,11,11,11,11,15,18,15,15,15,15,15,18,22,18,18,18,18,18,18,22,22,22,22,22,22,22,22,27,27,27,27,27,27,31,31,31,31,31,35,35,35,35,35,35,35,35,35,35")),
        (60, ints("4,4,4,4,4,4,6,4,4,6,9,6,6,6,9,12,9,9,9,9,12,15,12,12,12,12,12,15,18,15,15,15,15,15,15,18,18,18,18,18,18,18,18,21,21,21,21,21,21,25,25,25,25,25,28,28,28,28,28,28,28,28,28,28")),
        (65, ints("3,3,3,3,3,3,5,3,3,5,7,5,5,5,7,9,7,7,7,7,9,12,9,9,9,9,9,12,14,12,12,12,12,12,12,14,14,14,14,14,14,14,14,17,17,17,17,17,17,20,20,20,20,20,22,22,22,22,22,22,22,22,22,22")),
        (70, ints("2,2,2,2,2,2,4,2,2,4,6,4,4,4,6,8,6,6,6,6,8,10,8,8,8,8,8,10,12,10,10,10,10,10,10,12,12,12,12,12,12,12,12,14,14,14,14,14,14,16,16,16,16,16,18,18,18,18,18,18,18,18,18,18")),
        (72, ints("2,2,2,2,2,2,4,2,2,4,5,4,4,4,5,7,5,5,5,5,7,9,7,7,7,7,7,9,11,9,9,9,9,9,9,11,11,11,11,11,11,11,11,13,13,13,13,13,13,15,15,15,15,15,17,17,17,17,17,17,17,17,17,17")),
        (75, ints("2,2,2,2,2,2,3,2,2,3,5,3,3,3,5,6,5,5,5,5,6,8,6,6,6,6,6,8,10,8,8,8,8,8,8,10,10,10,10,10,10,10,10,12,12,12,12,12,12,14,14,14,14,14,15,15,15,15,15,15,15,15,15,15")),
        (80, ints("2,2,2,2,2,2,3,2,2,3,4,3,3,3,4,5,4,4,4,4,5,7,5,5,5,5,5,7,8,7,7,7,7,7,7,8,8,8,8,8,8,8,8,10,10,10,10,10,10,11,11,11,11,11,13,13,13,13,13,13,13,13,13,13")),
        (85, ints("1,1,1,1,1,1,2,1,1,2,3,2,2,2,3,4,3,3,3,3,4,6,4,4,4,4,4,6,7,6,6,6,6,6,6,7,7,7,7,7,7,7,7,8,8,8,8,8,8,9,9,9,9,9,11,11,11,11,11,11,11,11,11,11")),
        (88, ints("1,1,1,1,1,1,2,1,1,2,3,2,2,2,3,4,3,3,3,3,4,5,4,4,4,4,4,5,6,5,5,5,5,5,5,6,6,6,6,6,6,6,6,7,7,7,7,7,7,9,9,9,9,9,10,10,10,10,10,10,10,10,10,10")),
        (90, ints("1,1,1,1,1,1,2,1,1,2,3,2,2,2,3,4,3,3,3,3,4,5,4,4,4,4,4,5,6,5,5,5,5,5,5,6,6,6,6,6,6,6,6,7,7,7,7,7,7,8,8,8,8,8,9,9,9,9,9,9,9,9,9,9")),
        (92, ints("1,1,1,1,1,1,2,1,1,2,3,2,2,2,3,4,3,3,3,3,4,4,4,4,4,4,4,4,5,4,4,4,4,4,4,5,5,5,5,5,5,5,5,6,6,6,6,6,6,8,8,8,8,8,8,8,8,8,8,8,8,8,8,8")),
        (95, ints("1,1,1,1,1,1,2,1,1,2,2,2,2,2,2,3,2,2,2,2,3,4,3,3,3,3,3,4,5,4,4,4,4,4,4,5,5,5,5,5,5,5,5,6,6,6,6,6,6,7,7,7,7,7,8,8,8,8,8,8,8,8,8,8")),
    ]

    private static func ints(_ text: String) -> [Int] {
        text.split(separator: ",").map { Int($0) ?? 0 }
    }

    private static func estimateQuality(natural: [Int]) -> Int {
        var best = Int.max
        var quality = 100
        for (q, table) in imageIO {
            let distance = l1(natural, unzigzag(table))
            if distance < best {
                best = distance
                quality = q
            }
        }
        for q in 1...100 {
            let distance = l1(natural, scaledIJG(q))
            if distance < best {
                best = distance
                quality = q
            }
        }
        return quality
    }

    private static func scaledIJG(_ quality: Int) -> [Int] {
        let scale = quality < 50 ? 5000 / quality : 200 - quality * 2
        return ijgLuma.map { value in
            min(255, max(1, (value * scale + 50) / 100))
        }
    }

    private static func l1(_ a: [Int], _ b: [Int]) -> Int {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }
    }
}
