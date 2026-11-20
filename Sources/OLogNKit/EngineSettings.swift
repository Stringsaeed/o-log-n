import Darwin
import Foundation

public struct EngineSettings: Sendable, Codable, Equatable {
    public var quality: QualityPreset = .balanced
    public var archiveFormat: ArchiveFormat = .xz
    public var imageConversion: ImageConversion = .keep
    public var output: OutputLocation = .nextToOriginal
    public var suffix: String = "-min"
    public var stripMetadataInSmart: Bool = true
    public var preserveDates: Bool = true
    public var maxCPUJobs: Int? = nil
    /// Lossless-mode JPEG style. `.pixelExact` keeps the scan type (identical pixels everywhere);
    /// `.progressive` re-scans progressively (identical DCT coefficients, bigger gain, but some
    /// decoders — ImageIO included — render it very slightly differently). User decision 2026-11-19.
    public var jpegLossless: JPEGLosslessStyle = .pixelExact
    public init() {}
}

public enum JPEGLosslessStyle: String, Sendable, Codable, CaseIterable { case pixelExact, progressive }

enum SystemInfo {
    static var pCoreCount: Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }
}

enum QualityScale {
    /// Slice 1 calibration updates these three together. See architecture.md §9.
    static let ssimCompact = 0.970
    static let ssimBalanced = 0.980
    static let ssimStudio = 0.990
    static let paletteCompact = 0.950
    static let paletteBalanced = 0.970
    static let paletteStudio = 0.980

    static let lossyQualities: [Double] = [0.50, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.88, 0.92]

    static func ssim(_ preset: QualityPreset) -> Double {
        switch preset {
        case .compact: ssimCompact
        case .balanced: ssimBalanced
        case .studio: ssimStudio
        }
    }

    static func palette(_ preset: QualityPreset) -> Double {
        switch preset {
        case .compact: paletteCompact
        case .balanced: paletteBalanced
        case .studio: paletteStudio
        }
    }

    static func video(_ preset: QualityPreset) -> Double {
        switch preset {
        case .compact: 0.55
        case .balanced: 0.65
        case .studio: 0.75
        }
    }

    static func aacBitsPerSecond(channels: Int, preset: QualityPreset) -> Int {
        let stereo: Int
        switch preset {
        case .compact: stereo = 128_000
        case .balanced: stereo = 192_000
        case .studio: stereo = 256_000
        }
        if channels <= 1 { return stereo / 2 }
        return stereo
    }

    static func pdf(_ preset: QualityPreset) -> (dpi: Int, quality: Double) {
        switch preset {
        case .compact: (150, 0.70)
        case .balanced: (220, 0.82)
        case .studio: (300, 0.90)
        }
    }

    static func qTag(_ quality: Double) -> String {
        String(format: "q%.0f", quality * 100)
    }
}
