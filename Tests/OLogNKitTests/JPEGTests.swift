import Foundation
import Testing
@testable import OLogNKit

@Test func jpegLosslessRoundTripKeepsCoefficientsWhenItShrinks() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let out = bundle.directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let job = await Fixtures.run(bundle.jpeg, mode: .lossless, settings: Fixtures.settings(in: out))
    try await expectLossless(job, original: bundle.jpeg)
}

@Test func jpegLosslessProgressiveStyleIsCoefficientExactAndProgressive() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let out = bundle.directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var settings = Fixtures.settings(in: out)
    settings.jpegLossless = .progressive
    let job = await Fixtures.run(bundle.jpeg, mode: .lossless, settings: settings)
    guard case .finished(let result) = job.state else {
        Issue.record("job did not finish: \(job.state)")
        return
    }
    try #require(result.outcome == .compressed, "fixture should shrink: \(result.note ?? "")")
    let output = try #require(result.outputURL)
    #expect(result.lossless)
    #expect(result.method == "JPEG · progressive (DCT-exact)")
    let original = try Data(contentsOf: bundle.jpeg)
    let produced = try Data(contentsOf: output)
    #expect(!JPEGInspect.isProgressive(original))
    #expect(JPEGInspect.isProgressive(produced))
    #expect(JPEGBridge.coefficientsEqual(original, produced))
    try await LosslessVerifier.verify(original: bundle.jpeg, output: output)
}
