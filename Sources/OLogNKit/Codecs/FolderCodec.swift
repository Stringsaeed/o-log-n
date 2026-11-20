import CryptoKit
import Foundation

struct FolderCodec: Codec {
    let kind: FileKind = .folder
    let lane: Lane = .wide

    func compress(_ ctx: CodecContext) async throws -> CodecOutcome {
        let listing = try await Offload.run { token -> (bytes: Int64, count: Int) in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            return try FolderSizing.regularFiles(at: ctx.input)
        }
        if listing.count == 0 { return .skipped("empty folder") }
        let zip = ctx.settings.archiveFormat == .zip
        let ext = zip ? "zip" : "tar.xz"
        let temp = TempFile.make(in: ctx.scratch, ext: ext)
        try await Offload.run { token in
            let cancel: @Sendable () -> Bool = { token.isCancelled || ctx.isCancelled() }
            if zip {
                _ = try Command.run(
                    "/usr/bin/ditto",
                    ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", ctx.input.path, temp.path],
                    cancel: cancel)
                _ = try Command.run("/usr/bin/unzip", ["-tq", temp.path], cancel: cancel)
            } else {
                let tarURL = ctx.scratch.appendingPathComponent("payload.tar")
                let parent = ctx.input.deletingLastPathComponent().path
                let name = ctx.input.lastPathComponent
                let inputBytes = max(ctx.inputBytes, 1)
                _ = try Command.run(
                    "/usr/bin/tar",
                    TarArchive.createArguments(parent: parent, name: name),
                    standardOutput: tarURL,
                    progress: { bytes in
                        ctx.progress(min(0.99, Double(bytes) / Double(inputBytes)))
                    },
                    cancel: cancel)
                let tarHash = try FileHash.sha256(url: tarURL)
                try XZ.encodeFile(input: tarURL, output: temp, cancel: cancel, progress: { _ in })
                let decoded = try XZ.decodeHash(of: temp)
                guard decoded == tarHash else {
                    throw JobError.verificationFailed("tar.xz payload does not match the tar stream")
                }
                try? FileManager.default.removeItem(at: tarURL)
            }
        }
        let outputBytes = try Files.size(temp)
        guard Gain.accepts(input: ctx.inputBytes, output: outputBytes) else {
            try? FileManager.default.removeItem(at: temp)
            return .skipped("below minimum gain")
        }
        return .produced(temp: temp, ext: ext, method: zip ? "zip" : "tar.xz", lossless: true, note: nil)
    }
}

enum TarArchive {
    /// The one argument list used both to create a folder's tar and to re-create it for verification.
    /// macOS bsdtar treats some operands as instructions even after `--` (`-C` wants a directory,
    /// `@name` includes another archive), so names starting with `-` or `@` get an explicit `./` spelling.
    static func createArguments(parent: String, name: String) -> [String] {
        ["-cf", "-", "--no-mac-metadata", "--exclude", ".DS_Store", "-C", parent, "--", operand(name)]
    }

    static func operand(_ name: String) -> String {
        name.hasPrefix("-") || name.hasPrefix("@") ? "./" + name : name
    }

    /// SHA-256 of the same tar stream the folder codec writes.
    static func hash(ofFolder url: URL) throws -> SHA256Digest {
        let tarURL = FileManager.default.temporaryDirectory.appendingPathComponent("ologn-tar-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tarURL) }
        let parent = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        _ = try Command.run(
            "/usr/bin/tar",
            TarArchive.createArguments(parent: parent, name: name),
            standardOutput: tarURL)
        return try FileHash.sha256(url: tarURL)
    }
}

typealias SHA256Digest = SHA256.Digest
