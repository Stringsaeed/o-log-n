import Foundation
import Testing
@testable import OLogNKit

@Test func aSecondRunUsesTheNextSuffixAndOverwritesNothing() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let out = bundle.directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let settings = Fixtures.settings(in: out)
    let first = await Fixtures.run(bundle.text, mode: .lossless, settings: settings)
    let second = await Fixtures.run(bundle.text, mode: .lossless, settings: settings)
    guard case .finished(let firstResult) = first.state, case .finished(let secondResult) = second.state,
          let firstURL = firstResult.outputURL, let secondURL = secondResult.outputURL else {
        Issue.record("expected two compressed outputs")
        return
    }
    #expect(firstURL.lastPathComponent == "notes.txt.xz")
    #expect(secondURL.lastPathComponent == "notes.txt-2.xz")
    #expect(FileManager.default.fileExists(atPath: firstURL.path))
    #expect(FileManager.default.fileExists(atPath: secondURL.path))
    #expect(try Data(contentsOf: firstURL) == Data(contentsOf: firstURL))
}
