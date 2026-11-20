import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageIOLossy {
    struct Candidate: Sendable {
        var data: Data
        var quality: Double
        var ssim: Double
    }

    /// Lowest ladder quality whose encode meets `threshold`, at most 4 encodes.
    static func search(
        image: CGImage,
        reference: ImageBuffer,
        type: UTType,
        threshold: Double,
        properties: [CFString: Any] = [:],
        cancel: @escaping @Sendable () -> Bool
    ) -> Candidate? {
        let ladder = QualityScale.lossyQualities
        var low = 0
        var high = ladder.count - 1
        var best: Candidate?
        var encodes = 0
        while low <= high && encodes < 4 {
            if cancel() { return best }
            let mid = (low + high) / 2
            encodes += 1
            guard let data = encode(image: image, type: type, quality: ladder[mid], properties: properties) else {
                low = mid + 1
                continue
            }
            let score = SSIM.mean(reference: reference, data: data)
            if score >= threshold {
                best = Candidate(data: data, quality: ladder[mid], ssim: score)
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return best
    }

    static func encode(
        image: CGImage,
        type: UTType,
        quality: Double,
        properties: [CFString: Any] = [:]
    ) -> Data? {
        let storage = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(storage, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = properties
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return storage as Data
    }

    static func encodeFromSource(
        source: CGImageSource,
        type: UTType,
        quality: Double,
        auxiliary: [(CFString, CFDictionary)]
    ) -> Data? {
        let storage = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(storage, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let props = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImageFromSource(destination, source, 0, props)
        for (kind, info) in auxiliary {
            CGImageDestinationAddAuxiliaryDataInfo(destination, kind, info)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return storage as Data
    }

    static func orientedImage(from source: CGImageSource) -> CGImage? {
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
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func auxiliaryTypeList() -> [CFString] {
        [
            kCGImageAuxiliaryDataTypeHDRGainMap,
            kCGImageAuxiliaryDataTypeISOGainMap,
            kCGImageAuxiliaryDataTypeDepth,
            kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
        ]
    }

    static func auxiliary(from source: CGImageSource) -> [(CFString, CFDictionary)] {
        var found: [(CFString, CFDictionary)] = []
        for kind in auxiliaryTypeList() {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kind) {
                found.append((kind, info))
            }
        }
        return found
    }

    static func auxiliaryTypes(in data: Data) -> Set<String> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        var names: Set<String> = []
        for kind in auxiliaryTypeList() {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kind) != nil {
                names.insert(kind as String)
            }
        }
        return names
    }
}
