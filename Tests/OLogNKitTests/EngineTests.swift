import Foundation
import os
import Testing
@testable import OLogNKit

@Test func cancellingRemovesTheScratchDirectoryAndWritesNothing() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let out = bundle.directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let engine = CompressionEngine()
    let scratches = OSAllocatedUnfairLock(initialState: [URL]())
    await engine.setScratchHookForTesting { url in
        scratches.withLock { $0.append(url) }
        await engine.cancelAll()
    }
    let id = await engine.submit([bundle.text], mode: .lossless, settings: Fixtures.settings(in: out))[0]
    let job = await engine.waitUntilFinished(id)
    #expect(job.state == .cancelled)
    let seen = scratches.withLock { $0 }
    #expect(!seen.isEmpty)
    for url in seen {
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    let outputs = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
    #expect(outputs.isEmpty)
}

@Test func progressFractionsAreMonotonicAndTheJobEnds() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    let out = bundle.directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let engine = CompressionEngine()
    let stream = engine.events()
    let id = await engine.submit([bundle.text], mode: .lossless, settings: Fixtures.settings(in: out))[0]
    var fractions: [Double] = []
    var terminal = false
    for await event in stream {
        switch event {
        case .updated(let job) where job.id == id:
            if case .running(let fraction) = job.state { fractions.append(fraction) }
            if job.state.isTerminal { terminal = true }
        case .added(let job) where job.id == id && job.state.isTerminal:
            terminal = true
        default:
            break
        }
        if terminal { break }
    }
    #expect(terminal)
    #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
}
