import AVFoundation
import CoreMedia
import Foundation
import os
import VideoToolbox

struct VideoCodec: Codec {
    let kind: FileKind = .video
    let lane: Lane = .media

    func compress(_ ctx: CodecContext) async throws -> CodecOutcome {
        if ctx.mode == .lossless { return .skipped("lossless video is not offered") }
        let asset = AVURLAsset(url: ctx.input)
        // `isPlayable` is false for some readable HEVC (`hev1`) files. The contract
        // sends only assets AVFoundation cannot read down the generic path.
        let readable = (try? await asset.load(.isReadable)) ?? false
        guard readable else { return try await GenericCodec().compress(ctx) }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let allTracks = try await asset.load(.tracks)
        guard videoTracks.count == 1, let video = videoTracks.first else {
            return .skipped("video track layout is unsupported")
        }
        for track in allTracks {
            if track.mediaType != .video && track.mediaType != .audio {
                return .skipped("extra tracks")
            }
        }
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let encodedWidth = Int(abs(natural.width).rounded())
        let encodedHeight = Int(abs(natural.height).rounded())
        let display = natural.applying(transform)
        let displayWidth = Int(abs(display.width).rounded())
        let displayHeight = Int(abs(display.height).rounded())
        if encodedWidth < 2 || encodedHeight < 2 || encodedWidth % 2 != 0 || encodedHeight % 2 != 0 {
            return .skipped("odd video dimensions")
        }
        let descriptions = try await video.load(.formatDescriptions)
        if hasAlpha(descriptions) { return .skipped("alpha channel") }
        let subtype = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let codec = fourCC(subtype)
        let fps = Double(try await video.load(.nominalFrameRate))
        let dataRate = Double(try await video.load(.estimatedDataRate))
        if fps > 1, dataRate > 0 {
            let bpp = dataRate / (Double(encodedWidth) * Double(encodedHeight) * fps)
            if (codec == "hvc1" || codec == "hev1" || codec == "av01"), bpp < 0.045 {
                return .skipped("already a small HEVC/AV1 stream")
            }
            if (codec == "avc1" || codec == "avc3"), bpp < 0.065 {
                return .skipped("already a small H.264 stream")
            }
        }
        var tenBit = false
        if let description = descriptions.first,
           let bits = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) {
            let number = bits as? NSNumber
            if (number?.intValue ?? 8) > 8 { tenBit = true }
        }
        let duration = try await asset.load(.duration)
        let metadata = try await asset.load(.metadata)
        let quality = QualityScale.video(ctx.settings.quality)
        let ext = containerExtension(ctx.input)
        let temp = TempFile.make(in: ctx.scratch, ext: ext)
        let fileType: AVFileType = ext == "mov" ? .mov : .mp4
        try await VideoEncode.run(
            asset: asset,
            video: video,
            audio: audioTracks,
            output: temp,
            fileType: fileType,
            width: encodedWidth,
            height: encodedHeight,
            transform: transform,
            tenBit: tenBit,
            quality: quality,
            metadata: metadata,
            cancel: ctx.isCancelled,
            progress: ctx.progress)
        try await VideoEncode.verify(
            original: asset, originalDuration: duration, output: temp,
            encodedWidth: encodedWidth, encodedHeight: encodedHeight,
            displayWidth: displayWidth, displayHeight: displayHeight,
            audioCount: audioTracks.count)
        let outputBytes = try Files.size(temp)
        guard Gain.accepts(input: ctx.inputBytes, output: outputBytes) else {
            try? FileManager.default.removeItem(at: temp)
            return .skipped("below minimum gain")
        }
        let q = String(format: "q%.2f", quality)
        return .produced(temp: temp, ext: ext, method: "HEVC · \(q)", lossless: false, note: nil)
    }

    private func containerExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext == "mov" ? "mov" : "mp4"
    }

    private func hasAlpha(_ descriptions: [CMFormatDescription]) -> Bool {
        for description in descriptions {
            let codec = fourCC(CMFormatDescriptionGetMediaSubType(description))
            if codec == "ap4h" || codec == "ap4x" || codec == "muxa" { return true }
            if let raw = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) {
                if let number = raw as? NSNumber, number.boolValue { return true }
                if let flag = raw as? Bool, flag { return true }
            }
        }
        return false
    }

    private func fourCC(_ value: FourCharCode) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

private enum VideoEncode {
    static func run(
        asset: AVAsset,
        video: AVAssetTrack,
        audio: [AVAssetTrack],
        output: URL,
        fileType: AVFileType,
        width: Int,
        height: Int,
        transform: CGAffineTransform,
        tenBit: Bool,
        quality: Double,
        metadata: [AVMetadataItem],
        cancel: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let pixelFormat: OSType = tenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw JobError.codec("cannot read video") }
        reader.add(videoOutput)

        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        var compression: [String: Any] = [
            kVTCompressionPropertyKey_Quality as String: quality,
        ]
        if tenBit {
            compression[kVTCompressionPropertyKey_ProfileLevel as String] = kVTProfileLevel_HEVC_Main10_AutoLevel
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw JobError.codec("cannot add HEVC input") }
        writer.add(videoInput)
        for track in audio {
            let outputSettings: [String: Any]? = nil
            let descriptions = try await track.load(.formatDescriptions)
            let hint = descriptions.first
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            guard reader.canAdd(readerOutput) else { throw JobError.codec("cannot read audio") }
            reader.add(readerOutput)
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            guard writer.canAdd(writerInput) else { throw JobError.codec("cannot add audio passthrough") }
            writer.add(writerInput)
            audioPairs.append((readerOutput, writerInput))
        }
        writer.metadata = metadata
        guard reader.startReading() else {
            throw JobError.codec(reader.error?.localizedDescription ?? "video reader failed")
        }
        guard writer.startWriting() else {
            throw JobError.codec(writer.error?.localizedDescription ?? "video writer failed")
        }
        writer.startSession(atSourceTime: .zero)
        let duration = try await asset.load(.duration).seconds
        let readerBox = MediaBox(reader)
        let writerBox = MediaBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = FinishBox(continuation)
            let queue = DispatchQueue(label: "ologn.video", qos: .userInitiated)
            let group = DispatchGroup()
            pump(input: videoInput, output: videoOutput, writer: writerBox, group: group, queue: queue, duration: duration, cancel: cancel, progress: progress, box: box)
            for pair in audioPairs {
                pump(input: pair.1, output: pair.0, writer: writerBox, group: group, queue: queue, duration: duration, cancel: cancel, progress: { _ in }, box: box)
            }
            group.notify(queue: queue) {
                if box.isFailed {
                    let recorded = box.recordedError()
                    readerBox.value.cancelReading()
                    writerBox.value.cancelWriting()
                    if let recorded {
                        box.finish(FailureMap.jobError(recorded))
                    } else if cancel() {
                        box.finish(CancellationError())
                    } else {
                        box.finish(JobError.codec("video writer failed"))
                    }
                    return
                }
                if cancel() {
                    readerBox.value.cancelReading()
                    writerBox.value.cancelWriting()
                    box.finish(CancellationError())
                    return
                }
                writerBox.value.finishWriting {
                    if writerBox.value.status == .completed {
                        box.finish(nil)
                    } else {
                        box.finish(writerBox.value.error ?? JobError.codec("video writer failed"))
                    }
                }
            }
        }
        if cancel() {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }
        if reader.status == .failed {
            try? FileManager.default.removeItem(at: output)
            throw JobError.codec(reader.error?.localizedDescription ?? "video reader failed")
        }
    }

    static func verify(
        original: AVAsset,
        originalDuration: CMTime,
        output: URL,
        encodedWidth: Int,
        encodedHeight: Int,
        displayWidth: Int,
        displayHeight: Int,
        audioCount: Int
    ) async throws {
        let asset = AVURLAsset(url: output)
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw JobError.verificationFailed("video output is not playable") }
        let duration = try await asset.load(.duration)
        guard abs(duration.seconds - originalDuration.seconds) <= 0.1 else {
            throw JobError.verificationFailed("video duration differs")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw JobError.verificationFailed("video output has no picture") }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let box = size.applying(transform)
        let outEncodedWidth = Int(abs(size.width).rounded())
        let outEncodedHeight = Int(abs(size.height).rounded())
        let outDisplayWidth = Int(abs(box.width).rounded())
        let outDisplayHeight = Int(abs(box.height).rounded())
        guard outEncodedWidth == encodedWidth, outEncodedHeight == encodedHeight,
              outDisplayWidth == displayWidth, outDisplayHeight == displayHeight else {
            throw JobError.verificationFailed("video dimensions differ")
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count == audioCount else {
            throw JobError.verificationFailed("audio track count differs")
        }
        _ = original
    }

    private static func pump(
        input: AVAssetWriterInput,
        output: AVAssetReaderOutput,
        writer: MediaBox<AVAssetWriter>,
        group: DispatchGroup,
        queue: DispatchQueue,
        duration: Double,
        cancel: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Double) -> Void,
        box: FinishBox
    ) {
        group.enter()
        let state = PumpState()
        let inputBox = MediaBox(input)
        let outputBox = MediaBox(output)
        inputBox.value.requestMediaDataWhenReady(on: queue) {
            while inputBox.value.isReadyForMoreMediaData {
                if cancel() {
                    box.recordFailure(nil)
                    inputBox.value.markAsFinished()
                    state.leave(group)
                    return
                }
                guard let sample = outputBox.value.copyNextSampleBuffer() else {
                    inputBox.value.markAsFinished()
                    state.leave(group)
                    return
                }
                if duration > 0 {
                    let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if seconds.isFinite { progress(min(0.99, seconds / duration)) }
                }
                if !inputBox.value.append(sample) {
                    box.recordFailure(writer.value.error)
                    inputBox.value.markAsFinished()
                    state.leave(group)
                    return
                }
            }
        }
    }
}

private final class MediaBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private final class PumpState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    func leave(_ group: DispatchGroup) {
        let first = lock.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        if first { group.leave() }
    }
}

private final class FinishBox: @unchecked Sendable {
    private struct State {
        var resumed = false
        var failed = false
        var error: Error?
    }

    private let continuation: CheckedContinuation<Void, Error>
    private let lock = OSAllocatedUnfairLock(initialState: State())
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    var isFailed: Bool { lock.withLock { $0.failed } }

    /// Captures `writer.error` at the append failure, before `cancelWriting` can clear it.
    func recordFailure(_ error: Error?) {
        lock.withLock { state in
            state.failed = true
            if state.error == nil { state.error = error }
        }
    }

    func recordedError() -> Error? { lock.withLock { $0.error } }

    func finish(_ error: Error?) {
        let first = lock.withLock { state -> Bool in
            if state.resumed { return false }
            state.resumed = true
            return true
        }
        guard first else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}
