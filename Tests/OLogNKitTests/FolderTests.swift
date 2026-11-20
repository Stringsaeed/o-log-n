import Foundation
import Testing
@testable import OLogNKit

@Test func folderTarXZMatchesAFreshTar() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let out = bundle.directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let job = await Fixtures.run(bundle.folder, mode: .lossless, settings: Fixtures.settings(in: out))
    try await expectLossless(job, original: bundle.folder)
    guard case .finished(let result) = job.state, let output = result.outputURL else { return }
    #expect(output.lastPathComponent == "album.tar.xz")
}
