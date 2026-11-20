import Foundation

public enum LosslessVerifier {
    /// Throws `JobError.verificationFailed`. A message that starts with `unsupported` means the pair is not a content check.
    public static func verify(original: URL, output: URL) async throws {
        try await Offload.run { token in
            if token.isCancelled { throw CancellationError() }
            try verifyBody(original: original, output: output, cancel: { token.isCancelled })
        }
    }

    private static func verifyBody(original: URL, output: URL, cancel: @escaping @Sendable () -> Bool) throws {
        if cancel() { throw CancellationError() }
        let kind = try Router.kind(of: original)
        let name = output.lastPathComponent.lowercased()
        switch kind {
        case .png:
            guard name.hasSuffix(".png") else { throw unsupported("png") }
            try PNGFormat.verifyPair(original, output)
        case .jpeg:
            guard name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") else { throw unsupported("jpeg") }
            try JPEGCodec.verifyFiles(original, output)
        case .audio:
            guard name.hasSuffix(".flac") else { throw unsupported("audio") }
            try AudioVerify.pcmEqual(original, output)
        case .generic:
            if output.pathExtension.lowercased() == "xz" {
                let decoded = try XZ.decodeHash(of: output)
                let originalHash = try FileHash.sha256(url: original)
                guard decoded == originalHash else {
                    throw JobError.verificationFailed("xz payload does not match the input")
                }
            } else if output.pathExtension.lowercased() == "zip" {
                try zipMatches(original: original, archive: output, cancel: cancel)
            } else {
                throw unsupported("generic")
            }
        case .folder:
            if name.hasSuffix(".tar.xz") {
                let decoded = try XZ.decodeHash(of: output)
                let tar = try TarArchive.hash(ofFolder: original)
                guard decoded == tar else {
                    throw JobError.verificationFailed("tar.xz payload does not match the folder")
                }
            } else if output.pathExtension.lowercased() == "zip" {
                try zipMatches(original: original, archive: output, cancel: cancel)
            } else {
                throw unsupported("folder")
            }
        default:
            throw unsupported(kind.rawValue)
        }
    }

    private static func unsupported(_ kind: String) -> JobError {
        .verificationFailed("unsupported pair (\(kind))")
    }

    /// Compares regular-file paths and bytes. `.DS_Store` and `__MACOSX` are ignored. Extra files fail.
    private static func zipMatches(original: URL, archive: URL, cancel: @escaping @Sendable () -> Bool) throws {
        let extract = FileManager.default.temporaryDirectory
            .appendingPathComponent("ologn-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extract) }
        do {
            _ = try Command.run("/usr/bin/ditto", ["-xk", archive.path, extract.path], cancel: cancel)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JobError.verificationFailed("zip payload does not match the input")
        }
        var isDirectory: ObjCBool = false
        let sourceIsDirectory = FileManager.default.fileExists(atPath: original.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let allowed = original.lastPathComponent
        try rejectExtraTopLevel(extract, allowed: allowed)
        if sourceIsDirectory {
            try compareTrees(original, extract.appendingPathComponent(allowed, isDirectory: true))
        } else {
            try compareFiles(original, extract.appendingPathComponent(allowed))
        }
    }

    private static func rejectExtraTopLevel(_ root: URL, allowed: String) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let extras = names.filter { name in
            name != allowed && name != ".DS_Store" && name != "__MACOSX"
        }
        if !extras.isEmpty || !names.contains(allowed) {
            throw JobError.verificationFailed("zip payload does not match the input")
        }
    }

    private static func compareFiles(_ left: URL, _ right: URL) throws {
        guard FileManager.default.fileExists(atPath: right.path) else {
            throw JobError.verificationFailed("zip payload does not match the input")
        }
        guard try FileHash.sha256(url: left) == FileHash.sha256(url: right) else {
            throw JobError.verificationFailed("zip payload does not match the input")
        }
    }

    private static func compareTrees(_ left: URL, _ right: URL) throws {
        let source = try regularFiles(under: left)
        let output = try regularFiles(under: right)
        guard source.keys.sorted() == output.keys.sorted() else {
            throw JobError.verificationFailed("zip payload does not match the input")
        }
        for key in source.keys {
            guard let a = source[key], let b = output[key] else {
                throw JobError.verificationFailed("zip payload does not match the input")
            }
            try compareFiles(a, b)
        }
    }

    private static func regularFiles(under root: URL) throws -> [String: URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw JobError.verificationFailed("zip payload does not match the input")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [])
        else { throw JobError.verificationFailed("zip payload does not match the input") }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var files: [String: URL] = [:]
        for case let item as URL in enumerator {
            if item.lastPathComponent == ".DS_Store" { continue }
            let path = item.resolvingSymlinksInPath().standardizedFileURL.path
            let relative: String
            if path.hasPrefix(rootPath + "/") {
                relative = String(path.dropFirst(rootPath.count + 1))
            } else {
                relative = item.lastPathComponent
            }
            if relative.split(separator: "/").contains("__MACOSX") { continue }
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true || values.isDirectory == true { continue }
            if values.isRegularFile == true { files[relative] = item }
        }
        return files
    }
}
