import CoreGraphics
import Foundation
import ImageIO

struct ImageBuffer: Sendable, Equatable {
    var width: Int
    var height: Int
    /// Row-major sRGB, 8-bit, premultiplied-last RGBA. Both sides of a comparison use this layout.
    var rgba: Data
}

enum ImagePixels {
    static func buffer(url: URL) -> ImageBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return buffer(source: source)
    }

    static func buffer(data: Data) -> ImageBuffer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return buffer(source: source)
    }

    static func buffer(cgImage: CGImage) -> ImageBuffer? {
        draw(cgImage)
    }

    private static func buffer(source: CGImageSource) -> ImageBuffer? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxSide = max(pixelWidth, pixelHeight, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        guard let image else { return nil }
        return draw(image)
    }

    private static func draw(_ image: CGImage) -> ImageBuffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        guard WorkingMemory.fits(width: width, height: height, bytesPerPixel: 4) else { return nil }
        var rgba = Data(count: width * height * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return ImageBuffer(width: width, height: height, rgba: rgba)
    }
}

enum SSIM {
    /// Mean SSIM over full 8×8 luma windows, step 4. Unbiased (N−1) variance.
    static func mean(_ left: ImageBuffer, _ right: ImageBuffer) -> Double {
        guard left.width == right.width, left.height == right.height, left.width >= 8, left.height >= 8 else {
            return left.rgba == right.rgba && left.width == right.width ? 1 : 0
        }
        let width = left.width
        let height = left.height
        let stride = width + 1
        // Nine integral rows. Row r and row r−8 stay in distinct slots, so each window sees the
        // same recurrence as a full integral image and only O(width) doubles are stored.
        let slots = 9
        guard let cells = try? WorkingMemory.count(stride, slots),
              let bytes = try? WorkingMemory.count(cells, slots == 0 ? 0 : MemoryLayout<Double>.size * 5),
              WorkingMemory.fits(bytes)
        else { return 0 }
        var sumA = [Double](repeating: 0, count: cells)
        var sumB = [Double](repeating: 0, count: cells)
        var sumAA = [Double](repeating: 0, count: cells)
        var sumBB = [Double](repeating: 0, count: cells)
        var sumAB = [Double](repeating: 0, count: cells)

        let c1 = (0.01 * 255) * (0.01 * 255)
        let c2 = (0.03 * 255) * (0.03 * 255)
        let n = 64.0
        let n1 = 63.0
        var total = 0.0
        var windows = 0

        let scored: Double? = left.rgba.withUnsafeBytes { leftRaw in
            right.rgba.withUnsafeBytes { rightRaw in
                let leftBytes = leftRaw.bindMemory(to: UInt8.self)
                let rightBytes = rightRaw.bindMemory(to: UInt8.self)
                guard leftBytes.count >= width * height * 4, rightBytes.count >= width * height * 4 else { return nil }
                for y in 0..<height {
                    let row = y + 1
                    let slot = row % slots
                    let prev = (row - 1) % slots
                    for x in 0..<width {
                        let a = luma(leftBytes, (y * width + x) * 4)
                        let b = luma(rightBytes, (y * width + x) * 4)
                        let dest = slot * stride + x + 1
                        let leftI = slot * stride + x
                        let up = prev * stride + x + 1
                        let diag = prev * stride + x
                        sumA[dest] = a + sumA[leftI] + sumA[up] - sumA[diag]
                        sumB[dest] = b + sumB[leftI] + sumB[up] - sumB[diag]
                        sumAA[dest] = a * a + sumAA[leftI] + sumAA[up] - sumAA[diag]
                        sumBB[dest] = b * b + sumBB[leftI] + sumBB[up] - sumBB[diag]
                        sumAB[dest] = a * b + sumAB[leftI] + sumAB[up] - sumAB[diag]
                    }
                    guard row >= 8, (row - 8) % 4 == 0, row <= height else { continue }
                    let top = (row - 8) % slots
                    let bot = row % slots
                    var x = 0
                    while x + 8 <= width {
                        let sa = ring(sumA, stride, top, bot, x, 8)
                        let sb = ring(sumB, stride, top, bot, x, 8)
                        let saa = ring(sumAA, stride, top, bot, x, 8)
                        let sbb = ring(sumBB, stride, top, bot, x, 8)
                        let sab = ring(sumAB, stride, top, bot, x, 8)
                        let muA = sa / n
                        let muB = sb / n
                        let varA = (saa - sa * sa / n) / n1
                        let varB = (sbb - sb * sb / n) / n1
                        let cov = (sab - sa * sb / n) / n1
                        let numerator = (2 * muA * muB + c1) * (2 * cov + c2)
                        let denominator = (muA * muA + muB * muB + c1) * (varA + varB + c2)
                        total += denominator == 0 ? 1 : numerator / denominator
                        windows += 1
                        x += 4
                    }
                }
                return 0
            }
        }
        if scored == nil { return 0 }
        guard windows > 0 else { return 0 }
        return total / Double(windows)
    }

    static func mean(reference: ImageBuffer, data: Data) -> Double {
        guard let decoded = ImagePixels.buffer(data: data) else { return 0 }
        return mean(reference, decoded)
    }

    private static func luma(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> Double {
        let r = Float(bytes[offset])
        let g = Float(bytes[offset + 1])
        let b = Float(bytes[offset + 2])
        return Double(0.299 * r + 0.587 * g + 0.114 * b)
    }

    private static func ring(_ integral: [Double], _ stride: Int, _ top: Int, _ bot: Int, _ x: Int, _ w: Int) -> Double {
        let a = integral[bot * stride + (x + w)]
        let b = integral[top * stride + (x + w)]
        let c = integral[bot * stride + x]
        let d = integral[top * stride + x]
        return a - b - c + d
    }
}
