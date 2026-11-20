import Foundation

struct GenericCodec: Codec {
    let kind: FileKind = .generic
    let lane: Lane = .wide

    func compress(_ ctx: CodecContext) async throws -> CodecOutcome {
        let skip = try await Offload.run { token -> String? in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            guard SkipGate.shouldSkip(ctx.input) else { return nil }
            return SkipGate.reason(for: ctx.input)
        }
        if let skip { return .skipped(skip) }
        let zip = ctx.settings.archiveFormat == .zip
        let ext = zip ? "zip" : "xz"
        let temp = TempFile.make(in: ctx.scratch, ext: ext)
        try await Offload.run { token in
            let cancel: @Sendable () -> Bool = { token.isCancelled || ctx.isCancelled() }
            if zip {
                _ = try Command.run(
                    "/usr/bin/ditto",
                    ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", ctx.input.path, temp.path],
                    cancel: cancel)
                _ = try Command.run("/usr/bin/unzip", ["-tq", temp.path], cancel: cancel)
            } else {
                try XZ.encodeFile(input: ctx.input, output: temp, cancel: cancel, progress: ctx.progress)
                let decoded = try XZ.decodeHash(of: temp)
                let original = try FileHash.sha256(url: ctx.input)
                guard decoded == original else {
                    throw JobError.verificationFailed("xz payload does not match the input")
                }
            }
        }
        let outputBytes = try Files.size(temp)
        guard Gain.accepts(input: ctx.inputBytes, output: outputBytes) else {
            try? FileManager.default.removeItem(at: temp)
            return .skipped("below minimum gain")
        }
        return .produced(
            temp: temp,
            ext: ext,
            method: zip ? "zip" : "xz (LZMA2)",
            lossless: true,
            note: nil)
    }
}
