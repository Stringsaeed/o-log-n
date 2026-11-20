import Foundation
import Testing
@testable import OLogNKit

@Test func textCompressesAndRandomBytesAreLeftAlone() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let out = bundle.directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let text = await Fixtures.run(bundle.text, mode: .lossless, settings: Fixtures.settings(in: out))
    try await expectLossless(text, original: bundle.text)
    guard case .finished(let textResult) = text.state else { return }
    #expect(textResult.outcome == .compressed)
    #expect(textResult.outputURL?.lastPathComponent.hasSuffix(".txt.xz") == true)

    let before = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).count
    let random = await Fixtures.run(bundle.random, mode: .smart, settings: Fixtures.settings(in: out))
    guard case .finished(let randomResult) = random.state else {
        Issue.record("random job did not finish")
        return
    }
    #expect(randomResult.outcome == .alreadyOptimal)
    #expect(randomResult.outputURL == nil)
    let after = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil).count
    #expect(after == before)
}

@Test func multiStreamXZDecodesToTheInput() throws {
    let payload = Data(repeating: 0x61, count: 5 * 1024 * 1024)
    let encoded = try XZ.encode(data: payload, cancel: { false }, progress: { _ in })
    let decoded = try XZ.decode(encoded)
    #expect(decoded == payload)
}
