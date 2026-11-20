import AudioToolbox
import AVFoundation
import CryptoKit
import Foundation

struct AudioCodec: Codec {
    let kind: FileKind = .audio
    let lane: Lane = .cpu

    func compress(_ ctx: CodecContext) async throws -> CodecOutcome {
        let info = try await Offload.run { token -> AudioInfo in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            return try AudioInspect.inspect(ctx.input)
        }
        switch info.route {
        case .pcm(let channels, let bits, let rate):
            if ctx.mode == .lossless {
                return try await flac(ctx, channels: channels, bits: bits, rate: rate)
            }
            return try await aac(ctx, channels: channels, rate: rate)
        case .losslessCodec:
            if ctx.mode == .lossless { return .skipped("already lossless audio") }
            let channels = info.channels
            let rate = info.sampleRate
            return try await aac(ctx, channels: channels, rate: rate)
        case .alreadyOptimal(let reason):
            return .skipped(reason)
        }
    }

    private func flac(_ ctx: CodecContext, channels: Int, bits: Int, rate: Double) async throws -> CodecOutcome {
        let temp = TempFile.make(in: ctx.scratch, ext: "flac")
        try await Offload.run { token in
            try AudioTranscode.flac(
                from: ctx.input, to: temp, channels: channels, bits: bits, rate: rate,
                cancel: { token.isCancelled || ctx.isCancelled() })
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            try AudioVerify.pcmEqual(ctx.input, temp)
        }
        let outputBytes = try Files.size(temp)
        guard Gain.accepts(input: ctx.inputBytes, output: outputBytes) else {
            try? FileManager.default.removeItem(at: temp)
            return .skipped("below minimum gain")
        }
        return .produced(
            temp: temp, ext: "flac", method: "FLAC", lossless: true, note: "non-audio chunks dropped")
    }

    private func aac(_ ctx: CodecContext, channels: Int, rate: Double) async throws -> CodecOutcome {
        let bitrate = QualityScale.aacBitsPerSecond(channels: channels, preset: ctx.settings.quality)
        let temp = TempFile.make(in: ctx.scratch, ext: "m4a")
        try await Offload.run { token in
            try AudioTranscode.aac(
                from: ctx.input, to: temp, channels: channels, rate: rate, bitrate: bitrate,
                cancel: { token.isCancelled || ctx.isCancelled() })
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            try AudioVerify.smart(ctx.input, temp)
        }
        let outputBytes = try Files.size(temp)
        guard Gain.accepts(input: ctx.inputBytes, output: outputBytes) else {
            try? FileManager.default.removeItem(at: temp)
            return .skipped("below minimum gain")
        }
        let kbps = bitrate / 1000
        return .produced(temp: temp, ext: "m4a", method: "AAC \(kbps)k", lossless: false, note: nil)
    }
}

enum AudioVerify {
    static func pcmEqual(_ original: URL, _ output: URL) throws {
        let left = try AudioTranscode.decodeInt32(original)
        let right = try AudioTranscode.decodeInt32(output)
        guard left.frames == right.frames,
              left.hash == right.hash,
              left.channelCount == right.channelCount,
              abs(left.sampleRate - right.sampleRate) < 0.5 else {
            throw JobError.verificationFailed("pcm does not match")
        }
    }

    static func smart(_ original: URL, _ output: URL) throws {
        let left = try AVAudioFile(forReading: original)
        let right = try AVAudioFile(forReading: output)
        let leftRate = left.processingFormat.sampleRate
        let rightRate = right.processingFormat.sampleRate
        let leftDuration = Double(left.length) / leftRate
        let rightDuration = Double(right.length) / rightRate
        guard abs(leftDuration - rightDuration) <= 0.05 else {
            throw JobError.verificationFailed("audio duration differs")
        }
        guard left.processingFormat.channelCount == right.processingFormat.channelCount,
              abs(leftRate - rightRate) < 0.5 else {
            throw JobError.verificationFailed("audio format differs")
        }
    }
}

private enum AudioRoute {
    case pcm(channels: Int, bits: Int, rate: Double)
    case losslessCodec
    case alreadyOptimal(String)
}

private struct AudioInfo {
    var route: AudioRoute
    var channels: Int
    var sampleRate: Double
}

private enum AudioInspect {
    static func inspect(_ url: URL) throws -> AudioInfo {
        var file: ExtAudioFileRef?
        let status = ExtAudioFileOpenURL(url as CFURL, &file)
        guard status == noErr, let file else {
            throw JobError.unreadable("cannot open audio (\(status))")
        }
        defer { ExtAudioFileDispose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr else {
            throw JobError.unreadable("cannot read audio format")
        }
        let channels = Int(format.mChannelsPerFrame)
        let rate = format.mSampleRate
        let bits = Int(format.mBitsPerChannel)
        let fileType = audioFileType(file)
        if format.mFormatID == kAudioFormatFLAC || format.mFormatID == kAudioFormatAppleLossless {
            return AudioInfo(route: .losslessCodec, channels: channels, sampleRate: rate)
        }
        if format.mFormatID != kAudioFormatLinearPCM {
            return AudioInfo(route: .alreadyOptimal("lossy audio"), channels: channels, sampleRate: rate)
        }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let containerOK = [kAudioFileWAVEType, kAudioFileAIFFType, kAudioFileAIFCType, kAudioFileCAFType].contains(fileType)
        if !containerOK || isFloat || bits >= 32 || bits == 8 || !(channels >= 1 && channels <= 8) || (bits != 16 && bits != 24) {
            return AudioInfo(route: .alreadyOptimal("audio is not 16/24-bit integer PCM"), channels: channels, sampleRate: rate)
        }
        return AudioInfo(route: .pcm(channels: channels, bits: bits, rate: rate), channels: channels, sampleRate: rate)
    }

    private static func audioFileType(_ file: ExtAudioFileRef) -> AudioFileTypeID {
        var audioFile: AudioFileID?
        var size = UInt32(MemoryLayout<AudioFileID>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile) == noErr,
              let audioFile else { return 0 }
        var type: AudioFileTypeID = 0
        var typeSize = UInt32(MemoryLayout<AudioFileTypeID>.size)
        AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &typeSize, &type)
        return type
    }
}

enum AudioTranscode {
    struct PCMHash {
        var frames: Int64
        var hash: SHA256.Digest
        var sampleRate: Double
        var channelCount: Int
    }

    static func flac(
        from: URL, to: URL, channels: Int, bits: Int, rate: Double,
        cancel: @escaping () -> Bool
    ) throws {
        let client = pcmFormat(rate: rate, channels: channels, bits: bits, bytesPerChannel: bits == 24 ? 3 : 2)
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatFLAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bits),
            mReserved: 0)
        try transcode(
            from: from, to: to, fileType: kAudioFileFLACType, outputFormat: &outputFormat,
            client: client, bitrate: nil, bitDepthHint: bits, cancel: cancel)
    }

    static func aac(
        from: URL, to: URL, channels: Int, rate: Double, bitrate: Int,
        cancel: @escaping () -> Bool
    ) throws {
        let client = pcmFormat(rate: rate, channels: channels, bits: 16, bytesPerChannel: 2)
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        try transcode(
            from: from, to: to, fileType: kAudioFileM4AType, outputFormat: &outputFormat,
            client: client, bitrate: bitrate, bitDepthHint: nil, cancel: cancel)
    }

    static func decodeInt32(_ url: URL) throws -> PCMHash {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else {
            throw JobError.verificationFailed("cannot decode audio")
        }
        defer { ExtAudioFileDispose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format)
        let channels = Int(format.mChannelsPerFrame)
        var client = pcmFormat(rate: format.mSampleRate, channels: channels, bits: 32, bytesPerChannel: 4)
        let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, clientSize, &client) == noErr else {
            throw JobError.verificationFailed("cannot set decode format")
        }
        var hasher = SHA256()
        var frames: Int64 = 0
        let framesPerRead: UInt32 = 4096
        let bytes = Int(framesPerRead) * channels * 4
        var buffer = Data(count: bytes)
        while true {
            var count = framesPerRead
            let status: OSStatus = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(bytes),
                        mData: base))
                return ExtAudioFileRead(file, &count, &list)
            }
            if status != noErr { throw JobError.verificationFailed("audio read failed") }
            if count == 0 { break }
            let used = Int(count) * channels * 4
            hasher.update(data: buffer.prefix(used))
            frames += Int64(count)
        }
        return PCMHash(
            frames: frames, hash: hasher.finalize(),
            sampleRate: format.mSampleRate, channelCount: channels)
    }

    private static func pcmFormat(rate: Double, channels: Int, bits: Int, bytesPerChannel: Int) -> AudioStreamBasicDescription {
        let bytes = UInt32(channels * bytesPerChannel)
        return AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytes,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytes,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bits),
            mReserved: 0)
    }

    private static func transcode(
        from: URL,
        to: URL,
        fileType: AudioFileTypeID,
        outputFormat: inout AudioStreamBasicDescription,
        client: AudioStreamBasicDescription,
        bitrate: Int?,
        bitDepthHint: Int?,
        cancel: () -> Bool
    ) throws {
        var source: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(from as CFURL, &source) == noErr, let source else {
            throw JobError.unreadable("cannot open audio")
        }
        defer { ExtAudioFileDispose(source) }
        var clientFormat = client
        let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileSetProperty(source, kExtAudioFileProperty_ClientDataFormat, clientSize, &clientFormat) == noErr else {
            throw JobError.codec("cannot set audio client format")
        }
        var destination: ExtAudioFileRef?
        let created = ExtAudioFileCreateWithURL(
            to as CFURL, fileType, &outputFormat, nil, AudioFileFlags.eraseFile.rawValue, &destination)
        guard created == noErr, let destination else {
            throw JobError.codec("cannot create audio output (\(created))")
        }
        defer { ExtAudioFileDispose(destination) }
        guard ExtAudioFileSetProperty(destination, kExtAudioFileProperty_ClientDataFormat, clientSize, &clientFormat) == noErr else {
            throw JobError.codec("cannot set output client format")
        }
        if bitrate != nil || bitDepthHint != nil {
            var converter: AudioConverterRef?
            var converterSize = UInt32(MemoryLayout<AudioConverterRef>.size)
            guard ExtAudioFileGetProperty(destination, kExtAudioFileProperty_AudioConverter, &converterSize, &converter) == noErr,
                  let converter else {
                throw JobError.codec("cannot read audio converter")
            }
            if let bitDepthHint {
                var depth = UInt32(bitDepthHint)
                let set = AudioConverterSetProperty(
                    converter, kAudioConverterPropertyBitDepthHint, UInt32(MemoryLayout<UInt32>.size), &depth)
                if set != noErr { throw JobError.codec("bit depth hint failed (\(set))") }
            }
            if let bitrate {
                var rate = UInt32(bitrate)
                let set = AudioConverterSetProperty(
                    converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
                if set != noErr { throw JobError.codec("bitrate failed (\(set))") }
            }
        }
        let channels = Int(client.mChannelsPerFrame)
        let bytesPerFrame = Int(client.mBytesPerFrame)
        let framesPerRead = 4096
        var buffer = Data(count: framesPerRead * bytesPerFrame)
        while true {
            if cancel() { throw CancellationError() }
            var count = UInt32(framesPerRead)
            let status: OSStatus = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(framesPerRead * bytesPerFrame),
                        mData: base))
                return ExtAudioFileRead(source, &count, &list)
            }
            if status != noErr { throw JobError.codec("audio read failed (\(status))") }
            if count == 0 { break }
            let writeStatus: OSStatus = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: count * UInt32(bytesPerFrame),
                        mData: base))
                return ExtAudioFileWrite(destination, count, &list)
            }
            if writeStatus != noErr { throw JobError.codec("audio write failed (\(writeStatus))") }
        }
    }
}
