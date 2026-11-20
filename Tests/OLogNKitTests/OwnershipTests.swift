import Foundation
import Testing
@testable import OLogNKit

@Test func publishedStampMatchesTheFileThenStopsMatchingAfterRewrite() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let folder = bundle.directory.appendingPathComponent("published", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let job = await Fixtures.run(bundle.text, mode: .lossless, settings: Fixtures.settings(in: folder))
    guard case .finished(let result) = job.state, result.outcome == .compressed else {
        Issue.record("expected a compressed file, got \(job.state)")
        return
    }
    let url = try #require(result.outputURL)
    let stamp = try #require(result.outputFingerprint)
    let live = try await captureOffPool(url)
    #expect(stamp == live)
    try await writeOffPool(Data("usurper".utf8), to: url)
    let after = try await captureOffPool(url)
    #expect(stamp != after)
}

private func captureOffPool(_ url: URL) async throws -> SourceFingerprint {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try SourceFingerprint.capture(url))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func writeOffPool(_ data: Data, to url: URL) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try data.write(to: url, options: .atomic)
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
