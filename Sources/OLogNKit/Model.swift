import Darwin
import Foundation

public enum CompressionMode: String, Sendable, Codable, CaseIterable {
    case smart, lossless
}

public enum QualityPreset: String, Sendable, Codable, CaseIterable {
    case compact, balanced, studio
}

public enum ArchiveFormat: String, Sendable, Codable, CaseIterable {
    case xz, zip
}

public enum ImageConversion: String, Sendable, Codable, CaseIterable {
    case keep, heic, avif
}

public enum OutputLocation: Sendable, Codable, Hashable {
    case nextToOriginal
    case folder(URL)
}

public enum FileKind: String, Sendable, Codable, CaseIterable {
    case png, jpeg, heic, pdf, video, audio, folder, generic
}

public enum DropzoneAnchor: String, Sendable, Codable, CaseIterable {
    case topCenter, rightCenter, leftCenter
}

public struct JobID: Hashable, Sendable, Codable {
    public let raw: UUID
    public init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

public struct JobRequest: Sendable, Equatable {
    public var source: URL
    public var mode: CompressionMode
    public var settings: EngineSettings
    public var batchID: UUID?
    public init(source: URL, mode: CompressionMode, settings: EngineSettings, batchID: UUID? = nil) {
        self.source = source
        self.mode = mode
        self.settings = settings
        self.batchID = batchID
    }
}

/// Identity of a source at the moment compression started.
///
/// `size` is the byte count the gain gate used: `stat` size for a file, or the sum of regular-file
/// sizes for a folder. `modificationDate` and `fileID` come from `stat` (the call follows symlinks).
/// `fileID` is the inode. Replace Original should recapture the source and refuse the swap when any
/// field differs. `capture` does filesystem IO; do not call it on a cooperative thread.
public struct SourceFingerprint: Sendable, Codable, Equatable {
    public var size: Int64
    public var modificationDate: Date
    public var fileID: UInt64

    public init(size: Int64, modificationDate: Date, fileID: UInt64) {
        self.size = size
        self.modificationDate = modificationDate
        self.fileID = fileID
    }

    public static func capture(_ url: URL) throws -> SourceFingerprint {
        let info = try stat(url)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let bytes = try FolderSizing.regularFiles(at: url).bytes
            return SourceFingerprint(size: bytes, modificationDate: info.date, fileID: info.fileID)
        }
        return SourceFingerprint(size: info.size, modificationDate: info.date, fileID: info.fileID)
    }

    private static func stat(_ url: URL) throws -> (size: Int64, date: Date, fileID: UInt64) {
        let buffer = UnsafeMutablePointer<Darwin.stat>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        buffer.initialize(to: Darwin.stat())
        defer { buffer.deinitialize(count: 1) }
        let rc = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return olognStat(pointer, buffer)
        }
        guard rc == 0 else {
            throw JobError.unreadable("cannot stat \(url.path)")
        }
        let info = buffer.pointee
        let spec = info.st_mtimespec
        let date = Date(
            timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
        return (Int64(info.st_size), date, UInt64(info.st_ino))
    }
}

/// `stat(2)`. Swift's overlay hides the function behind the `stat` struct, and on
/// Apple Silicon the inode-64 symbol is the unsuffixed `stat`.
@_silgen_name("stat")
private func olognStat(_ path: UnsafePointer<CChar>, _ buf: UnsafeMutablePointer<Darwin.stat>) -> Int32

public struct JobResult: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        case compressed, alreadyOptimal
    }

    public let outcome: Outcome
    public let kind: FileKind
    public let method: String
    public let lossless: Bool
    public let verified: Bool
    public let inputBytes: Int64
    public let outputBytes: Int64
    public let outputURL: URL?
    public let note: String?
    public let duration: TimeInterval
    /// Captured when processing started. Nil only for results built without a source snapshot.
    public let sourceFingerprint: SourceFingerprint?
    /// Identity of the file `OutputWriter` had just published. Nil when this result has no output.
    /// The app compares later file actions against this stamp. It does not fingerprint whatever
    /// happens to sit at the path afterwards and treat that as the output.
    public let outputFingerprint: SourceFingerprint?

    public init(
        outcome: Outcome,
        kind: FileKind,
        method: String,
        lossless: Bool,
        verified: Bool,
        inputBytes: Int64,
        outputBytes: Int64,
        outputURL: URL?,
        note: String?,
        duration: TimeInterval,
        sourceFingerprint: SourceFingerprint? = nil,
        outputFingerprint: SourceFingerprint? = nil
    ) {
        self.outcome = outcome
        self.kind = kind
        self.method = method
        self.lossless = lossless
        self.verified = verified
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.outputURL = outputURL
        self.note = note
        self.duration = duration
        self.sourceFingerprint = sourceFingerprint
        self.outputFingerprint = outputFingerprint
    }

    public var savedBytes: Int64 { max(0, inputBytes - outputBytes) }
    public var savedFraction: Double {
        guard inputBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(inputBytes)
    }
}

public enum JobError: Error, Sendable, Codable, Equatable {
    case unreadable(String)
    case outputNotWritable(String)
    case diskFull
    case verificationFailed(String)
    case codec(String)
}

public enum JobState: Sendable, Equatable {
    case queued
    case running(fraction: Double)
    case finished(JobResult)
    case failed(JobError)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

public struct Job: Identifiable, Sendable, Equatable {
    public let id: JobID
    public let request: JobRequest
    public let kind: FileKind
    public let inputBytes: Int64
    public let createdAt: Date
    public var state: JobState

    /// The synthesized memberwise initializer is internal. History restore and the demo
    /// tray construct jobs from outside this module.
    public init(id: JobID, request: JobRequest, kind: FileKind, inputBytes: Int64, createdAt: Date, state: JobState) {
        self.id = id
        self.request = request
        self.kind = kind
        self.inputBytes = inputBytes
        self.createdAt = createdAt
        self.state = state
    }

    public var idKey: JobID { id }
}

public enum EngineEvent: Sendable {
    case added(Job)
    case updated(Job)
    case removed(JobID)
    case paused(reason: String)
    case resumed
}

enum Lane: Sendable {
    case cpu, wide, media
}

struct CodecContext: Sendable {
    let input: URL
    let inputBytes: Int64
    let mode: CompressionMode
    let settings: EngineSettings
    let scratch: URL
    let progress: @Sendable (Double) -> Void
    let isCancelled: @Sendable () -> Bool
}

enum CodecOutcome: Sendable {
    case produced(temp: URL, ext: String, method: String, lossless: Bool, note: String?)
    case skipped(String)
}

protocol Codec: Sendable {
    var kind: FileKind { get }
    var lane: Lane { get }
    func compress(_ ctx: CodecContext) async throws -> CodecOutcome
}
