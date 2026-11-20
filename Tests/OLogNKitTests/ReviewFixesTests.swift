import AVFoundation
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import OLogNKit

private func reviewDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("ologn-review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func reviewContext(_ url: URL, mode: CompressionMode, scratch: URL, bytes: Int64, settings: EngineSettings = EngineSettings()) -> CodecContext {
    CodecContext(
        input: url, inputBytes: bytes, mode: mode, settings: settings, scratch: scratch,
        progress: { _ in }, isCancelled: { false })
}

private func writeReviewImage(_ url: URL, width: Int, height: Int, type: UTType, quality: Double, paint: (Int, Int) -> (UInt8, UInt8, UInt8)) throws {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let rgb = paint(x, y)
            pixels[i] = rgb.0
            pixels[i + 1] = rgb.1
            pixels[i + 2] = rgb.2
        }
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let data = NSMutableData(bytes: pixels, length: pixels.count)
    guard let provider = CGDataProvider(data: data),
          let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { throw TestError("image") }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw TestError("finalize") }
}

private func xattrValue(_ path: String, _ name: String) -> Data? {
    let length = getxattr(path, name, nil, 0, 0, 0)
    guard length > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: length)
    let copied = buffer.withUnsafeMutableBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return getxattr(path, name, base, length, 0, 0)
    }
    guard copied > 0 else { return nil }
    return Data(buffer.prefix(copied))
}

private func pngCRC(_ type: String, _ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    func eat(_ byte: UInt8) {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            let mask: UInt32 = (crc & 1) == 1 ? 0xEDB8_8320 : 0
            crc = (crc >> 1) ^ mask
        }
    }
    for byte in type.utf8 { eat(byte) }
    for byte in data { eat(byte) }
    return crc ^ 0xFFFF_FFFF
}

private func pngChunk(_ type: String, _ data: Data) -> Data {
    var out = Data()
    var length = UInt32(data.count).bigEndian
    withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
    out.append(contentsOf: [UInt8](type.utf8))
    out.append(data)
    var crc = pngCRC(type, data).bigEndian
    withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
    return out
}

private func pngAssemble(_ chunks: [Data]) -> Data {
    var out = Data([137, 80, 78, 71, 13, 10, 26, 10])
    for chunk in chunks { out.append(chunk) }
    return out
}

private func be32(_ value: UInt32) -> Data {
    var be = value.bigEndian
    return withUnsafeBytes(of: &be) { Data($0) }
}

private func ihdr(width: Int, height: Int, depth: UInt8, color: UInt8) -> Data {
    var data = Data(count: 13)
    data.replaceSubrange(0..<4, with: be32(UInt32(width)))
    data.replaceSubrange(4..<8, with: be32(UInt32(height)))
    data[8] = depth
    data[9] = color
    return data
}

private func writeWAV(_ url: URL, rate: Int, channels: Int, frames: [Int16]) throws {
    let dataBytes = frames.count * channels * 2
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
    u32(UInt32(rate))
    u32(UInt32(rate * channels * 2))
    u16(UInt16(channels * 2))
    u16(16)
    body.append(contentsOf: "data".utf8)
    u32(UInt32(dataBytes))
    for sample in frames {
        for _ in 0..<channels {
            var little = sample.littleEndian
            withUnsafeBytes(of: &little) { body.append(contentsOf: $0) }
        }
    }
    try body.write(to: url)
}

private func writeClip(
    _ url: URL, width: Int, height: Int, frames: Int, codec: AVVideoCodecType, fileType: AVFileType,
    transform: CGAffineTransform = .identity, bitrate: Int? = nil, alpha: UInt8 = 255
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    var compression: [String: Any] = [:]
    if let bitrate {
        compression[AVVideoAverageBitRateKey] = bitrate
        compression[AVVideoExpectedSourceFrameRateKey] = 30
        compression[AVVideoMaxKeyFrameIntervalKey] = 30
    }
    var settings: [String: Any] = [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
    if !compression.isEmpty { settings[AVVideoCompressionPropertiesKey] = compression }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    guard writer.canAdd(input) else { throw TestError("video input") }
    writer.add(input)
    guard writer.startWriting() else { throw TestError(writer.error?.localizedDescription ?? "start") }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixel)
        guard let pixel else { throw TestError("pixel") }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            let bytes = CVPixelBufferGetDataSize(pixel)
            let raw = base.assumingMemoryBound(to: UInt8.self)
            var state = UInt64(frame &* 1_103_515_245 &+ 12_345)
            var offset = 0
            while offset + 3 < bytes {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                raw[offset] = UInt8(truncatingIfNeeded: state >> 33)
                raw[offset + 1] = UInt8(truncatingIfNeeded: state >> 41)
                raw[offset + 2] = UInt8(truncatingIfNeeded: state >> 49)
                raw[offset + 3] = alpha
                offset += 4
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let time = CMTime(value: CMTimeValue(frame), timescale: 30)
        if !adaptor.append(pixel, withPresentationTime: time) {
            throw TestError(writer.error?.localizedDescription ?? "append")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw TestError(writer.error?.localizedDescription ?? "video") }
}

private func markerSegment(_ marker: UInt8, _ payload: Data) -> Data {
    var out = Data([0xFF, marker])
    let length = UInt16(payload.count + 2)
    out.append(UInt8(length >> 8))
    out.append(UInt8(length & 0xFF))
    out.append(payload)
    return out
}

@Test func folderDestinationInsideSourceIsRejected() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let album = root.appendingPathComponent("album", isDirectory: true)
    let nested = album.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try String(repeating: "alpha beta gamma\n", count: 40).write(
        to: album.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let link = root.appendingPathComponent("album-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: album)
    let before = try Fixtures.hash(album)
    for destination in [album, nested, link] {
        var settings = EngineSettings()
        settings.output = .folder(destination)
        let job = await Fixtures.run(album, mode: .lossless, settings: settings)
        guard case .failed(let error) = job.state else {
            Issue.record("expected rejection, got \(job.state)")
            continue
        }
        #expect(error == .outputNotWritable("destination is inside the source folder"))
    }
    #expect(try Fixtures.hash(album) == before)
    let outputs = try FileManager.default.contentsOfDirectory(at: album, includingPropertiesForKeys: nil)
    #expect(outputs.allSatisfy { !$0.lastPathComponent.contains(".tar") && $0.pathExtension != "xz" && $0.pathExtension != "zip" })

    let note = root.appendingPathComponent("note.txt")
    try String(repeating: "hello folder boundary\n", count: 300).write(to: note, atomically: true, encoding: .utf8)
    let sibling = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let fileJob = await Fixtures.run(note, mode: .lossless, settings: Fixtures.settings(in: sibling))
    if case .failed(let error) = fileJob.state {
        #expect(error != .outputNotWritable("destination is inside the source folder"))
    }
}

@Test func gainUsesFingerprintSizeWhenSourceShrinksWhileQueued() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let holder = root.appendingPathComponent("holder.txt")
    let victim = root.appendingPathComponent("victim.txt")
    try Data(repeating: 0x61, count: 80_000).write(to: holder)
    try Data(repeating: 0x62, count: 20_000).write(to: victim)
    let release = OSAllocatedUnfairLock(initialState: false)
    let entered = OSAllocatedUnfairLock(initialState: false)
    defer { release.withLock { $0 = true } }
    let engine = CompressionEngine()
    let calls = OSAllocatedUnfairLock(initialState: 0)
    await engine.setPostAcquireHookForTesting {
        let first = calls.withLock { value -> Bool in
            value += 1
            return value == 1
        }
        guard first else { return }
        entered.withLock { $0 = true }
        while !release.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    let holderID = await engine.submit([holder], mode: .lossless, settings: Fixtures.settings(in: out))[0]
    for _ in 0..<200 {
        if entered.withLock({ $0 }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(entered.withLock { $0 })
    let stream = engine.events()
    let victimID = await engine.submit([victim], mode: .lossless, settings: Fixtures.settings(in: out))[0]
    let sawQueuedSize = OSAllocatedUnfairLock(initialState: false)
    let watcher = Task {
        for await event in stream {
            let job: Job
            switch event {
            case .added(let value), .updated(let value): job = value
            default: continue
            }
            if job.id == victimID, job.inputBytes == 20_000 {
                sawQueuedSize.withLock { $0 = true }
                return
            }
        }
    }
    for _ in 0..<200 where !sawQueuedSize.withLock({ $0 }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    watcher.cancel()
    #expect(sawQueuedSize.withLock { $0 })
    try Data("short".utf8).write(to: victim)
    release.withLock { $0 = true }
    let job = await engine.waitUntilFinished(victimID)
    _ = await engine.waitUntilFinished(holderID)
    guard case .finished(let result) = job.state else {
        Issue.record("victim did not finish: \(job.state)")
        return
    }
    #expect(result.inputBytes == 5)
    #expect(result.savedFraction < 0.5)
    let fingerprint = try #require(result.sourceFingerprint)
    #expect(fingerprint.size == 5)
    let again = try await Offload.run { _ in try SourceFingerprint.capture(victim) }
    #expect(fingerprint.fileID == again.fileID)
}

@Test func sourceChangeDuringCompressionFails() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("story.txt")
    try String(repeating: "the quick brown fox\n", count: 2_000).write(to: source, atomically: true, encoding: .utf8)
    let engine = CompressionEngine()
    await engine.setScratchHookForTesting { _ in
        try? Data(repeating: 0x63, count: 32).write(to: source)
    }
    let id = await engine.submit([source], mode: .lossless, settings: Fixtures.settings(in: out))[0]
    let job = await engine.waitUntilFinished(id)
    #expect(job.state == .failed(.unreadable("source changed during compression")))
}

@Test func smartPNGKeepsTRNSTransparency() async throws {
    let width = 8
    let height = 4
    var rows = Data(count: height * (1 + width * 3))
    for y in 0..<height {
        let start = y * (1 + width * 3)
        rows[start] = 0
        for x in 0..<width {
            let o = start + 1 + x * 3
            if x == 1 && y == 1 {
                rows[o] = 1; rows[o + 1] = 2; rows[o + 2] = 3
            } else {
                rows[o] = 9; rows[o + 1] = 9; rows[o + 2] = 9
            }
        }
    }
    let png = pngAssemble([
        pngChunk("IHDR", ihdr(width: width, height: height, depth: 8, color: 2)),
        pngChunk("tRNS", Data([0, 1, 0, 2, 0, 3])),
        pngChunk("IDAT", try Zlib.compress(rows, level: 6)),
        pngChunk("IEND", Data()),
    ])
    let file = try PNGFormat.parse(png)
    let rgba = try #require(PNGFormat.straightRGBA(file))
    #expect(!PNGFormat.isFullyOpaque(rgba))
    let key = (1 * width + 1) * 4
    #expect(rgba[key] == 1 && rgba[key + 1] == 2 && rgba[key + 2] == 3 && rgba[key + 3] == 0)
    var opaque = rgba
    opaque[key + 3] = 255
    #expect(PNGFormat.maxAlphaDelta(rgba, opaque) == 255)

    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("key.png")
    try png.write(to: source)
    let scratch = root.appendingPathComponent("scratch", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let outcome = try await PNGCodec().compress(reviewContext(source, mode: .smart, scratch: scratch, bytes: Int64(png.count)))
    if case .produced(let temp, _, let method, _, _) = outcome {
        let produced = try PNGFormat.canonical(try PNGFormat.parse(Data(contentsOf: temp)))
        #expect(produced[key + 3] == 0)
        if method.contains("palette") { #expect(produced[key + 3] == 0) }
    }
}

@Test func smartVideoSkipsProRes4444Alpha() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clip = root.appendingPathComponent("alpha.mov")
    try await writeClip(clip, width: 64, height: 64, frames: 6, codec: .proRes4444, fileType: .mov, alpha: 80)
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let job = await Fixtures.run(clip, mode: .smart, settings: Fixtures.settings(in: out))
    guard case .finished(let result) = job.state else {
        Issue.record("alpha clip did not finish: \(job.state)")
        return
    }
    #expect(result.outcome == .alreadyOptimal)
    #expect(result.note == "alpha channel")
    #expect(result.outputURL == nil)
}

@Test func quarantineXattrSurvivesReadOnlyJPEG() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("shot.jpg")
    try writeReviewImage(source, width: 640, height: 360, type: .jpeg, quality: 0.92) { x, y in
        (UInt8(x % 256), UInt8(y % 256), 180)
    }
    let payload = Data("0083;00000000;Safari;OLogN".utf8)
    let set = payload.withUnsafeBytes { raw -> Int32 in
        guard let base = raw.baseAddress else { return -1 }
        return setxattr(source.path, "com.apple.quarantine", base, payload.count, 0, 0)
    }
    #expect(set == 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let job = await Fixtures.run(source, mode: .lossless, settings: Fixtures.settings(in: out))
    guard case .finished(let result) = job.state, let output = result.outputURL else {
        Issue.record("read-only jpeg did not publish: \(job.state)")
        return
    }
    #expect(xattrValue(output.path, "com.apple.quarantine") == payload)
    let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
    #expect((mode?.intValue ?? 0) & 0o222 == 0)
}

@Test func jpegTranscodeSurvivesCorruptInput() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("wide.jpg")
    try writeReviewImage(source, width: 1200, height: 800, type: .jpeg, quality: 0.9) { x, y in
        (UInt8((x / 3) % 256), UInt8((y / 3) % 256), UInt8((x + y) % 256))
    }
    let data = try Data(contentsOf: source)
    #expect(data.count > 70_000)
    let transcoded = try JPEGBridge.transcode(data, progressive: -1, markers: 2)
    #expect(transcoded.count > 65_536)
    #expect(JPEGBridge.coefficientsEqual(data, transcoded))
    let truncated = Data(data.prefix(120))
    do {
        _ = try JPEGBridge.transcode(truncated, progressive: 1, markers: 2)
        Issue.record("truncated jpeg transcoded")
    } catch let error as JobError {
        if case .codec = error {} else { Issue.record("unexpected \(error)") }
    }
}

@Test func hostilePNGDimensionsDoNotAllocate() throws {
    let png = pngAssemble([
        pngChunk("IHDR", ihdr(width: 1_000_000, height: 1_000_000, depth: 8, color: 2)),
        pngChunk("IDAT", Data([0, 1, 2, 3])),
        pngChunk("IEND", Data()),
    ])
    do {
        _ = try PNGFormat.parse(png)
        Issue.record("huge png parsed")
    } catch let error as JobError {
        #expect(error == .codec("image exceeds the working-memory budget"))
    }
    #expect(WorkingMemory.fits(width: 20_000, height: 20_000, bytesPerPixel: 4) == false)
    #expect(WorkingMemory.fits(width: 20_000, height: 20_000, bytesPerPixel: 1) == true)
    let oversized = PNGFile(
        width: 20_000, height: 20_000, bitDepth: 8, colorType: 2, interlace: 0,
        chunks: [], samples: Data(), bytesPerRow: 60_000, filterBPP: 3)
    #expect(PNGFormat.straightRGBA(oversized) == nil)
}

@Test func ssimRollingMatchesIdenticalImage() {
    let side = 16
    let rgba = Data(repeating: 40, count: side * side * 4)
    let image = ImageBuffer(width: side, height: side, rgba: rgba)
    #expect(SSIM.mean(image, image) == 1)
    var changed = rgba
    changed[0] = 0
    let other = ImageBuffer(width: side, height: side, rgba: changed)
    #expect(SSIM.mean(image, other) < 1)
    let tiny = ImageBuffer(width: 4, height: 4, rgba: Data(repeating: 7, count: 64))
    #expect(SSIM.mean(tiny, tiny) == 1)
}

@Test func diskFullPauseHoldsTheNextWaiterUntilResume() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("a.txt")
    let second = root.appendingPathComponent("b.txt")
    try String(repeating: "disk full pause probe\n", count: 2_000).write(to: first, atomically: true, encoding: .utf8)
    try String(repeating: "disk full pause probe\n", count: 2_000).write(to: second, atomically: true, encoding: .utf8)
    let engine = CompressionEngine()
    let hits = OSAllocatedUnfairLock(initialState: 0)
    await engine.setPostAcquireHookForTesting {
        let count = hits.withLock { value -> Int in
            value += 1
            return value
        }
        if count == 1 { throw JobError.diskFull }
    }
    let ids = await engine.submit([first, second], mode: .lossless, settings: Fixtures.settings(in: out))
    // Either job may win the wide lane first, so find whichever one hit disk-full rather than assuming ids[0].
    var failedID: JobID?
    var heldID: JobID?
    for _ in 0..<250 {
        let jobs = await engine.jobs()
        if let failed = jobs.first(where: { $0.state == .failed(.diskFull) }) {
            failedID = failed.id
            if let other = jobs.first(where: { $0.id != failed.id }), case .queued = other.state, other.inputBytes > 0 {
                heldID = other.id
                break
            }
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    let failed = try #require(failedID, "one job should fail with disk-full")
    let held = try #require(heldID, "the other job should stay queued while paused")
    #expect(Set([failed, held]) == Set(ids))
    // While paused, the held job must not start, even after its lane frees up.
    try await Task.sleep(for: .milliseconds(150))
    let stillQueued = await engine.jobs().first(where: { $0.id == held })
    if case .queued = stillQueued?.state {} else { Issue.record("held job left .queued while paused: \(String(describing: stillQueued?.state))") }
    await engine.resume()
    let finished = await engine.waitUntilFinished(held)
    #expect(finished.state.isTerminal)
    if case .failed(let error) = finished.state { #expect(error != .diskFull) }
}

@Test func underlyingENOSPCMapsToDiskFull() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix])
    #expect(FailureMap.jobError(wrapped) == .diskFull)
    let many = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: [posix]])
    #expect(FailureMap.jobError(many) == .diskFull)
    let chain = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
        NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: posix]),
    ])
    #expect(FailureMap.jobError(chain) == .diskFull)
}

@Test func addedPrecedesUpdatedUnderConcurrentSubscribers() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var urls: [URL] = []
    for index in 0..<420 {
        let url = root.appendingPathComponent("item-\(index).zip")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]).write(to: url)
        urls.append(url)
    }
    let engine = CompressionEngine()
    let early = (0..<4).map { _ in engine.events() }
    let ids = await engine.submit(urls, mode: .lossless, settings: Fixtures.settings(in: out))
    let late = engine.events()
    let logs = await withTaskGroup(of: (Int, Bool).self) { group in
        for stream in early + [late] {
            group.addTask { await reviewEventOrder(stream, expected: ids.count) }
        }
        var gathered: [(Int, Bool)] = []
        for await item in group { gathered.append(item) }
        return gathered
    }
    #expect(logs.count == 5)
    #expect(logs.allSatisfy { $0.0 == 0 })
    #expect(logs.contains { $0.1 })
}

private func reviewEventOrder(_ stream: AsyncStream<EngineEvent>, expected: Int) async -> (Int, Bool) {
    var seen = Set<JobID>()
    var bad = 0
    var zeros = Set<JobID>()
    var grew = Set<JobID>()
    var done = Set<JobID>()
    for await event in stream {
        let job: Job
        switch event {
        case .added(let value):
            seen.insert(value.id)
            if value.inputBytes == 0 { zeros.insert(value.id) }
            job = value
        case .updated(let value):
            if !seen.contains(value.id) { bad += 1 }
            seen.insert(value.id)
            if value.inputBytes > 0 { grew.insert(value.id) }
            job = value
        default:
            continue
        }
        if job.state.isTerminal { done.insert(job.id) }
        if done.count >= expected { break }
    }
    return (bad, !zeros.intersection(grew).isEmpty)
}

/// Wall-clock check: process-wide CPU load from other tests running in parallel counts against
/// the 500 ms budget, so CI runs this test in isolation (see .github/workflows/ci.yml).
@Test func losslessJPEGBatchLeavesTheHeartbeatResponsive() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var urls: [URL] = []
    for index in 0..<6 {
        let url = root.appendingPathComponent("frame-\(index).jpg")
        try writeReviewImage(url, width: 160, height: 120, type: .jpeg, quality: 0.9) { x, y in
            (UInt8((x + index) % 256), UInt8(y % 256), 90)
        }
        urls.append(url)
    }
    let zip = root.appendingPathComponent("ready.zip")
    try Data([0x50, 0x4B, 0x03, 0x04]).write(to: zip)
    urls.append(zip)
    let engine = CompressionEngine()
    let clock = ContinuousClock()
    let start = clock.now
    let ids = await engine.submit(urls, mode: .lossless, settings: Fixtures.settings(in: out))
    let zipJob = await engine.waitUntilFinished(ids[ids.count - 1])
    let elapsed = start.duration(to: .now)
    guard case .finished(let result) = zipJob.state else {
        Issue.record("zip did not finish: \(zipJob.state)")
        return
    }
    #expect(result.outcome == .alreadyOptimal)
    #expect(elapsed < .milliseconds(500))
    await engine.cancelAll()
    for id in ids.dropLast() { _ = await engine.waitUntilFinished(id) }
}

@Test func verifyRejectsUnrelatedZipAndEmptyXZ() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = root.appendingPathComponent("notes.txt")
    try Data("hello from the source\n".utf8).write(to: text)
    let other = root.appendingPathComponent("other.txt")
    try Data("completely different bytes\n".utf8).write(to: other)
    let zip = root.appendingPathComponent("other.txt.zip")
    _ = try Command.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", other.path, zip.path])
    do {
        try await LosslessVerifier.verify(original: text, output: zip)
        Issue.record("unrelated zip verified")
    } catch let error as JobError {
        #expect(error == .verificationFailed("zip payload does not match the input"))
    }
    let empty = root.appendingPathComponent("empty.bin")
    try Data().write(to: empty)
    let fake = root.appendingPathComponent("empty.bin.xz")
    try Data().write(to: fake)
    do {
        try await LosslessVerifier.verify(original: empty, output: fake)
        Issue.record("empty xz verified")
    } catch let error as JobError {
        #expect(error == .verificationFailed("xz payload does not match the input"))
    }
    let real = try XZ.encode(data: Data(), cancel: { false }, progress: { _ in })
    let realURL = root.appendingPathComponent("real.bin.xz")
    try real.write(to: realURL)
    let emptyNamed = root.appendingPathComponent("real.bin")
    try Data().write(to: emptyNamed)
    try await LosslessVerifier.verify(original: emptyNamed, output: realURL)

    let folder = root.appendingPathComponent("album", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("one".utf8).write(to: folder.appendingPathComponent("a.txt"))
    let folderZip = root.appendingPathComponent("album.zip")
    _ = try Command.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", folder.path, folderZip.path])
    try await LosslessVerifier.verify(original: folder, output: folderZip)
    try Data("two".utf8).write(to: folder.appendingPathComponent("a.txt"))
    do {
        try await LosslessVerifier.verify(original: folder, output: folderZip)
        Issue.record("changed folder matched the zip")
    } catch is JobError {}
}

@Test func pcmEqualChecksSampleRateAndChannels() throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let samples = (0..<64).map { Int16($0 * 100) }
    let low = root.appendingPathComponent("low.wav")
    let high = root.appendingPathComponent("high.wav")
    try writeWAV(low, rate: 22_050, channels: 1, frames: samples)
    try writeWAV(high, rate: 44_100, channels: 1, frames: samples)
    try AudioVerify.pcmEqual(low, low)
    do {
        try AudioVerify.pcmEqual(low, high)
        Issue.record("mismatched rates compared equal")
    } catch let error as JobError {
        #expect(error == .verificationFailed("pcm does not match"))
    }
}

@Test func cancelDuringCodecIsNotAlreadyOptimal() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("tiny.png")
    try writeReviewImage(source, width: 32, height: 32, type: .png, quality: 1) { x, y in
        (UInt8(x * 8), UInt8(y * 8), 20)
    }
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let engine = CompressionEngine()
    await engine.setAfterCodecHookForTesting { await engine.cancelAll() }
    let id = await engine.submit([source], mode: .smart, settings: Fixtures.settings(in: out))[0]
    let job = await engine.waitUntilFinished(id)
    #expect(job.state == .cancelled)
}

@Test func smartJPEGProgressiveStripsCOMAndKeepsICCAndOrientation() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("marked.jpg")
    try writeReviewImage(source, width: 640, height: 480, type: .jpeg, quality: 0.42) { x, y in
        (UInt8(min(x / 3, 255)), UInt8(min(y / 2, 255)), 40)
    }
    var jpeg = try Data(contentsOf: source)
    #expect(JPEGInspect.parse(jpeg).estimatedQuality <= 72)
    let exif = Data([
        0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
        0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x01,
        0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x06, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])
    var icc = Data("ICC_PROFILE\0".utf8)
    icc.append(contentsOf: [1, 1])
    var app0 = Data("JFIF\0".utf8)
    app0.append(contentsOf: [1, 1, 0, 0, 72, 0, 72, 1, 1, 9, 9, 9])
    let extras = [
        markerSegment(0xE0, app0),
        markerSegment(0xE1, exif),
        markerSegment(0xE2, icc),
        markerSegment(0xED, Data("Photoshop 3.0\0".utf8)),
        markerSegment(0xFE, Data("comment".utf8)),
    ]
    var marked = Data(jpeg.prefix(2))
    for extra in extras { marked.append(extra) }
    if jpeg.count > 2 { marked.append(jpeg.dropFirst(2)) }
    jpeg = marked
    try jpeg.write(to: source)
    #expect(JPEGMarkers.containsCOM(jpeg))
    #expect(JPEGMarkers.orientation(of: jpeg) == 6)
    let sourceThumb = try #require(JPEGMarkers.jfifThumbnailSize(jpeg))
    #expect(sourceThumb.0 == 1 && sourceThumb.1 == 1)
    let scratch = root.appendingPathComponent("scratch", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let outcome = try await JPEGCodec().compress(
        reviewContext(source, mode: .smart, scratch: scratch, bytes: Int64(jpeg.count)))
    guard case .produced(let temp, _, let method, let lossless, _) = outcome else {
        Issue.record("progressive fallback did not produce: \(outcome)")
        return
    }
    #expect(method == "JPEG · progressive")
    #expect(!lossless)
    let output = try Data(contentsOf: temp)
    #expect(!JPEGMarkers.containsCOM(output))
    #expect(JPEGMarkers.containsICC(output))
    #expect(JPEGMarkers.orientation(of: output) == 6)
    let strippedThumb = try #require(JPEGMarkers.jfifThumbnailSize(output))
    #expect(strippedThumb.0 == 0 && strippedThumb.1 == 0)
    #expect(!JPEGMarkers.containsApplication(output, marker: 0xED, prefix: [UInt8]("Photoshop".utf8)))
}

@Test func losslessJPEGKeepsJFIFThumbnail() throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("thumb.jpg")
    try writeReviewImage(source, width: 160, height: 120, type: .jpeg, quality: 0.85) { x, y in
        (UInt8(x % 200), UInt8(y % 180), 40)
    }
    let jpeg = try Data(contentsOf: source)
    guard jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8, jpeg[2] == 0xFF, jpeg[3] == 0xE0 else {
        Issue.record("fixture has no APP0")
        return
    }
    let length = (Int(jpeg[4]) << 8) | Int(jpeg[5])
    var payload = Data(jpeg.subdata(in: 6..<(4 + length)).prefix(14))
    while payload.count < 14 { payload.append(0) }
    payload[12] = 1
    payload[13] = 1
    payload.append(contentsOf: [12, 34, 56])
    var rebuilt = Data([0xFF, 0xD8])
    rebuilt.append(markerSegment(0xE0, payload))
    rebuilt.append(jpeg.dropFirst(4 + length))
    let output = try JPEGBridge.transcode(rebuilt, progressive: -1, markers: 2)
    let keptThumb = try #require(JPEGMarkers.jfifThumbnailSize(output))
    #expect(keptThumb.0 == 1 && keptThumb.1 == 1)
    #expect(JPEGBridge.coefficientsEqual(rebuilt, output))
}

@Test func indexedPNGWritesColorChunksBeforePLTE() throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var iccp = Data("test\0\0".utf8)
    iccp.append(try Zlib.compress(Data("profile".utf8), level: 6))
    let kept = [
        PNGChunk(type: "iCCP", data: iccp),
        PNGChunk(type: "gAMA", data: be32(45455)),
        PNGChunk(type: "sBIT", data: Data([8, 8, 8])),
        PNGChunk(type: "pHYs", data: Data([0, 0, 0x0B, 0x13, 0, 0, 0x0B, 0x13, 1])),
    ]
    let indices = Data([0, 1, 0, 1])
    let palette = Data([255, 0, 0, 0, 255, 0])
    let encoded = try PNGFormat.encodeIndexed(width: 2, height: 2, indices: indices, palette: [UInt8](palette), kept: kept)
    let types = try PNGFormat.parse(encoded).chunks.map(\.type)
    let iccpAt = try #require(types.firstIndex(of: "iCCP"))
    let gamaAt = try #require(types.firstIndex(of: "gAMA"))
    let sbitAt = try #require(types.firstIndex(of: "sBIT"))
    let plteAt = try #require(types.firstIndex(of: "PLTE"))
    let physAt = try #require(types.firstIndex(of: "pHYs"))
    #expect(iccpAt < plteAt && gamaAt < plteAt && sbitAt < plteAt && physAt > plteAt)

    let width = 4
    let height = 4
    var rows = Data(count: height * (1 + width * 3))
    for y in 0..<height {
        rows[y * (1 + width * 3)] = 0
        for x in 0..<width {
            let o = y * (1 + width * 3) + 1 + x * 3
            let on = (x + y) % 2 == 0
            rows[o] = on ? 10 : 200
            rows[o + 1] = on ? 20 : 30
            rows[o + 2] = on ? 30 : 40
        }
    }
    let original = pngAssemble([
        pngChunk("IHDR", ihdr(width: width, height: height, depth: 8, color: 2)),
        pngChunk("iCCP", iccp),
        pngChunk("pHYs", Data([0, 0, 1, 0, 0, 0, 1, 0, 1])),
        pngChunk("IDAT", try Zlib.compress(rows, level: 6)),
        pngChunk("IEND", Data()),
    ])
    let reduced = try PNGFormat.encodeLossless(try PNGFormat.parse(original), allowReductions: true, cancel: { false }).data
    let reducedTypes = try PNGFormat.parse(reduced).chunks.map(\.type)
    #expect(reducedTypes.contains("PLTE"))
    let reducedICC = try #require(reducedTypes.firstIndex(of: "iCCP"))
    let reducedPLTE = try #require(reducedTypes.firstIndex(of: "PLTE"))
    let reducedPHYS = try #require(reducedTypes.firstIndex(of: "pHYs"))
    #expect(reducedICC < reducedPLTE)
    #expect(reducedPHYS > reducedPLTE)
}

@Test func packedPaletteOddWidthsVerify() throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for depth in [1, 2, 4] {
        let width = 65
        let height = 3
        let colors = 1 << depth
        var palette = Data()
        var trns = Data()
        for index in 0..<colors {
            palette.append(UInt8((index * 37) % 256))
            palette.append(UInt8((index * 53 + 20) % 256))
            palette.append(UInt8((index * 17 + 80) % 256))
            trns.append(index == 0 ? 0 : 255)
        }
        let rowBytes = (width * depth + 7) / 8
        var filtered = Data(count: height * (rowBytes + 1))
        var expected = Data(count: width * height * 4)
        for y in 0..<height {
            filtered[y * (rowBytes + 1)] = 0
            for x in 0..<width {
                let index = (x + y) % colors
                let bitIndex = x * depth
                let byteIndex = y * (rowBytes + 1) + 1 + bitIndex / 8
                let shift = 8 - depth - (bitIndex % 8)
                filtered[byteIndex] |= UInt8(index) << shift
                let pixel = (y * width + x) * 4
                expected[pixel] = palette[index * 3]
                expected[pixel + 1] = palette[index * 3 + 1]
                expected[pixel + 2] = palette[index * 3 + 2]
                expected[pixel + 3] = trns[index]
            }
        }
        let png = pngAssemble([
            pngChunk("IHDR", ihdr(width: width, height: height, depth: UInt8(depth), color: 3)),
            pngChunk("PLTE", palette),
            pngChunk("tRNS", trns),
            pngChunk("IDAT", try Zlib.compress(filtered, level: 6)),
            pngChunk("IEND", Data()),
        ])
        let parsed = try PNGFormat.parse(png)
        #expect(try PNGFormat.canonical(parsed) == expected)
        let encoded = try PNGFormat.encodeLossless(parsed, allowReductions: false, cancel: { false }).data
        let src = root.appendingPathComponent("p\(depth).png")
        let dst = root.appendingPathComponent("p\(depth)-out.png")
        try png.write(to: src)
        try encoded.write(to: dst)
        try PNGFormat.verifyPair(src, dst)
    }
}

@Test func portraitVideoIsNotRotatedTwice() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clip = root.appendingPathComponent("portrait.mp4")
    let turn = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    try await writeClip(
        clip, width: 320, height: 240, frames: 30, codec: .h264, fileType: .mp4,
        transform: turn, bitrate: 8_000_000)
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let job = await Fixtures.run(clip, mode: .smart, settings: Fixtures.settings(in: out))
    guard case .finished(let result) = job.state, result.outcome == .compressed, let output = result.outputURL else {
        Issue.record("portrait clip was not compressed: \(job.state)")
        return
    }
    #expect(result.method.hasPrefix("HEVC"))
    let asset = AVURLAsset(url: output)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let display = size.applying(transform)
    #expect(Int(abs(size.width).rounded()) == 320)
    #expect(Int(abs(size.height).rounded()) == 240)
    #expect(Int(abs(display.width).rounded()) == 240)
    #expect(Int(abs(display.height).rounded()) == 320)
}

@Test func waitUntilFinishedReturnsRemovedAndUnknownJobs() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("done.zip")
    try Data([0x50, 0x4B, 0x03, 0x04, 0x00]).write(to: zip)
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let engine = CompressionEngine()
    let id = await engine.submit([zip], mode: .lossless, settings: Fixtures.settings(in: out))[0]
    let finished = await engine.waitUntilFinished(id)
    #expect(finished.state.isTerminal)
    await engine.remove(id)
    let tombstone = await engine.waitUntilFinished(id)
    #expect(tombstone.id == finished.id)
    #expect(tombstone.state == finished.state)
    let unknown = await engine.waitUntilFinished(JobID())
    #expect(unknown.state == .cancelled)
}

@Test func skipGateDoesNotWaitBehindWideLane() async throws {
    let root = try reviewDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let slow = root.appendingPathComponent("slow.txt")
    try String(repeating: "lane holder\n", count: 4_000).write(to: slow, atomically: true, encoding: .utf8)
    let zip = root.appendingPathComponent("skip.zip")
    try Data([0x50, 0x4B, 0x03, 0x04]).write(to: zip)
    let release = OSAllocatedUnfairLock(initialState: false)
    defer { release.withLock { $0 = true } }
    let engine = CompressionEngine()
    let entered = OSAllocatedUnfairLock(initialState: false)
    await engine.setPostAcquireHookForTesting {
        entered.withLock { $0 = true }
        while !release.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    let slowID = await engine.submit([slow], mode: .lossless, settings: Fixtures.settings(in: out))[0]
    for _ in 0..<200 {
        if entered.withLock({ $0 }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(entered.withLock { $0 })
    let zipID = await engine.submit([zip], mode: .lossless, settings: Fixtures.settings(in: out))[0]
    let zipJob = await engine.waitUntilFinished(zipID)
    let slowStillWaiting = await engine.jobs().contains { $0.id == slowID && !$0.state.isTerminal }
    #expect(slowStillWaiting)
    guard case .finished(let result) = zipJob.state else {
        Issue.record("zip did not finish: \(zipJob.state)")
        release.withLock { $0 = true }
        _ = await engine.waitUntilFinished(slowID)
        return
    }
    #expect(result.outcome == .alreadyOptimal)
    #expect(result.duration < 0.25)
    release.withLock { $0 = true }
    _ = await engine.waitUntilFinished(slowID)
}
