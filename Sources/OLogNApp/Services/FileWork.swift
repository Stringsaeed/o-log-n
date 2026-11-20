import Darwin
import Foundation
import OLogNKit
import Synchronization

/// Names a new file without colliding. Attempt 1 is `stem.ext`; later attempts are `stem-2.ext`, `stem-3.ext`, …
enum FileNames {
    static func candidate(directory: URL, stem: String, ext: String, attempt: Int) -> URL {
        let suffix = attempt <= 1 ? "" : "-\(attempt)"
        let name = ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)"
        return directory.appendingPathComponent(name)
    }
}

/// Moves a file or directory onto a path that must not already exist.
///
/// Same-volume moves use `renamex_np(RENAME_EXCL)`. Cross-volume moves copy to a
/// private name on the destination volume, then exclusive-rename into place, and
/// only then delete the source. A failure leaves the source where it was.
enum FileMove {
    enum Outcome: Equatable {
        case stored
        case exists
        case failed(String)
    }

    static func exclusive(from: URL, to: URL) -> Outcome {
        if from.standardizedFileURL == to.standardizedFileURL { return .stored }
        switch renameExclusive(from: from, to: to) {
        case .stored:
            return .stored
        case .exists:
            return .exists
        case .crossVolume:
            return copyExclusive(from: from, to: to)
        case .failed(let message):
            return .failed(message)
        }
    }

    private enum Rename {
        case stored
        case exists
        case crossVolume
        case failed(String)
    }

    private static func renameExclusive(from: URL, to: URL) -> Rename {
        from.withUnsafeFileSystemRepresentation { source in
            to.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return .failed("could not copy the path") }
                if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return .stored }
                let error = errno
                if error == EEXIST { return .exists }
                if error == EXDEV { return .crossVolume }
                return .failed(String(cString: strerror(error)))
            }
        }
    }

    private static func copyExclusive(from: URL, to: URL) -> Outcome {
        let partial = to.deletingLastPathComponent()
            .appendingPathComponent(".ologn-move-\(UUID().uuidString)")
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_RECURSIVE)
        let copied = from.withUnsafeFileSystemRepresentation { source -> Int32 in
            partial.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return -1 }
                return copyfile(source, destination, nil, flags)
            }
        }
        if copied != 0 {
            try? FileManager.default.removeItem(at: partial)
            let error = errno
            if error == EEXIST { return .exists }
            return .failed(String(cString: strerror(error)))
        }
        switch renameExclusive(from: partial, to: to) {
        case .stored:
            try? FileManager.default.removeItem(at: from)
            return .stored
        case .exists:
            try? FileManager.default.removeItem(at: partial)
            return .exists
        case .crossVolume, .failed:
            try? FileManager.default.removeItem(at: partial)
            return .failed("could not place the file")
        }
    }
}

/// Creates a new file with `O_CREAT|O_EXCL` and retries `stem-2`, `stem-3`, … on collision.
/// Never replaces an existing file. Call only from `JobFileWork`.
enum ExclusiveFile {
    static func create(directory: URL, stem: String, ext: String, contents: Data) throws -> URL {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for attempt in 1...10_000 {
            let url = FileNames.candidate(directory: directory, stem: stem, ext: ext, attempt: attempt)
            let fd = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
                guard let pointer else { return -1 }
                return Darwin.open(pointer, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            }
            if fd < 0 {
                if errno == EEXIST { continue }
                throw ReplaceError.io(String(cString: strerror(errno)))
            }
            do {
                try writeAll(fd, contents)
            } catch {
                Darwin.close(fd)
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            if Darwin.close(fd) != 0 {
                try? FileManager.default.removeItem(at: url)
                throw ReplaceError.io(String(cString: strerror(errno)))
            }
            return url
        }
        throw ReplaceError.io("could not find a free name")
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ReplaceError.io(String(cString: strerror(errno)))
                }
                written += count
            }
        }
    }
}

/// Serial file work. One queue per job, plus a clipboard queue. The main actor only awaits the result.
enum JobFileWork {
    private static let queues = Mutex<[UUID: DispatchQueue]>([:])
    private static let clipboard = DispatchQueue(label: "app.ologn.mac.clipboard", qos: .userInitiated)

    static func run<T: Sendable>(_ id: JobID, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await perform(on: queue(for: id), body)
    }

    static func runDetached<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await perform(on: clipboard, body)
    }

    private static func queue(for id: JobID) -> DispatchQueue {
        queues.withLock { queues in
            if let existing = queues[id.raw] { return existing }
            let created = DispatchQueue(label: "app.ologn.mac.file.\(id.raw.uuidString)", qos: .userInitiated)
            queues[id.raw] = created
            return created
        }
    }

    private static func perform<T: Sendable>(
        on queue: DispatchQueue,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
