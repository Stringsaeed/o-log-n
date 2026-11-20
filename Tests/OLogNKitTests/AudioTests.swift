import Foundation
import Testing
@testable import OLogNKit

@Test func wavLosslessBecomesVerifiedFLAC() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let out = bundle.directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let job = await Fixtures.run(bundle.wav, mode: .lossless, settings: Fixtures.settings(in: out))
    try await expectLossless(job, original: bundle.wav)
    guard case .finished(let result) = job.state else { return }
    if result.outcome == .compressed {
        #expect(result.outputURL?.pathExtension == "flac")
        #expect(result.note == "non-audio chunks dropped")
    }
}
