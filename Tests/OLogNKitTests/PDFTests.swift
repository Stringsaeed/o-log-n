import Foundation
import Testing
@testable import OLogNKit

@Test func pdfLosslessIsAlreadyOptimal() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let out = bundle.directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let job = await Fixtures.run(bundle.pdf, mode: .lossless, settings: Fixtures.settings(in: out))
    guard case .finished(let result) = job.state else {
        Issue.record("pdf job did not finish: \(job.state)")
        return
    }
    #expect(result.outcome == .alreadyOptimal)
    #expect(result.outputURL == nil)
    #expect(try Fixtures.hash(bundle.pdf) == Fixtures.hash(bundle.pdf))
}
