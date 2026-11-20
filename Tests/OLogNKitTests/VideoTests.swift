import Foundation
import Testing
@testable import OLogNKit

@Test func videoLosslessDoesNotOpenASecondFile() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let out = bundle.directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let before = try Fixtures.hash(bundle.video)
    let job = await Fixtures.run(bundle.video, mode: .lossless, settings: Fixtures.settings(in: out))
    guard case .finished(let result) = job.state else {
        Issue.record("video job did not finish: \(job.state)")
        return
    }
    #expect(result.outcome == .alreadyOptimal)
    #expect(result.outputURL == nil)
    #expect(try Fixtures.hash(bundle.video) == before)
    let names = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
    #expect(names.isEmpty)
}
