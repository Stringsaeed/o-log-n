import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OLogNKit

enum Fixtures {
    struct Bundle {
        var directory: URL
        var png: URL
        var jpeg: URL
        var wav: URL
        var text: URL
        var random: URL
        var folder: URL
        var pdf: URL
        var video: URL
        var jpegNamedPNG: URL
    }

    static func make() async throws -> Bundle {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ologn-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = directory.appendingPathComponent("pattern.png")
        let jpeg = directory.appendingPathComponent("photo.jpg")
        let wav = directory.appendingPathComponent("tone.wav")
        let text = directory.appendingPathComponent("notes.txt")
        let random = directory.appendingPathComponent("noise.bin")
        let folder = directory.appendingPathComponent("album", isDirectory: true)
        let pdf = directory.appendingPathComponent("page.pdf")
        let video = directory.appendingPathComponent("clip.mp4")
        let jpegNamedPNG = directory.appendingPathComponent("misnamed.png")
        try writePNG(png, width: 640, height: 360)
        try writeJPEG(jpeg, width: 640, height: 360)
        try writeWAV(wav)
        let prose = String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 4_000)
        try prose.write(to: text, atomically: true, encoding: .utf8)
        try randomBytes(count: 320_000).write(to: random)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filler = String(repeating: "alpha beta gamma delta epsilon\n", count: 800)
        try filler.write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try filler.write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try writePDF(pdf)
        try await writeVideo(video)
        try FileManager.default.copyItem(at: jpeg, to: jpegNamedPNG)
        return Bundle(
            directory: directory, png: png, jpeg: jpeg, wav: wav, text: text, random: random,
            folder: folder, pdf: pdf, video: video, jpegNamedPNG: jpegNamedPNG)
    }

    static func settings(in directory: URL) -> EngineSettings {
        var settings = EngineSettings()
        settings.output = .folder(directory)
        return settings
    }

    static func run(_ url: URL, mode: CompressionMode, settings: EngineSettings) async -> Job {
        let engine = CompressionEngine()
        let id = await engine.submit([url], mode: mode, settings: settings)[0]
        return await engine.waitUntilFinished(id)
    }

    static func hash(_ url: URL) throws -> SHA256Digest {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return try hashTree(url)
        }
        return try FileHash.sha256(url: url)
    }

    /// Stable digest of a directory's regular files. Opening the directory itself is not a file read.
    private static func hashTree(_ root: URL) throws -> SHA256Digest {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { throw TestError("cannot list \(root.path)") }
        var files: [URL] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true { files.append(item) }
        }
        files.sort { $0.path < $1.path }
        var hasher = SHA256()
        for file in files {
            let relative = file.path.dropFirst(root.path.count)
            hasher.update(data: Data(String(relative).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file))
        }
        return hasher.finalize()
    }

    private static func writePNG(_ url: URL, width: Int, height: Int) throws {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8((x / 8) % 20 * 12)
                pixels[i + 1] = UInt8((y / 8) % 20 * 9)
                pixels[i + 2] = 48
            }
        }
        try writeImage(pixels, width: width, height: height, type: .png, url: url, quality: 1)
    }

    private static func writeJPEG(_ url: URL, width: Int, height: Int) throws {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x % 256)
                pixels[i + 1] = UInt8(y % 256)
                pixels[i + 2] = 180
            }
        }
        try writeImage(pixels, width: width, height: height, type: .jpeg, url: url, quality: 0.92)
    }

    private static func writeImage(
        _ pixels: [UInt8], width: Int, height: Int, type: UTType, url: URL, quality: Double
    ) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let data = NSMutableData(bytes: pixels, length: pixels.count)
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw TestError("image") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw TestError("destination")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TestError("finalize") }
    }

    private static func writeWAV(_ url: URL) throws {
        let frames = 48_000
        let channels = 2
        let dataBytes = frames * channels * 2
        var body = Data()
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { body.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { body.append(contentsOf: $0) }
        }
        body.append(contentsOf: "RIFF".utf8)
        u32(UInt32(36 + dataBytes))
        body.append(contentsOf: "WAVEfmt ".utf8)
        u32(16)
        u16(1)
        u16(UInt16(channels))
        u32(48_000)
        u32(48_000 * 4)
        u16(4)
        u16(16)
        body.append(contentsOf: "data".utf8)
        u32(UInt32(dataBytes))
        var samples = Data(count: dataBytes)
        samples.withUnsafeMutableBytes { raw in
            let pointer = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                let sample = Int16(sin(Double(frame) / 48.0) * 12_000)
                pointer[frame * 2] = sample
                pointer[frame * 2 + 1] = sample
            }
        }
        body.append(samples)
        try body.write(to: url)
    }

    private static func writePDF(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 400)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw TestError("pdf") }
        context.beginPDFPage(nil)
        var noise = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for i in 0..<noise.count { noise[i] = UInt8((i * 17) & 255) }
        let data = NSData(bytes: noise, length: noise.count)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let provider = CGDataProvider(data: data),
           let image = CGImage(
            width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            context.draw(image, in: CGRect(x: 40, y: 40, width: 200, height: 200))
        }
        context.endPDFPage()
        context.closePDF()
    }

    private static func writeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640,
            AVVideoHeightKey: 360,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 640,
                kCVPixelBufferHeightKey as String: 360,
            ])
        guard writer.canAdd(input) else { throw TestError("video input") }
        writer.add(input)
        guard writer.startWriting() else { throw TestError(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, nil, &pixel)
            guard let pixel else { throw TestError("pixel") }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                memset(base, Int32(frame & 255), CVPixelBufferGetDataSize(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            let time = CMTime(value: CMTimeValue(frame), timescale: 30)
            if !adaptor.append(pixel, withPresentationTime: time) {
                throw TestError(writer.error?.localizedDescription ?? "append")
            }
        }
        input.markAsFinished()
        // Never block a cooperative thread here: parallel tests would starve the pool and deadlock.
        await writer.finishWriting()
        if writer.status != .completed {
            throw TestError(writer.error?.localizedDescription ?? "video")
        }
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        for index in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        return Data(bytes)
    }
}

struct TestError: Error { var message: String; init(_ message: String) { self.message = message } }

func expectLossless(_ job: Job, original: URL) async throws {
    guard case .finished(let result) = job.state else {
        Issue.record("job did not finish: \(job.state)")
        return
    }
    let before = try Fixtures.hash(original)
    let after = try Fixtures.hash(original)
    #expect(before == after)
    if result.outcome == .compressed {
        #expect(result.outputBytes < result.inputBytes)
        #expect(result.verified)
        #expect(result.outputURL != nil)
        if result.lossless, let output = result.outputURL {
            try await LosslessVerifier.verify(original: original, output: output)
        }
    } else {
        #expect(result.outputURL == nil)
        #expect(result.outputBytes == result.inputBytes)
    }
}
