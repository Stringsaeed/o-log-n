import CLibDeflate
import Foundation

enum Zlib {
    static func compress(_ input: Data, level: Int) throws -> Data {
        guard let compressor = libdeflate_alloc_compressor(Int32(level)) else {
            throw JobError.codec("libdeflate compressor")
        }
        defer { libdeflate_free_compressor(compressor) }
        let bound = libdeflate_zlib_compress_bound(compressor, input.count)
        var output = Data(count: bound)
        let written: Int = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                guard let dstBase = dst.baseAddress else { return 0 }
                let srcBase = src.baseAddress ?? UnsafeRawPointer(dstBase)
                return libdeflate_zlib_compress(compressor, srcBase, input.count, dstBase, bound)
            }
        }
        guard written > 0 else { throw JobError.codec("libdeflate compress failed") }
        return output.prefix(written)
    }

    static func decompress(_ input: Data, expected: Int) throws -> Data {
        guard let decompressor = libdeflate_alloc_decompressor() else {
            throw JobError.codec("libdeflate decompressor")
        }
        defer { libdeflate_free_decompressor(decompressor) }
        var output = Data(count: expected)
        var actual = 0
        let result: libdeflate_result = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else {
                    return libdeflate_result(rawValue: 1)
                }
                return libdeflate_zlib_decompress(
                    decompressor, srcBase, input.count, dstBase, expected, &actual)
            }
        }
        guard result.rawValue == 0 else {
            throw JobError.verificationFailed("png inflate failed")
        }
        guard actual == expected else {
            throw JobError.verificationFailed("png inflate length \(actual) != \(expected)")
        }
        return output
    }
}

struct PNGChunk: Sendable, Equatable {
    var type: String
    var data: Data
}

struct PNGFile: Sendable {
    var width: Int
    var height: Int
    var bitDepth: Int
    var colorType: Int
    var interlace: Int
    var chunks: [PNGChunk]
    /// Unfiltered scanline samples. No filter bytes.
    var samples: Data
    var bytesPerRow: Int
    var filterBPP: Int

    var hasAnimatedMarker: Bool { chunks.contains { $0.type == "acTL" } }

    func chunk(_ type: String) -> PNGChunk? { chunks.first { $0.type == type } }

    var blocksReduction: Bool {
        chunks.contains { ["tRNS", "bKGD", "sBIT", "hIST"].contains($0.type) }
    }
}

enum PNGFormat {
    private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    static func parse(_ data: Data) throws -> PNGFile {
        guard data.count >= 8, data.prefix(8) == signature else {
            throw JobError.unreadable("not a png")
        }
        var chunks: [PNGChunk] = []
        var offset = 8
        var idat = Data()
        while offset + 12 <= data.count {
            let length = Int(readU32(data, offset))
            let typeBytes = data.subdata(in: offset + 4..<offset + 8)
            guard let type = String(data: typeBytes, encoding: .ascii), type.count == 4 else {
                throw JobError.unreadable("bad png chunk")
            }
            let start = offset + 8
            let end = start + length
            guard length >= 0, end + 4 <= data.count else { throw JobError.unreadable("truncated png chunk") }
            let chunkData = data.subdata(in: start..<end)
            if type == "IDAT" {
                idat.append(chunkData)
            } else {
                chunks.append(PNGChunk(type: type, data: chunkData))
            }
            offset = end + 4
            if type == "IEND" { break }
        }
        guard let ihdr = chunks.first(where: { $0.type == "IHDR" })?.data, ihdr.count >= 13 else {
            throw JobError.unreadable("png missing IHDR")
        }
        let width = Int(readU32(ihdr, 0))
        let height = Int(readU32(ihdr, 4))
        let bitDepth = Int(ihdr[8])
        let colorType = Int(ihdr[9])
        let interlace = Int(ihdr[12])
        guard width > 0, height > 0 else { throw JobError.unreadable("empty png") }
        let bitsPerPixel = try WorkingMemory.count(samplesPerPixel(colorType), bitDepth)
        let pixelBits = try WorkingMemory.count(width, bitsPerPixel)
        let (padded, padOverflow) = pixelBits.addingReportingOverflow(7)
        if padOverflow { throw JobError.unreadable("image dimensions overflow") }
        let row = padded / 8
        let bpp = filterBPP(bitDepth: bitDepth, colorType: colorType)
        guard interlace == 0 else {
            return PNGFile(
                width: width, height: height, bitDepth: bitDepth, colorType: colorType,
                interlace: interlace, chunks: chunks, samples: Data(), bytesPerRow: row, filterBPP: bpp)
        }
        let (rowPlus, rowOverflow) = row.addingReportingOverflow(1)
        if rowOverflow { throw JobError.unreadable("image dimensions overflow") }
        let expected = try WorkingMemory.count(height, rowPlus)
        guard WorkingMemory.fits(expected) else {
            throw JobError.codec("image exceeds the working-memory budget")
        }
        let inflated = try Zlib.decompress(idat, expected: expected)
        let samples = try unfilter(inflated, height: height, row: row, bpp: bpp)
        return PNGFile(
            width: width, height: height, bitDepth: bitDepth, colorType: colorType,
            interlace: interlace, chunks: chunks, samples: samples, bytesPerRow: row, filterBPP: bpp)
    }

    static func verifyPair(_ original: URL, _ output: URL) throws {
        let a = try parse(try Files.read(original))
        let b = try parse(try Files.read(output))
        let left = try canonical(a)
        let right = try canonical(b)
        guard left == right else { throw JobError.verificationFailed("png pixels differ") }
        guard let ia = ImagePixels.buffer(url: original), let ib = ImagePixels.buffer(url: output), ia == ib else {
            throw JobError.verificationFailed("png imageio pixels differ")
        }
    }

    /// Lossless re-encode. `level` is the libdeflate level actually used.
    static func encodeLossless(
        _ file: PNGFile,
        allowReductions: Bool,
        cancel: @escaping @Sendable () -> Bool
    ) throws -> (data: Data, level: Int) {
        if cancel() { throw CancellationError() }
        var working = file
        var changed = false
        if allowReductions, file.bitDepth == 8, !file.blocksReduction, file.interlace == 0 {
            if let reduced = reduce(file) {
                working = reduced.file
                changed = reduced.changed
            }
        }
        let filtered = try chooseFiltered(working, cancel: cancel)
        let level = working.samples.count > 64 * 1024 * 1024 ? 9 : 12
        if cancel() { throw CancellationError() }
        let compressed = try Zlib.compress(filtered, level: level)
        if !changed, file.bitDepth == working.bitDepth, file.colorType == working.colorType {
            return (spliceIDAT(file, compressed: compressed), level)
        }
        return (rebuild(working, compressed: compressed, stripSmartText: false), level)
    }

    static func encodeIndexed(
        width: Int,
        height: Int,
        indices: Data,
        palette: [UInt8],
        kept: [PNGChunk]
    ) throws -> Data {
        let (span, spanOverflow) = width.addingReportingOverflow(1)
        if spanOverflow || width < 0 || height < 0 {
            throw JobError.unreadable("image dimensions overflow")
        }
        let rowsBytes = try WorkingMemory.count(height, span)
        guard WorkingMemory.fits(rowsBytes) else {
            throw JobError.codec("image exceeds the working-memory budget")
        }
        var rows = Data(count: rowsBytes)
        rows.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            indices.withUnsafeBytes { src in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return }
                for y in 0..<height {
                    base[y * (width + 1)] = 0
                    base.advanced(by: y * (width + 1) + 1).update(from: srcBase.advanced(by: y * width), count: width)
                }
            }
        }
        let compressed = try Zlib.compress(rows, level: 12)
        var ihdr = Data(count: 13)
        writeU32(&ihdr, 0, UInt32(width))
        writeU32(&ihdr, 4, UInt32(height))
        ihdr[8] = 8
        ihdr[9] = 3
        let keepTypes: Set<String> = ["cICP", "iCCP", "sRGB", "cHRM", "gAMA", "sBIT", "pHYs"]
        var ancillary: [PNGChunk] = [PNGChunk(type: "PLTE", data: Data(palette))]
        for chunk in kept where keepTypes.contains(chunk.type) {
            ancillary.append(chunk)
        }
        var chunks = [PNGChunk(type: "IHDR", data: ihdr)]
        chunks.append(contentsOf: ordered(ancillary))
        chunks.append(PNGChunk(type: "IDAT", data: compressed))
        chunks.append(PNGChunk(type: "IEND", data: Data()))
        return assemble(chunks)
    }

    static func straightRGBA(_ file: PNGFile) -> Data? {
        guard file.bitDepth == 8, file.interlace == 0 else { return nil }
        guard WorkingMemory.fits(width: file.width, height: file.height, bytesPerPixel: 4) else { return nil }
        let count = file.width * file.height
        var rgba = Data(count: count * 4)
        let samples = file.samples
        let row = file.bytesPerRow
        let key = truecolorKey(file)
        let ok: Bool = rgba.withUnsafeMutableBytes { dstRaw in
            samples.withUnsafeBytes { srcRaw in
                guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return false }
                switch file.colorType {
                case 2:
                    for y in 0..<file.height {
                        for x in 0..<file.width {
                            let s = src.advanced(by: y * row + x * 3)
                            let d = dst.advanced(by: (y * file.width + x) * 4)
                            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]
                            if let key, s[0] == key.r, s[1] == key.g, s[2] == key.b {
                                d[3] = 0
                            } else {
                                d[3] = 255
                            }
                        }
                    }
                case 6:
                    for y in 0..<file.height {
                        for x in 0..<file.width {
                            let s = src.advanced(by: y * row + x * 4)
                            let d = dst.advanced(by: (y * file.width + x) * 4)
                            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]
                        }
                    }
                default:
                    return false
                }
                return true
            }
        }
        return ok ? rgba : nil
    }

    /// Largest absolute alpha difference. 255 when the buffers are not the same length.
    static func maxAlphaDelta(_ left: Data, _ right: Data) -> Int {
        guard left.count == right.count, left.count % 4 == 0 else { return 255 }
        var maxDelta = 0
        var index = 3
        while index < left.count {
            let delta = abs(Int(left[index]) - Int(right[index]))
            if delta > maxDelta { maxDelta = delta }
            index += 4
        }
        return maxDelta
    }

    static func isFullyOpaque(_ rgba: Data) -> Bool {
        var index = 3
        while index < rgba.count {
            if rgba[index] != 255 { return false }
            index += 4
        }
        return true
    }

    // MARK: - Reductions

    private struct Reduction {
        var file: PNGFile
        var changed: Bool
    }

    private static func reduce(_ file: PNGFile) -> Reduction? {
        guard file.bitDepth == 8 else { return nil }
        var samples = file.samples
        var colorType = file.colorType
        var changed = false
        if colorType == 6, alphaIsOpaque(samples, width: file.width, height: file.height, row: file.bytesPerRow) {
            samples = dropAlpha(samples, width: file.width, height: file.height)
            colorType = 2
            changed = true
        }
        if colorType == 2 || colorType == 6 {
            if let indexed = exactPalette(samples, width: file.width, height: file.height, colorType: colorType) {
                var next = file
                next.samples = indexed.indices
                next.colorType = 3
                next.bytesPerRow = file.width
                next.filterBPP = 1
                next.chunks.removeAll { ["PLTE", "tRNS", "bKGD", "sBIT", "hIST"].contains($0.type) }
                next.chunks.insert(PNGChunk(type: "PLTE", data: indexed.palette), at: 1)
                if let trns = indexed.trns {
                    next.chunks.insert(PNGChunk(type: "tRNS", data: trns), at: 2)
                }
                return Reduction(file: next, changed: true)
            }
        }
        guard changed else { return nil }
        var next = file
        next.samples = samples
        next.colorType = colorType
        next.bytesPerRow = file.width * (colorType == 2 ? 3 : 4)
        next.filterBPP = colorType == 2 ? 3 : 4
        return Reduction(file: next, changed: true)
    }

    private static func alphaIsOpaque(_ samples: Data, width: Int, height: Int, row: Int) -> Bool {
        samples.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            for y in 0..<height {
                for x in 0..<width where base[y * row + x * 4 + 3] != 255 { return false }
            }
            return true
        }
    }

    private static func dropAlpha(_ samples: Data, width: Int, height: Int) -> Data {
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { dstRaw in
            samples.withUnsafeBytes { srcRaw in
                guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                let row = width * 4
                var o = 0
                for y in 0..<height {
                    for x in 0..<width {
                        let s = y * row + x * 4
                        dst[o] = src[s]
                        dst[o + 1] = src[s + 1]
                        dst[o + 2] = src[s + 2]
                        o += 3
                    }
                }
            }
        }
        return rgb
    }

    private struct Indexed {
        var indices: Data
        var palette: Data
        var trns: Data?
    }

    /// Exact palette only when the image already has ≤ 256 distinct colours.
    private static func exactPalette(_ samples: Data, width: Int, height: Int, colorType: Int) -> Indexed? {
        let channels = colorType == 6 ? 4 : 3
        var lookup: [UInt32: UInt8] = [:]
        var colors: [UInt32] = []
        colors.reserveCapacity(257)
        let pixelCount = width * height
        for i in 0..<pixelCount {
            let o = i * channels
            var key: UInt32 = 0
            if channels == 4 {
                key = UInt32(samples[o]) << 24 | UInt32(samples[o + 1]) << 16 | UInt32(samples[o + 2]) << 8 | UInt32(samples[o + 3])
            } else {
                key = UInt32(samples[o]) << 16 | UInt32(samples[o + 1]) << 8 | UInt32(samples[o + 2])
            }
            if lookup[key] == nil {
                if colors.count == 256 { return nil }
                lookup[key] = UInt8(colors.count)
                colors.append(key)
            }
        }
        var indices = Data(count: pixelCount)
        for i in 0..<pixelCount {
            let o = i * channels
            let key: UInt32
            if channels == 4 {
                key = UInt32(samples[o]) << 24 | UInt32(samples[o + 1]) << 16 | UInt32(samples[o + 2]) << 8 | UInt32(samples[o + 3])
            } else {
                key = UInt32(samples[o]) << 16 | UInt32(samples[o + 1]) << 8 | UInt32(samples[o + 2])
            }
            indices[i] = lookup[key] ?? 0
        }
        var palette = Data(count: colors.count * 3)
        var trns = Data(count: colors.count)
        var usesAlpha = false
        for (i, key) in colors.enumerated() {
            if channels == 4 {
                palette[i * 3] = UInt8((key >> 24) & 0xff)
                palette[i * 3 + 1] = UInt8((key >> 16) & 0xff)
                palette[i * 3 + 2] = UInt8((key >> 8) & 0xff)
                let alpha = UInt8(key & 0xff)
                trns[i] = alpha
                if alpha != 255 { usesAlpha = true }
            } else {
                palette[i * 3] = UInt8((key >> 16) & 0xff)
                palette[i * 3 + 1] = UInt8((key >> 8) & 0xff)
                palette[i * 3 + 2] = UInt8(key & 0xff)
            }
        }
        return Indexed(indices: indices, palette: palette, trns: usesAlpha ? trns : nil)
    }

    // MARK: - Filter

    private static func chooseFiltered(_ file: PNGFile, cancel: @escaping @Sendable () -> Bool) throws -> Data {
        let adaptive = try filter(file, fixed: nil, cancel: cancel)
        let none = try filter(file, fixed: 0, cancel: cancel)
        if cancel() { throw CancellationError() }
        let a = try Zlib.compress(adaptive, level: 6)
        let n = try Zlib.compress(none, level: 6)
        return a.count <= n.count ? adaptive : none
    }

    private static func filter(_ file: PNGFile, fixed: UInt8?, cancel: @escaping @Sendable () -> Bool) throws -> Data {
        let width = file.bytesPerRow
        let height = file.height
        let bpp = file.filterBPP
        var filtered = Data(count: height * (width + 1))
        let samples = file.samples
        try filtered.withUnsafeMutableBytes { dstRaw in
            try samples.withUnsafeBytes { srcRaw in
                guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                var candidate = [UInt8](repeating: 0, count: width)
                var bestRow = [UInt8](repeating: 0, count: width)
                let filters: ClosedRange<UInt8> = fixed.map { $0...$0 } ?? 0...4
                for y in 0..<height {
                    if y & 63 == 0, cancel() { throw CancellationError() }
                    var bestScore = Int.max
                    var bestFilter: UInt8 = 0
                    for kind in filters {
                        var score = 0
                        for x in 0..<width {
                            let cur = Int(src[y * width + x])
                            let left = x >= bpp ? Int(src[y * width + x - bpp]) : 0
                            let up = y > 0 ? Int(src[(y - 1) * width + x]) : 0
                            let ul = y > 0 && x >= bpp ? Int(src[(y - 1) * width + x - bpp]) : 0
                            let pred: Int
                            switch kind {
                            case 0: pred = 0
                            case 1: pred = left
                            case 2: pred = up
                            case 3: pred = (left + up) >> 1
                            default: pred = Int(paeth(left, up, ul))
                            }
                            let diff = UInt8(truncatingIfNeeded: cur - pred)
                            candidate[x] = diff
                            score += abs(Int(Int8(bitPattern: diff)))
                        }
                        if score < bestScore {
                            bestScore = score
                            bestFilter = kind
                            bestRow = candidate
                        }
                    }
                    let out = y * (width + 1)
                    dst[out] = bestFilter
                    for x in 0..<width { dst[out + 1 + x] = bestRow[x] }
                }
            }
        }
        return filtered
    }

    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> UInt8 {
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        if pa <= pb && pa <= pc { return UInt8(truncatingIfNeeded: a) }
        if pb <= pc { return UInt8(truncatingIfNeeded: b) }
        return UInt8(truncatingIfNeeded: c)
    }

    private static func unfilter(_ inflated: Data, height: Int, row: Int, bpp: Int) throws -> Data {
        var samples = Data(count: height * row)
        try inflated.withUnsafeBytes { srcRaw in
            try samples.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                      let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                for y in 0..<height {
                    let filter = src[y * (row + 1)]
                    let inRow = src.advanced(by: y * (row + 1) + 1)
                    let out = dst.advanced(by: y * row)
                    let prev = y > 0 ? dst.advanced(by: (y - 1) * row) : nil
                    for x in 0..<row {
                        let left = x >= bpp ? Int(out[x - bpp]) : 0
                        let up = prev.map { Int($0[x]) } ?? 0
                        let ul = prev.flatMap { p in x >= bpp ? Int(p[x - bpp]) : 0 } ?? 0
                        let value = Int(inRow[x])
                        let pred: Int
                        switch filter {
                        case 0: pred = 0
                        case 1: pred = left
                        case 2: pred = up
                        case 3: pred = (left + up) >> 1
                        case 4: pred = Int(paeth(left, up, ul))
                        default: throw JobError.unreadable("bad png filter")
                        }
                        out[x] = UInt8(truncatingIfNeeded: value + pred)
                    }
                }
            }
        }
        return samples
    }

    // MARK: - Canonical pixels

    static func canonical(_ file: PNGFile) throws -> Data {
        guard file.interlace == 0 else { throw JobError.verificationFailed("interlaced png") }
        let pixels = try WorkingMemory.count(file.width, file.height)
        if file.bitDepth == 16 {
            let bytes = try WorkingMemory.count(pixels, 8)
            guard WorkingMemory.fits(bytes) else {
                throw JobError.codec("image exceeds the working-memory budget")
            }
            var rgba = Data(count: bytes)
            try fill16(&rgba, file)
            return rgba
        }
        guard file.bitDepth == 8 || file.colorType == 0 || file.colorType == 3 else {
            throw JobError.verificationFailed("unsupported png depth")
        }
        let bytes = try WorkingMemory.count(pixels, 4)
        guard WorkingMemory.fits(bytes) else {
            throw JobError.codec("image exceeds the working-memory budget")
        }
        var rgba = Data(count: bytes)
        try fill8(&rgba, file)
        return rgba
    }

    private static func fill8(_ rgba: inout Data, _ file: PNGFile) throws {
        let palette = file.chunk("PLTE")?.data ?? Data()
        let trns = file.chunk("tRNS")?.data ?? Data()
        try rgba.withUnsafeMutableBytes { dstRaw in
            try file.samples.withUnsafeBytes { srcRaw in
                guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                let row = file.bytesPerRow
                for y in 0..<file.height {
                    for x in 0..<file.width {
                        let d = dst.advanced(by: (y * file.width + x) * 4)
                        switch file.colorType {
                        case 2:
                            let s = src.advanced(by: y * row + x * 3)
                            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]
                            if let key = truecolorKey(file), s[0] == key.r, s[1] == key.g, s[2] == key.b {
                                d[3] = 0
                            } else {
                                d[3] = 255
                            }
                        case 6:
                            let s = src.advanced(by: y * row + x * 4)
                            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]
                        case 0:
                            let raw = try packed(src, y: y, x: x, row: row, bitDepth: file.bitDepth, width: file.width)
                            let value = scaleGray(raw, bitDepth: file.bitDepth)
                            d[0] = value; d[1] = value; d[2] = value
                            if let key = grayKey(file), raw == key {
                                d[3] = 0
                            } else {
                                d[3] = 255
                            }
                        case 3:
                            let index = try packed(src, y: y, x: x, row: row, bitDepth: file.bitDepth, width: file.width)
                            let o = index * 3
                            guard o + 2 < palette.count else { throw JobError.verificationFailed("palette index") }
                            d[0] = palette[o]; d[1] = palette[o + 1]; d[2] = palette[o + 2]
                            d[3] = index < trns.count ? trns[index] : 255
                        case 4:
                            let s = src.advanced(by: y * row + x * 2)
                            d[0] = s[0]; d[1] = s[0]; d[2] = s[0]; d[3] = s[1]
                        default:
                            throw JobError.verificationFailed("png color type")
                        }
                    }
                }
            }
        }
    }

    private static func fill16(_ rgba: inout Data, _ file: PNGFile) throws {
        guard file.bitDepth == 16 else { return }
        try rgba.withUnsafeMutableBytes { dstRaw in
            try file.samples.withUnsafeBytes { srcRaw in
                guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                let channels = samplesPerPixel(file.colorType)
                for i in 0..<(file.width * file.height) {
                    let s = src.advanced(by: i * channels * 2)
                    let d = dst.advanced(by: i * 8)
                    switch file.colorType {
                    case 0:
                        d[0] = s[0]; d[1] = s[1]
                        d[2] = s[0]; d[3] = s[1]
                        d[4] = s[0]; d[5] = s[1]
                        let sample = (UInt16(s[0]) << 8) | UInt16(s[1])
                        if let key = grayKey16(file), sample == key {
                            d[6] = 0; d[7] = 0
                        } else {
                            d[6] = 255; d[7] = 255
                        }
                    case 2:
                        d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]; d[4] = s[4]; d[5] = s[5]
                        let red = (UInt16(s[0]) << 8) | UInt16(s[1])
                        let green = (UInt16(s[2]) << 8) | UInt16(s[3])
                        let blue = (UInt16(s[4]) << 8) | UInt16(s[5])
                        if let key = truecolorKey16(file), red == key.r, green == key.g, blue == key.b {
                            d[6] = 0; d[7] = 0
                        } else {
                            d[6] = 255; d[7] = 255
                        }
                    case 4:
                        d[0] = s[0]; d[1] = s[1]; d[2] = s[0]; d[3] = s[1]; d[4] = s[0]; d[5] = s[1]
                        d[6] = s[2]; d[7] = s[3]
                    case 6:
                        for b in 0..<8 { d[b] = s[b] }
                    default:
                        throw JobError.verificationFailed("png color type")
                    }
                }
            }
        }
    }

    /// Raw packed sample. Indexed colour must keep this index; gray scales it separately.
    private static func packed(
        _ src: UnsafePointer<UInt8>, y: Int, x: Int, row: Int, bitDepth: Int, width: Int
    ) throws -> Int {
        _ = width
        if bitDepth == 8 { return Int(src[y * row + x]) }
        if bitDepth == 16 {
            let o = y * row + x * 2
            return (Int(src[o]) << 8) | Int(src[o + 1])
        }
        guard bitDepth == 1 || bitDepth == 2 || bitDepth == 4 else {
            throw JobError.verificationFailed("unsupported png depth")
        }
        let bitIndex = x * bitDepth
        let byte = src[y * row + bitIndex / 8]
        let shift = 8 - bitDepth - (bitIndex % 8)
        let mask = (1 << bitDepth) - 1
        return (Int(byte) >> shift) & mask
    }

    private static func scaleGray(_ value: Int, bitDepth: Int) -> UInt8 {
        if bitDepth >= 8 { return UInt8(truncatingIfNeeded: value) }
        let mask = (1 << bitDepth) - 1
        return UInt8((value * 255) / mask)
    }

    /// Colour type 2 tRNS is 6 bytes, RRGGBB. Depths below 16 store the key in the low byte.
    private static func truecolorKey(_ file: PNGFile) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard file.colorType == 2, let data = file.chunk("tRNS")?.data, data.count >= 6 else { return nil }
        return (data[1], data[3], data[5])
    }

    private static func truecolorKey16(_ file: PNGFile) -> (r: UInt16, g: UInt16, b: UInt16)? {
        guard file.colorType == 2, let data = file.chunk("tRNS")?.data, data.count >= 6 else { return nil }
        return (
            UInt16(data[0]) << 8 | UInt16(data[1]),
            UInt16(data[2]) << 8 | UInt16(data[3]),
            UInt16(data[4]) << 8 | UInt16(data[5]))
    }

    /// Colour type 0 tRNS is 2 bytes. Depths below 16 compare the raw packed value to the low byte.
    private static func grayKey(_ file: PNGFile) -> Int? {
        guard file.colorType == 0, let data = file.chunk("tRNS")?.data, data.count >= 2 else { return nil }
        return Int(data[1])
    }

    private static func grayKey16(_ file: PNGFile) -> UInt16? {
        guard file.colorType == 0, let data = file.chunk("tRNS")?.data, data.count >= 2 else { return nil }
        return UInt16(data[0]) << 8 | UInt16(data[1])
    }

    // MARK: - Assembly

    private static func spliceIDAT(_ file: PNGFile, compressed: Data) -> Data {
        var out = signature
        var inserted = false
        for chunk in file.chunks {
            if chunk.type == "IHDR" {
                out.append(chunkBytes(ihdr(file)))
                continue
            }
            if chunk.type == "IDAT" { continue }
            if chunk.type == "IEND" {
                if !inserted {
                    out.append(chunkBytes(PNGChunk(type: "IDAT", data: compressed)))
                    inserted = true
                }
                out.append(chunkBytes(chunk))
                continue
            }
            out.append(chunkBytes(chunk))
        }
        return out
    }

    /// iCCP, sRGB, cHRM, gAMA, sBIT and cICP must precede PLTE. pHYs may follow it.
    private static let beforePLTE: Set<String> = ["cICP", "iCCP", "sRGB", "cHRM", "gAMA", "sBIT"]

    private static func ordered(_ chunks: [PNGChunk]) -> [PNGChunk] {
        var early: [PNGChunk] = []
        var plte: [PNGChunk] = []
        var trns: [PNGChunk] = []
        var rest: [PNGChunk] = []
        for chunk in chunks {
            switch chunk.type {
            case "IHDR", "IDAT", "IEND":
                continue
            case "PLTE":
                plte.append(chunk)
            case "tRNS":
                trns.append(chunk)
            default:
                if beforePLTE.contains(chunk.type) { early.append(chunk) }
                else { rest.append(chunk) }
            }
        }
        return early + plte + trns + rest
    }

    private static func rebuild(_ file: PNGFile, compressed: Data, stripSmartText: Bool) -> Data {
        let drop: Set<String> = ["IHDR", "IDAT", "IEND", "bKGD", "hIST"]
        let smartDrop: Set<String> = ["tEXt", "zTXt", "iTXt", "tIME", "eXIf"]
        var body: [PNGChunk] = []
        for chunk in file.chunks where !drop.contains(chunk.type) {
            if stripSmartText && smartDrop.contains(chunk.type) { continue }
            body.append(chunk)
        }
        var chunks = [ihdr(file)]
        chunks.append(contentsOf: ordered(body))
        chunks.append(PNGChunk(type: "IDAT", data: compressed))
        chunks.append(PNGChunk(type: "IEND", data: Data()))
        return assemble(chunks)
    }

    private static func ihdr(_ file: PNGFile) -> PNGChunk {
        var data = Data(count: 13)
        writeU32(&data, 0, UInt32(file.width))
        writeU32(&data, 4, UInt32(file.height))
        data[8] = UInt8(file.bitDepth)
        data[9] = UInt8(file.colorType)
        data[12] = UInt8(file.interlace)
        return PNGChunk(type: "IHDR", data: data)
    }

    private static func assemble(_ chunks: [PNGChunk]) -> Data {
        var out = signature
        for chunk in chunks { out.append(chunkBytes(chunk)) }
        return out
    }

    private static func chunkBytes(_ chunk: PNGChunk) -> Data {
        var out = Data()
        var length = UInt32(chunk.data.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        let type = Array(chunk.type.utf8)
        out.append(contentsOf: type)
        out.append(chunk.data)
        var crc = type.withUnsafeBytes { raw in
            libdeflate_crc32(0, raw.baseAddress, type.count)
        }
        if !chunk.data.isEmpty {
            crc = chunk.data.withUnsafeBytes { raw in
                libdeflate_crc32(crc, raw.baseAddress, chunk.data.count)
            }
        }
        var be = crc.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        return out
    }

    private static func samplesPerPixel(_ colorType: Int) -> Int {
        switch colorType {
        case 0: 1
        case 2: 3
        case 3: 1
        case 4: 2
        case 6: 4
        default: 1
        }
    }

    private static func filterBPP(bitDepth: Int, colorType: Int) -> Int {
        max(1, (samplesPerPixel(colorType) * bitDepth + 7) / 8)
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func writeU32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        data[offset] = UInt8((value >> 24) & 0xff)
        data[offset + 1] = UInt8((value >> 16) & 0xff)
        data[offset + 2] = UInt8((value >> 8) & 0xff)
        data[offset + 3] = UInt8(value & 0xff)
    }
}
