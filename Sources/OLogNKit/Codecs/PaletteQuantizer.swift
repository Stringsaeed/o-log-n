import Foundation

/// Oklab median-cut (256) with 3 weighted k-means passes and serpentine Floyd–Steinberg.
/// Histogram buckets store the weighted mean of the pixels that landed in them.
enum PaletteQuantizer {
    struct Image: Sendable {
        var indices: Data
        var palette: Data
    }

    static func quantize(
        rgba: Data,
        width: Int,
        height: Int,
        cancel: @escaping @Sendable () -> Bool
    ) -> Image {
        var counts = [Int](repeating: 0, count: 32768)
        var rSum = [Int](repeating: 0, count: 32768)
        var gSum = [Int](repeating: 0, count: 32768)
        var bSum = [Int](repeating: 0, count: 32768)
        rgba.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let pixels = width * height
            for i in 0..<pixels {
                let p = base.advanced(by: i * 4)
                let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                let index = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
                counts[index] += 1
                rSum[index] += r
                gSum[index] += g
                bSum[index] += b
            }
        }
        var entries: [Entry] = []
        entries.reserveCapacity(4096)
        for index in 0..<32768 where counts[index] > 0 {
            let count = counts[index]
            let r = UInt8(rSum[index] / count)
            let g = UInt8(gSum[index] / count)
            let b = UInt8(bSum[index] / count)
            entries.append(Entry(r: r, g: g, b: b, lab: rgbToOklab(r, g, b), weight: count))
        }
        if entries.isEmpty {
            return Image(indices: Data(count: width * height), palette: Data([0, 0, 0]))
        }
        let boxes = medianCut(entries, cancel: cancel)
        var palette = boxes.map { meanRGB($0) }
        refine(&palette, entries: entries)
        let lut = nearestLUT(palette)
        let indices = dither(rgba: rgba, width: width, height: height, palette: palette, lut: lut, cancel: cancel)
        var bytes = Data(count: palette.count * 3)
        for (i, color) in palette.enumerated() {
            bytes[i * 3] = color.0
            bytes[i * 3 + 1] = color.1
            bytes[i * 3 + 2] = color.2
        }
        return Image(indices: indices, palette: bytes)
    }

    private struct Entry {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var lab: Oklab
        var weight: Int
    }

    private struct Oklab {
        var l: Float
        var a: Float
        var b: Float
    }

    private struct Box {
        var items: [Entry]
    }

    private static func medianCut(_ entries: [Entry], cancel: () -> Bool) -> [Box] {
        var boxes = [Box(items: entries)]
        while boxes.count < 256 {
            if boxes.count & 15 == 0, cancel() { break }
            var bestIndex = -1
            var bestScore: Float = -1
            var bestAxis = 0
            for (index, box) in boxes.enumerated() {
                if box.items.count <= 1 { continue }
                var minL: Float = 1e9, maxL: Float = -1e9
                var minA: Float = 1e9, maxA: Float = -1e9
                var minB: Float = 1e9, maxB: Float = -1e9
                var weight = 0
                for entry in box.items {
                    minL = min(minL, entry.lab.l); maxL = max(maxL, entry.lab.l)
                    minA = min(minA, entry.lab.a); maxA = max(maxA, entry.lab.a)
                    minB = min(minB, entry.lab.b); maxB = max(maxB, entry.lab.b)
                    weight += entry.weight
                }
                let dL = maxL - minL, dA = maxA - minA, dB = maxB - minB
                let span = max(dL, max(dA, dB))
                let score = span * sqrt(Float(weight))
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                    bestAxis = (dL >= dA && dL >= dB) ? 0 : ((dA >= dB) ? 1 : 2)
                }
            }
            if bestIndex < 0 { break }
            var items = boxes[bestIndex].items
            items.sort { lhs, rhs in
                switch bestAxis {
                case 0: lhs.lab.l < rhs.lab.l
                case 1: lhs.lab.a < rhs.lab.a
                default: lhs.lab.b < rhs.lab.b
                }
            }
            let total = items.reduce(0) { $0 + $1.weight }
            var accumulated = 0
            var split = items.count / 2
            if split < 1 { split = 1 }
            for i in 0..<(items.count - 1) {
                accumulated += items[i].weight
                if accumulated >= total / 2 {
                    split = max(1, i + 1)
                    break
                }
            }
            if split >= items.count { split = items.count - 1 }
            boxes[bestIndex] = Box(items: Array(items[..<split]))
            boxes.append(Box(items: Array(items[split...])))
        }
        return boxes
    }

    private static func meanRGB(_ box: Box) -> (UInt8, UInt8, UInt8) {
        var r = 0, g = 0, b = 0, w = 0
        for entry in box.items {
            r += Int(entry.r) * entry.weight
            g += Int(entry.g) * entry.weight
            b += Int(entry.b) * entry.weight
            w += entry.weight
        }
        let weight = max(1, w)
        return (UInt8(r / weight), UInt8(g / weight), UInt8(b / weight))
    }

    private static func refine(_ palette: inout [(UInt8, UInt8, UInt8)], entries: [Entry]) {
        let count = palette.count
        guard count > 1 else { return }
        for _ in 0..<3 {
            var sumR = [Int](repeating: 0, count: count)
            var sumG = [Int](repeating: 0, count: count)
            var sumB = [Int](repeating: 0, count: count)
            var sumW = [Int](repeating: 0, count: count)
            let labs = palette.map { rgbToOklab($0.0, $0.1, $0.2) }
            for entry in entries {
                var best = 0
                var bestDistance: Float = 1e9
                for color in 0..<count {
                    let distance = dist2(entry.lab, labs[color])
                    if distance < bestDistance {
                        bestDistance = distance
                        best = color
                    }
                }
                sumR[best] += Int(entry.r) * entry.weight
                sumG[best] += Int(entry.g) * entry.weight
                sumB[best] += Int(entry.b) * entry.weight
                sumW[best] += entry.weight
            }
            for color in 0..<count where sumW[color] > 0 {
                palette[color] = (
                    UInt8(sumR[color] / sumW[color]),
                    UInt8(sumG[color] / sumW[color]),
                    UInt8(sumB[color] / sumW[color]))
            }
        }
    }

    private static func nearestLUT(_ palette: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        let labs = palette.map { rgbToOklab($0.0, $0.1, $0.2) }
        var lut = [UInt8](repeating: 0, count: 32768)
        for index in 0..<32768 {
            let r = UInt8(((index >> 10) & 31) * 255 / 31)
            let g = UInt8(((index >> 5) & 31) * 255 / 31)
            let b = UInt8((index & 31) * 255 / 31)
            let lab = rgbToOklab(r, g, b)
            var best = 0
            var bestDistance: Float = 1e9
            for color in 0..<palette.count {
                let distance = dist2(lab, labs[color])
                if distance < bestDistance {
                    bestDistance = distance
                    best = color
                }
            }
            lut[index] = UInt8(best)
        }
        return lut
    }

    private static func dither(
        rgba: Data,
        width: Int,
        height: Int,
        palette: [(UInt8, UInt8, UInt8)],
        lut: [UInt8],
        cancel: () -> Bool
    ) -> Data {
        var indices = Data(count: width * height)
        var errCur = [Float](repeating: 0, count: (width + 2) * 3)
        var errNext = [Float](repeating: 0, count: (width + 2) * 3)
        rgba.withUnsafeBytes { raw in
            guard let pixels = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            indices.withUnsafeMutableBytes { idxRaw in
                guard let out = idxRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                for y in 0..<height {
                    if y & 31 == 0, cancel() { return }
                    errNext.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
                    let forward = y % 2 == 0
                    let range: AnySequence<Int> = forward ? AnySequence(0..<width) : AnySequence(stride(from: width - 1, through: 0, by: -1))
                    let direction = forward ? 1 : -1
                    for x in range {
                        let source = pixels.advanced(by: (y * width + x) * 4)
                        let leftSame = x > 0 && same(pixels.advanced(by: (y * width + x - 1) * 4), source)
                        let upSame = y > 0 && same(pixels.advanced(by: ((y - 1) * width + x) * 4), source)
                        let flat = (x > 0 || y > 0) && (x == 0 || leftSame) && (y == 0 || upSame)
                        let e = (x + 1) * 3
                        let r: Int
                        let g: Int
                        let b: Int
                        if flat {
                            r = Int(source[0]); g = Int(source[1]); b = Int(source[2])
                        } else {
                            r = clamp(Float(source[0]) + errCur[e] * 0.7)
                            g = clamp(Float(source[1]) + errCur[e + 1] * 0.7)
                            b = clamp(Float(source[2]) + errCur[e + 2] * 0.7)
                        }
                        let bucket = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
                        let chosen = Int(lut[bucket])
                        out[y * width + x] = UInt8(chosen)
                        if flat { continue }
                        let color = palette[chosen]
                        let er = Float(r) - Float(color.0)
                        let eg = Float(g) - Float(color.1)
                        let eb = Float(b) - Float(color.2)
                        add(&errCur, (x + 1 + direction) * 3, er, eg, eb, 7.0 / 16.0)
                        add(&errNext, (x + 1 - direction) * 3, er, eg, eb, 3.0 / 16.0)
                        add(&errNext, (x + 1) * 3, er, eg, eb, 5.0 / 16.0)
                        add(&errNext, (x + 1 + direction) * 3, er, eg, eb, 1.0 / 16.0)
                    }
                    swap(&errCur, &errNext)
                }
            }
        }
        return indices
    }

    private static func same(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>) -> Bool {
        a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3]
    }

    private static func clamp(_ value: Float) -> Int {
        Int(max(0, min(255, value)))
    }

    private static func add(_ buffer: inout [Float], _ index: Int, _ r: Float, _ g: Float, _ b: Float, _ weight: Float) {
        guard index >= 0, index + 2 < buffer.count else { return }
        buffer[index] += r * weight
        buffer[index + 1] += g * weight
        buffer[index + 2] += b * weight
    }

    private static func dist2(_ lhs: Oklab, _ rhs: Oklab) -> Float {
        let dl = lhs.l - rhs.l
        let da = lhs.a - rhs.a
        let db = lhs.b - rhs.b
        return dl * dl + da * da + db * db
    }

    private static func srgbToLinear(_ channel: UInt8) -> Float {
        let value = Float(channel) / 255
        if value <= 0.04045 { return value / 12.92 }
        return powf((value + 0.055) / 1.055, 2.4)
    }

    private static func rgbToOklab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Oklab {
        let lr = srgbToLinear(r)
        let lg = srgbToLinear(g)
        let lb = srgbToLinear(b)
        let l = cbrtf(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrtf(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrtf(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return Oklab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}
