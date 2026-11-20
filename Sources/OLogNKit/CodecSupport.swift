import CryptoKit
import Foundation
import os

enum WorkingMemory {
    /// Per-job decoded-image budget. Over budget, Smart refuses the pixel path.
    static let budget = 512 * 1024 * 1024

    static func fits(_ bytes: Int) -> Bool {
        bytes >= 0 && bytes <= budget
    }

    static func fits(width: Int, height: Int, bytesPerPixel: Int) -> Bool {
        guard let bytes = try? count(width, height, bytesPerPixel) else { return false }
        return fits(bytes)
    }

    static func count(_ factors: Int...) throws -> Int {
        var total = 1
        for factor in factors {
            guard factor >= 0 else { throw JobError.unreadable("image dimensions overflow") }
            let (value, overflow) = total.multipliedReportingOverflow(by: factor)
            if overflow { throw JobError.unreadable("image dimensions overflow") }
            total = value
        }
        return total
    }
}

enum Gain {
    /// D20: `saved >= max(512, input * 5 / 1000)`.
    static func accepts(input: Int64, output: Int64) -> Bool {
        let saved = input - output
        guard saved > 0 else { return false }
        return saved >= minimum(for: input)
    }

    static func minimum(for input: Int64) -> Int64 {
        max(512, input * 5 / 1000)
    }
}

enum Files {
    static func size(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        return Int64(values.fileSize ?? 0)
    }

    static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FailureMap.jobError(error) == .diskFull
                ? JobError.diskFull
                : JobError.unreadable(error.localizedDescription)
        }
    }
}

enum FileHash {
    static func sha256(data: Data) -> SHA256.Digest {
        SHA256.hash(data: data)
    }

    static func sha256(url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Drain autoreleased NSData per chunk: without a pool, a multi-GB file grows RSS to its full size.
        while try autoreleasepool(invoking: {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize()
    }
}

enum FolderSizing {
    /// Sum of regular-file sizes, and the number of regular files. Directories count as neither.
    static func regularFiles(at url: URL) throws -> (bytes: Int64, count: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw JobError.unreadable("cannot list \(url.path)")
        }
        var bytes: Int64 = 0
        var count = 0
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                count += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (bytes, count)
    }
}

/// Owns the lifecycle of tools spawned by `Command.run` (tar, ditto, unzip). Children are not killed when
/// their parent exits, so hosts call `ChildProcesses.terminateAll()` on quit / SIGINT.
///
/// It holds `Process` objects, not bare PIDs, and signals only through `Process.terminate()` while
/// `isRunning`, under the same lock that guards registration. A PID is only reusable after Foundation has
/// reaped the child, and a reaped child reports `isRunning == false`, so an exited child is never signalled.
/// After `terminateAll()`, new launches are refused, and a child that was mid-launch is stopped right after
/// `run()`.
final class ChildProcessRegistry: @unchecked Sendable {
    static let shared = ChildProcessRegistry()

    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]
    private var shuttingDown = false

    init() {}

    /// Call before `process.run()`. Returns false once shutdown has begun; the caller must not launch.
    func register(_ process: Process) -> Bool {
        lock.withLock {
            guard !shuttingDown else { return false }
            running[ObjectIdentifier(process)] = process
            return true
        }
    }

    /// Call right after `process.run()`. It closes the window where shutdown ran between register and launch.
    func launched(_ process: Process) {
        lock.withLock {
            if shuttingDown, process.isRunning { process.terminate() }
        }
    }

    /// Call once the child has exited, or after it was told to terminate.
    func unregister(_ process: Process) {
        lock.withLock { running[ObjectIdentifier(process)] = nil }
    }

    /// Stops every running child and refuses further launches. Idempotent and callable from any thread.
    func terminateAll() {
        lock.withLock {
            shuttingDown = true
            for process in running.values where process.isRunning {
                process.terminate()
            }
        }
    }

    var isShuttingDown: Bool { lock.withLock { shuttingDown } }
}

public enum ChildProcesses {
    /// Stops all spawned tools (SIGTERM) and refuses new ones. For app quit and CLI interrupt only.
    public static func terminateAll() { ChildProcessRegistry.shared.terminateAll() }
}

enum Command {
    /// Runs an absolute-path tool. Stderr goes to a file. A non-zero exit throws `JobError.codec`.
    static func run(
        _ executable: String,
        _ arguments: [String],
        standardOutput: URL? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil,
        cancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> Data {
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ologn-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderrHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = stderrHandle

        let pipe = Pipe()
        var stdoutWriter: FileHandle?
        if let standardOutput {
            if !FileManager.default.fileExists(atPath: standardOutput.path) {
                FileManager.default.createFile(atPath: standardOutput.path, contents: nil)
            }
            stdoutWriter = try FileHandle(forWritingTo: standardOutput)
            process.standardOutput = stdoutWriter
        } else {
            process.standardOutput = pipe
        }
        defer { try? stdoutWriter?.close() }

        let registry = ChildProcessRegistry.shared
        guard registry.register(process) else { throw CancellationError() }
        defer { registry.unregister(process) }
        try process.run()
        registry.launched(process)

        let bucket = OSAllocatedUnfairLock(initialState: Data())
        let group = DispatchGroup()
        if stdoutWriter == nil {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let reader = pipe.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    bucket.withLock { $0.append(chunk) }
                }
                group.leave()
            }
        }

        while process.isRunning {
            if cancel() {
                process.terminate()
                group.wait()
                throw CancellationError()
            }
            if let standardOutput, let progress {
                let current = (try? Files.size(standardOutput)) ?? 0
                progress(current)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        group.wait()

        let status = process.terminationStatus
        if status != 0 {
            let errData = (try? Data(contentsOf: stderrURL)) ?? Data()
            let text = String(decoding: errData, as: UTF8.self)
            let tail = text.suffix(500).trimmingCharacters(in: .whitespacesAndNewlines)
            throw JobError.codec(tail.isEmpty ? "\(executable) exited \(status)" : String(tail))
        }
        return bucket.withLock { $0 }
    }
}

enum TempFile {
    static func make(in directory: URL, ext: String) -> URL {
        let name = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(name)
    }
}
