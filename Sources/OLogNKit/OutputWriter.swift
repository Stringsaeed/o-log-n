import Darwin
import Foundation

enum OutputNames {
    static func isArchive(_ ext: String) -> Bool {
        ext == "xz" || ext == "zip" || ext == "tar.xz"
    }

    /// Media: `stem-min.ext`, then `stem-min-2.ext`. Archives: `name.ext.xz` / `folder.tar.xz` / `name.zip`.
    static func destination(
        directory: URL,
        source: URL,
        ext: String,
        suffix: String,
        attempt: Int
    ) -> URL {
        let fileName: String
        if ext == "tar.xz" {
            let base = source.lastPathComponent
            let stem = attempt <= 1 ? base : "\(base)-\(attempt)"
            fileName = "\(stem).tar.xz"
        } else if isArchive(ext) {
            let base = source.lastPathComponent
            fileName = attempt <= 1 ? "\(base).\(ext)" : "\(base)-\(attempt).\(ext)"
        } else {
            let stem = source.deletingPathExtension().lastPathComponent
            if attempt <= 1 {
                fileName = "\(stem)\(suffix).\(ext)"
            } else {
                fileName = "\(stem)\(suffix)-\(attempt).\(ext)"
            }
        }
        return directory.appendingPathComponent(fileName)
    }
}

enum OutputWriter {
    struct PublishedOutput: Sendable {
        var url: URL
        var fingerprint: SourceFingerprint
    }

    /// Moves `temp` into place. Returns nil when D20 fails (the temp is deleted). Never overwrites.
    ///
    /// The fingerprint is `stat` of the file the exclusive rename just published, taken before this
    /// function returns. Callers run `publish` off the cooperative pool; the stamp must not be a
    /// later look at whatever path the name now points to.
    static func publish(
        temp: URL,
        ext: String,
        source: URL,
        destinationDirectory: URL,
        settings: EngineSettings,
        kind: FileKind,
        inputBytes: Int64,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> PublishedOutput? {
        let outputBytes = try Files.size(temp)
        guard Gain.accepts(input: inputBytes, output: outputBytes) else {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
        if isCancelled() {
            try? FileManager.default.removeItem(at: temp)
            throw CancellationError()
        }
        if !OutputNames.isArchive(ext) {
            try copyMetadata(from: source, to: temp, settings: settings, kind: kind)
        }
        for attempt in 1...10_000 {
            if isCancelled() {
                try? FileManager.default.removeItem(at: temp)
                throw CancellationError()
            }
            let dest = OutputNames.destination(
                directory: destinationDirectory,
                source: source,
                ext: ext,
                suffix: settings.suffix,
                attempt: attempt)
            let moved = renameExclusive(from: temp, to: dest)
            switch moved {
            case .stored:
                let fingerprint = try SourceFingerprint.capture(dest)
                return PublishedOutput(url: dest, fingerprint: fingerprint)
            case .exists:
                continue
            case .diskFull:
                throw JobError.diskFull
            case .failed(let message):
                throw JobError.outputNotWritable(message)
            }
        }
        throw JobError.outputNotWritable("could not find a free name")
    }

    static func makeScratch(appropriateFor directory: URL) throws -> URL {
        do {
            return try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: directory,
                create: true)
        } catch {
            let mapped = FailureMap.jobError(error)
            if case .diskFull = mapped { throw JobError.diskFull }
            throw JobError.outputNotWritable(error.localizedDescription)
        }
    }

    private enum Move {
        case stored
        case exists
        case diskFull
        case failed(String)
    }

    private static func renameExclusive(from: URL, to: URL) -> Move {
        let source = strdup(from.path)
        let dest = strdup(to.path)
        defer {
            free(source)
            free(dest)
        }
        guard let source, let dest else { return .failed("could not copy path") }
        let result = renamex_np(source, dest, UInt32(RENAME_EXCL))
        if result == 0 { return .stored }
        let error = errno
        if error == EEXIST { return .exists }
        if error == ENOSPC { return .diskFull }
        return .failed(String(cString: strerror(error)))
    }

    private static func copyMetadata(from source: URL, to temp: URL, settings: EngineSettings, kind: FileKind) throws {
        guard kind != .generic, kind != .folder else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        // Extended attributes while the scratch file is still writable. Permissions go on last,
        // or a read-only mode would make setxattr fail and drop quarantine.
        try copyXattrs(from: source.path, to: temp.path)
        if settings.preserveDates {
            var dates: [FileAttributeKey: Any] = [:]
            if let created = attributes[.creationDate] { dates[.creationDate] = created }
            if let modified = attributes[.modificationDate] { dates[.modificationDate] = modified }
            if !dates.isEmpty {
                try applyAttributes(dates, to: temp.path)
            }
        }
        if let permissions = attributes[.posixPermissions] {
            try applyAttributes([.posixPermissions: permissions], to: temp.path)
        }
    }

    private static func applyAttributes(_ attributes: [FileAttributeKey: Any], to path: String) throws {
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        } catch {
            if case .diskFull = FailureMap.jobError(error) { throw JobError.diskFull }
            throw JobError.outputNotWritable(error.localizedDescription)
        }
    }

    private static func copyXattrs(from: String, to: String) throws {
        let names = [
            "com.apple.metadata:_kMDItemUserTags",
            "com.apple.metadata:kMDItemWhereFroms",
            "com.apple.quarantine",
        ]
        for name in names {
            let length = getxattr(from, name, nil, 0, 0, 0)
            if length < 0 {
                let error = errno
                if error == ENOATTR { continue }
                throw JobError.outputNotWritable("could not copy \(name)")
            }
            if length == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: length)
            let copied = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return getxattr(from, name, base, length, 0, 0)
            }
            if copied < 0 {
                throw JobError.outputNotWritable("could not copy \(name)")
            }
            let wrote = buffer.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return setxattr(to, name, base, copied, 0, 0)
            }
            if wrote != 0 {
                throw JobError.outputNotWritable("could not copy \(name)")
            }
        }
    }
}
