import Foundation
import Testing
@testable import OLogNKit

/// Fable's ship-readiness review: a folder whose name starts with "-" was parsed by tar as options.
@Test func folderNamedLikeAnOptionArchivesAndVerifies() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ologn-release-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("-rf album", isDirectory: true)
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let filler = String(repeating: "dash-prefixed folder names must not become tar flags\n", count: 2_000)
    try filler.write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try filler.write(to: folder.appendingPathComponent("--version"), atomically: true, encoding: .utf8)

    var settings = EngineSettings()
    settings.output = .folder(out)
    let engine = CompressionEngine()
    let id = await engine.submit([folder], mode: .lossless, settings: settings)[0]
    let job = await engine.waitUntilFinished(id)
    guard case .finished(let result) = job.state else {
        Issue.record("folder job did not finish: \(job.state)")
        return
    }
    #expect(result.outcome == .compressed)
    let output = try #require(result.outputURL)
    #expect(output.lastPathComponent == "-rf album.tar.xz")
    try await LosslessVerifier.verify(original: folder, output: output)
}

@Test func registryStopsARunningChildAndRefusesLaunchesAfterShutdown() throws {
    // An isolated registry: the shared one is process-wide and other tests launch tools through it.
    let registry = ChildProcessRegistry()
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    #expect(registry.register(sleeper))
    try sleeper.run()
    registry.launched(sleeper)
    let started = ContinuousClock.now
    registry.terminateAll()
    sleeper.waitUntilExit()
    registry.unregister(sleeper)
    #expect(sleeper.terminationReason == .uncaughtSignal)
    #expect(ContinuousClock.now - started < .seconds(5))

    let late = Process()
    late.executableURL = URL(fileURLWithPath: "/bin/sleep")
    late.arguments = ["30"]
    #expect(!registry.register(late), "launches after shutdown must be refused")
    registry.terminateAll()  // idempotent
}

@Test func childLaunchedDuringShutdownIsStoppedRightAfterRun() throws {
    let registry = ChildProcessRegistry()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    #expect(registry.register(child))
    registry.terminateAll()          // shutdown lands between register and run
    try child.run()
    registry.launched(child)         // must stop it immediately
    child.waitUntilExit()
    registry.unregister(child)
    #expect(child.terminationReason == .uncaughtSignal)
}

@Test(arguments: ["-C", "@photos", "-rf album"])
func folderNamesThatTarTreatsAsInstructionsRoundTrip(name: String) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ologn-release-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent(name, isDirectory: true)
    let out = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try String(repeating: "special operand \(name)\n", count: 2_000)
        .write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    var settings = EngineSettings()
    settings.output = .folder(out)
    let engine = CompressionEngine()
    let id = await engine.submit([folder], mode: .lossless, settings: settings)[0]
    let job = await engine.waitUntilFinished(id)
    guard case .finished(let result) = job.state, let output = result.outputURL else {
        Issue.record("\(name): \(job.state)")
        return
    }
    #expect(output.lastPathComponent == "\(name).tar.xz")
    try await LosslessVerifier.verify(original: folder, output: output)
    let extracted = root.appendingPathComponent("x", isDirectory: true)
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
    // Off the cooperative pool: blocking waits in parallel tests starved it once before (architecture §9).
    let status = try await Offload.run { _ -> Int32 in
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", output.path, "-C", extracted.path]
        try tar.run()
        tar.waitUntilExit()
        return tar.terminationStatus
    }
    #expect(status == 0)
    let restored = try String(contentsOf: extracted.appendingPathComponent(name).appendingPathComponent("a.txt"), encoding: .utf8)
    #expect(restored.hasPrefix("special operand \(name)"))
}
