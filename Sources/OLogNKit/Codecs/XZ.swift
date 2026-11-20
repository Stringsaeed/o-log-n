import Compression
import CryptoKit
import Foundation
import os

/// Concatenated xz streams, one per 4 MiB chunk, from `COMPRESSION_LZMA`.
enum XZ {
    static let chunkSize = 4 * 1024 * 1024

    static func encode(
        data: Data,
        cancel: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> Data {
        let reader = MemoryReader(data)
        let sink = DataSink()
        try encodeChunks(
            read: { reader.read(chunkSize) },
            write: { sink.append($0) },
            total: Int64(data.count),
            cancel: cancel,
            progress: progress)
        return sink.bytes
    }

    static func encodeFile(
        input: URL,
        output: URL,
        cancel: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let total = try Files.size(input)
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        let reader = FileReader(handle)
        try encodeChunks(
            read: { try reader.read(chunkSize) },
            write: { try writer.write(contentsOf: $0) },
            total: total,
            cancel: cancel,
            progress: progress)
    }

    static func decode(_ data: Data) throws -> Data {
        let sink = DataSink()
        try decompress(data) { sink.append($0) }
        return sink.bytes
    }

    static func decodeHash(of url: URL) throws -> SHA256.Digest {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var hasher = SHA256()
        try decompress(data) { hasher.update(data: $0) }
        return hasher.finalize()
    }

    private static func encodeChunks(
        read: () throws -> Data,
        write: (Data) throws -> Void,
        total: Int64,
        cancel: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var consumed: Int64 = 0
        var wroteAny = false
        // One autorelease pool per batch keeps memory at ~2 × width × chunk regardless of input size
        // (FileHandle reads and writes hand back autoreleased NSData on these threads).
        while try autoreleasepool(invoking: { () throws -> Bool in
            if cancel() { throw CancellationError() }
            var batch: [Data] = []
            batch.reserveCapacity(width)
            for _ in 0..<width {
                let chunk = try read()
                if chunk.isEmpty { break }
                batch.append(chunk)
            }
            if batch.isEmpty { return false }
            wroteAny = true
            let compressed = try compressBatch(batch, cancel: cancel)
            for part in compressed { try write(part) }
            consumed += Int64(batch.reduce(0) { $0 + $1.count })
            if total > 0 {
                progress(min(0.99, Double(consumed) / Double(total)))
            }
            return true
        }) {}
        if !wroteAny {
            try write(try compressChunk(Data()))
        }
    }

    private static func compressBatch(_ batch: [Data], cancel: @escaping @Sendable () -> Bool) throws -> [Data] {
        let slots = OSAllocatedUnfairLock(initialState: [Data?](repeating: nil, count: batch.count))
        let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
        DispatchQueue.concurrentPerform(iterations: batch.count) { index in
            if cancel() {
                failure.withLock { if $0 == nil { $0 = "cancelled" } }
                return
            }
            do {
                let compressed = try compressChunk(batch[index])
                slots.withLock { $0[index] = compressed }
            } catch {
                failure.withLock { if $0 == nil { $0 = String(describing: error) } }
            }
        }
        if failure.withLock({ $0 }) == "cancelled" { throw CancellationError() }
        if let message = failure.withLock({ $0 }) { throw JobError.codec(message) }
        let parts = slots.withLock { $0 }
        guard parts.allSatisfy({ $0 != nil }) else { throw JobError.codec("xz batch incomplete") }
        return parts.compactMap { $0 }
    }

    private static func compressChunk(_ input: Data) throws -> Data {
        let capacity = max(input.count + 65_536, 4_096)
        var output = Data(count: capacity)
        var written = encodeBuffer(input, into: &output)
        if written == 0 {
            output = Data(count: capacity * 2 + input.count)
            written = encodeBuffer(input, into: &output)
        }
        guard written > 0 else { throw JobError.codec("xz encode failed") }
        return output.prefix(written)
    }

    private static func encodeBuffer(_ input: Data, into output: inout Data) -> Int {
        output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                if let srcBase = src.bindMemory(to: UInt8.self).baseAddress {
                    return compression_encode_buffer(
                        dstBase, dst.count, srcBase, src.count, nil, COMPRESSION_LZMA)
                }
                var dummy: UInt8 = 0
                return withUnsafePointer(to: &dummy) { source in
                    compression_encode_buffer(dstBase, dst.count, source, 0, nil, COMPRESSION_LZMA)
                }
            }
        }
    }

    /// Re-inits the decoder at each stream end. `compression_stream` stops at the first stream.
    /// An empty buffer is not an xz payload: at least one stream must finish.
    private static func decompress(_ input: Data, into consume: (Data) -> Void) throws {
        if input.isEmpty {
            throw JobError.verificationFailed("xz payload does not match the input")
        }
        var streams = 0
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw JobError.verificationFailed("xz payload does not match the input")
            }
            var offset = 0
            while offset < raw.count {
                let dummyDst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
                let dummySrc = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
                defer {
                    dummyDst.deallocate()
                    dummySrc.deallocate()
                }
                var stream = compression_stream(
                    dst_ptr: dummyDst, dst_size: 0, src_ptr: UnsafePointer(dummySrc), src_size: 0, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
                    == COMPRESSION_STATUS_OK
                else {
                    throw JobError.verificationFailed("xz init failed")
                }
                defer { compression_stream_destroy(&stream) }
                let capacity = 1 << 20
                let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                defer { destination.deallocate() }
                try withUnsafeMutablePointer(to: &stream) { pointer in
                    pointer.pointee.src_ptr = base.advanced(by: offset)
                    pointer.pointee.src_size = raw.count - offset
                    var ended = false
                    var spins = 0
                    while !ended {
                        spins += 1
                        if spins > 8_000_000 { throw JobError.verificationFailed("xz decode stalled") }
                        pointer.pointee.dst_ptr = destination
                        pointer.pointee.dst_size = capacity
                        let sourceBefore = pointer.pointee.src_size
                        let status = compression_stream_process(pointer, 0)
                        let produced = capacity - pointer.pointee.dst_size
                        if produced > 0 {
                            autoreleasepool { consume(Data(bytes: destination, count: produced)) }
                        }
                        if status == COMPRESSION_STATUS_END {
                            ended = true
                            streams += 1
                        } else if status == COMPRESSION_STATUS_ERROR {
                            throw JobError.verificationFailed("xz decode error")
                        } else if produced == 0 && pointer.pointee.src_size == sourceBefore {
                            throw JobError.verificationFailed("xz decode made no progress")
                        }
                    }
                    let consumed = (raw.count - offset) - pointer.pointee.src_size
                    if consumed <= 0 { throw JobError.verificationFailed("xz stream consumed nothing") }
                    offset += consumed
                }
            }
        }
        if streams < 1 {
            throw JobError.verificationFailed("xz payload does not match the input")
        }
    }
}

private final class DataSink: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Data())
    func append(_ data: Data) { lock.withLock { $0.append(data) } }
    var bytes: Data { lock.withLock { $0 } }
}

private final class MemoryReader: @unchecked Sendable {
    private let data: Data
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    init(_ data: Data) { self.data = data }
    func read(_ count: Int) -> Data {
        lock.withLock { offset in
            guard offset < data.count else { return Data() }
            let end = min(data.count, offset + count)
            let slice = data.subdata(in: offset..<end)
            offset = end
            return slice
        }
    }
}

private final class FileReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = OSAllocatedUnfairLock(initialState: ())
    init(_ handle: FileHandle) { self.handle = handle }
    func read(_ count: Int) throws -> Data {
        try lock.withLock { _ in
            try handle.read(upToCount: count) ?? Data()
        }
    }
}
