import AppKit
import Foundation
import os
import OLogNKit

struct SelfTestReport {
    var scenario: Int
    var pass: Bool
    var detail: String
    var trash: [URL] = []

    func emit() {
        let detail = detail
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "'")
        print("{\"scenario\":\(scenario),\"pass\":\(pass),\"detail\":\"\(detail)\"}")
        fflush(stdout)
    }
}

/// Drives the same replace, undo, naming, and settings types the tray uses.
enum ReplaceSelfTest {
    static func run() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ologn-replace-\(UUID().uuidString)", isDirectory: true)
        var failed = false
        var trash: [URL] = []
        do {
            try await JobFileWork.runDetached {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            let reports = [
                try await scenario1(root),
                try await scenario3(root),
                try await scenario4(root),
                try await scenario5(root),
                try scenario13(),
                try await scenario14(root),
                try await scenario15(root),
            ]
            for report in reports {
                report.emit()
                trash.append(contentsOf: report.trash)
                if !report.pass { failed = true }
            }
        } catch {
            SelfTestReport(scenario: 0, pass: false, detail: "replace selftest crashed: \(error)").emit()
            failed = true
        }
        let leftover = trash
        try? await JobFileWork.runDetached {
            for url in leftover {
                try? FileManager.default.removeItem(at: url)
            }
            try? FileManager.default.removeItem(at: root)
        }
        exit(failed ? 1 : 0)
    }

    private static func scenario1(_ root: URL) async throws -> SelfTestReport {
        let dir = root.appendingPathComponent("s1", isDirectory: true)
        let sourceBytes = Data("source-v1".utf8)
        let outputBytes = Data("output-v1-compressed".utf8)
        let pair = try await makePair(dir: dir, source: "photo.png", output: "photo-min.png", sourceBytes: sourceBytes, outputBytes: outputBytes)

        try await remove(pair.output)
        let missing = try await replace(pair)
        let sourceAfterMissing = try await read(pair.source)
        guard case .failure(.outputMissing) = missing, sourceAfterMissing == sourceBytes, await exists(pair.source) else {
            return SelfTestReport(scenario: 1, pass: false, detail: "deleted output was not refused as outputMissing")
        }

        let edited = Data("source-v1-edited".utf8)
        let changedPair = try await recapture(pair, sourceBytes: sourceBytes, outputBytes: outputBytes, thenEditSource: edited)
        let changed = try await replace(changedPair)
        let sourceAfterEdit = try await read(pair.source)
        let outputAfterEdit = try await read(pair.output)
        guard case .failure(.sourceChanged) = changed, sourceAfterEdit == edited, outputAfterEdit == outputBytes else {
            return SelfTestReport(scenario: 1, pass: false, detail: "edited source was not refused as sourceChanged")
        }

        let forged = Data("forged-output".utf8)
        let forgedPair = try await recapture(pair, sourceBytes: sourceBytes, outputBytes: outputBytes, thenEditOutput: forged)
        let forgedResult = try await replace(forgedPair)
        let sourceAfterForge = try await read(pair.source)
        let outputAfterForge = try await read(pair.output)
        guard case .failure(.outputChanged) = forgedResult, sourceAfterForge == sourceBytes, outputAfterForge == forged else {
            return SelfTestReport(scenario: 1, pass: false, detail: "edited output was not refused as outputChanged")
        }
        return SelfTestReport(scenario: 1, pass: false, detail: "refused missing output, edited source, and edited output").passing
    }

    /// Undo must restore only the file Replace trashed, not whatever later appeared at that Trash path.
    private static func scenario14(_ root: URL) async throws -> SelfTestReport {
        let dir = root.appendingPathComponent("s14", isDirectory: true)
        let sourceBytes = Data("source-v14".utf8)
        let outputBytes = Data("output-v14-compressed".utf8)
        let pair = try await makePair(dir: dir, source: "scan.png", output: "scan-min.png", sourceBytes: sourceBytes, outputBytes: outputBytes)
        guard case .success(let record) = try await replace(pair) else {
            return SelfTestReport(scenario: 14, pass: false, detail: "setup replace failed")
        }
        let impostor = Data("someone-else-in-the-trash".utf8)
        try await JobFileWork.runDetached { try impostor.write(to: record.trashedURL, options: .atomic) }
        let result = try await undo(record)
        let atOriginal = try await read(pair.source)
        let inTrash = try await read(record.trashedURL)
        let trash = [record.trashedURL]
        guard case .failure(.notInTrash) = result, atOriginal == outputBytes, inTrash == impostor else {
            return SelfTestReport(scenario: 14, pass: false, detail: "undo restored a swapped Trash file: \(result)", trash: trash)
        }
        return SelfTestReport(scenario: 14, pass: true, detail: "undo refused a Trash file that is not the trashed original", trash: trash)
    }

    /// Replace is refused for folders at the service itself, not only in the store and UI.
    private static func scenario15(_ root: URL) async throws -> SelfTestReport {
        let dir = root.appendingPathComponent("s15", isDirectory: true)
        let folder = dir.appendingPathComponent("album", isDirectory: true)
        let archive = dir.appendingPathComponent("album.tar.xz")
        let stamps = try await JobFileWork.runDetached { () -> (SourceFingerprint, SourceFingerprint) in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("child".utf8).write(to: folder.appendingPathComponent("a.txt"))
            try Data("archive".utf8).write(to: archive)
            return (try SourceFingerprint.capture(folder), try SourceFingerprint.capture(archive))
        }
        let request = ReplaceRequest(
            jobID: JobID(), original: folder, output: archive, kind: .folder,
            sourceFingerprint: stamps.0, outputFingerprint: stamps.1, displayName: "album")
        let result: Result<ReplaceRecord, ReplaceError> = try await JobFileWork.run(request.jobID) {
            do { return .success(try ReplaceService.replace(request)) } catch let error as ReplaceError { return .failure(error) }
        }
        let folderStillThere = await exists(folder.appendingPathComponent("a.txt"))
        guard case .failure(.notAllowed) = result, folderStillThere else {
            return SelfTestReport(scenario: 15, pass: false, detail: "folder replace was not refused by ReplaceService: \(result)")
        }
        return SelfTestReport(scenario: 15, pass: true, detail: "ReplaceService refused a folder before any file operation")
    }

    private static func scenario3(_ root: URL) async throws -> SelfTestReport {
        let original = Data("ORIGINAL-PNG".utf8)
        let compressed = Data("COMPRESSED-PNG".utf8)
        let dirA = root.appendingPathComponent("s3a", isDirectory: true)
        let pairA = try await makePair(dir: dirA, source: "photo.png", output: "photo-min.png", sourceBytes: original, outputBytes: compressed)
        let replaced = try await replace(pairA)
        guard case .success(let record) = replaced, let installed = record.movedTo else {
            return SelfTestReport(scenario: 3, pass: false, detail: "same-extension replace did not install")
        }
        let document = Data("NEW DOCUMENT".utf8)
        try await write(installed, document)
        let undone = try await undo(record)
        let installedBytes = try await read(installed)
        let aside = await exists(pairA.output)
        var pin = OutputPin.pinned(record.movedTo)
        var location = record.movedTo
        if case .failure(let error) = undone {
            UndoApplication.apply(error: error, pin: &pin, replacedLocation: &location)
        }
        var ledger = UndoLedger()
        ledger.push(.replace(record))
        guard case .failure(.outputChanged) = undone,
              installedBytes == document,
              !aside,
              pin == .pinned(nil),
              ledger.peek() != nil
        else {
            return SelfTestReport(
                scenario: 3,
                pass: false,
                detail: "undo of a replaced installed file did not keep it and the record",
                trash: [record.trashedURL])
        }

        let dirB = root.appendingPathComponent("s3b", isDirectory: true)
        let pairB = try await makePair(dir: dirB, source: "photo.png", output: "photo-min.png", sourceBytes: original, outputBytes: compressed)
        let replacedB = try await replace(pairB)
        guard case .success(let recordB) = replacedB else {
            return SelfTestReport(scenario: 3, pass: false, detail: "second replace failed", trash: [record.trashedURL])
        }
        let user = Data("USER-FILE-BYTES".utf8)
        try await write(pairB.output, user)
        let restored = try await undo(recordB)
        guard case .success(let url) = restored, let url else {
            return SelfTestReport(scenario: 3, pass: false, detail: "undo did not return the relocated output", trash: [record.trashedURL, recordB.trashedURL])
        }
        let userBytes = try await read(pairB.output)
        let relocated = try await read(url)
        let restoredOriginal = try await read(pairB.source)
        let pinB = OutputPin.pinned(url)
        guard url.lastPathComponent == "photo-min-2.png",
              userBytes == user,
              relocated == compressed,
              restoredOriginal == original,
              pinB == .pinned(url)
        else {
            return SelfTestReport(
                scenario: 3,
                pass: false,
                detail: "occupied output path was not kept and the card URL was \(url.lastPathComponent)",
                trash: [record.trashedURL, recordB.trashedURL])
        }
        return SelfTestReport(
            scenario: 3,
            pass: true,
            detail: "identity mismatch keeps the file; a blocked restore uses photo-min-2.png",
            trash: [record.trashedURL, recordB.trashedURL])
    }

    private static func scenario4(_ root: URL) async throws -> SelfTestReport {
        let dir = root.appendingPathComponent("s4", isDirectory: true)
        let stamp = "Clipboard-stamp"
        let firstBytes = Data("alpha-bytes".utf8)
        let secondBytes = Data("beta-bytes".utf8)
        let names = try await JobFileWork.runDetached { () throws -> (String, String, Data) in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let first = try ExclusiveFile.create(directory: dir, stem: stamp, ext: "png", contents: firstBytes)
            let second = try ExclusiveFile.create(directory: dir, stem: stamp, ext: "png", contents: secondBytes)
            let kept = try Data(contentsOf: first)
            return (first.lastPathComponent, second.lastPathComponent, kept)
        }
        let pass = names.2 == firstBytes
            && names.0 == "\(stamp).png"
            && names.1 == "\(stamp)-2.png"
        return SelfTestReport(
            scenario: 4,
            pass: pass,
            detail: pass ? "exclusive create kept the first file and suffixed -2" : "names \(names.0) and \(names.1)")
    }

    private static func scenario5(_ root: URL) async throws -> SelfTestReport {
        let dir = root.appendingPathComponent("s5", isDirectory: true)
        let original = Data("ORIGINAL-PNG".utf8)
        let compressed = Data("COMPRESSED-JPG".utf8)
        let pair = try await makePair(dir: dir, source: "photo.png", output: "photo.jpg", sourceBytes: original, outputBytes: compressed)
        let replaced = try await replace(pair)
        guard case .success(let record) = replaced, record.movedTo == pair.output, await !exists(pair.source) else {
            return SelfTestReport(scenario: 5, pass: false, detail: "extension change did not land on photo.jpg")
        }
        guard try await read(pair.output) == compressed else {
            return SelfTestReport(scenario: 5, pass: false, detail: "photo.jpg bytes changed during replace", trash: [record.trashedURL])
        }
        try await write(pair.source, Data("BLOCKER".utf8))
        var ledger = UndoLedger()
        ledger.push(.replace(record))
        let blocked = try await undo(record)
        let jpg = try await read(pair.output)
        guard case .failure(.occupied) = blocked, jpg == compressed, ledger.count == 1 else {
            return SelfTestReport(scenario: 5, pass: false, detail: "occupied undo moved or dropped the record", trash: [record.trashedURL])
        }
        try await remove(pair.source)
        let second = try await undo(record)
        guard case .success = second else {
            return SelfTestReport(scenario: 5, pass: false, detail: "second undo did not restore", trash: [record.trashedURL])
        }
        ledger.commitSuccess()
        let restored = try await read(pair.source)
        let kept = try await read(pair.output)
        let pass = ledger.count == 0 && restored == original && kept == compressed
        return SelfTestReport(
            scenario: 5,
            pass: pass,
            detail: pass ? "occupied undo kept the record; the retry restored" : "ledger \(ledger.count)",
            trash: [record.trashedURL])
    }

    private static func scenario13() throws -> SelfTestReport {
        var settings = AppSettings()
        settings.historyDays = 1
        settings.defaultMode = .lossless
        settings.presence = .always
        settings.anchor = .leftCenter
        settings.haptics = false
        settings.engine.quality = .studio
        settings.engine.jpegLossless = .progressive
        settings.engine.archiveFormat = .zip
        settings.engine.suffix = "-tiny"
        settings.engine.stripMetadataInSmart = false
        settings.engine.maxCPUJobs = 4
        settings.engine.output = .folder(URL(fileURLWithPath: "/tmp/ologn-out", isDirectory: true))

        let encoded = try JSONEncoder().encode(settings)
        let round = try JSONDecoder().decode(AppSettings.self, from: encoded)
        guard round == settings else {
            return SelfTestReport(scenario: 13, pass: false, detail: "full settings blob did not round-trip")
        }

        var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        object.removeValue(forKey: "historyDays")
        var engine = object["engine"] as? [String: Any] ?? [:]
        engine.removeValue(forKey: "jpegLossless")
        engine["quality"] = "not-a-preset"
        object["engine"] = engine
        let partial = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        guard partial.historyDays == 7,
              partial.engine.quality == .balanced,
              partial.engine.jpegLossless == .pixelExact,
              partial.engine.archiveFormat == .zip,
              partial.engine.suffix == "-tiny",
              partial.engine.maxCPUJobs == 4,
              partial.engine.stripMetadataInSmart == false,
              partial.defaultMode == .lossless,
              partial.presence == .always,
              partial.haptics == false,
              partial.engine.output == settings.engine.output
        else {
            return SelfTestReport(scenario: 13, pass: false, detail: "a bad or missing field reset its siblings")
        }

        object.removeValue(forKey: "engine")
        let bare = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        let pass = bare.engine == EngineSettings() && bare.defaultMode == .lossless && bare.presence == .always && bare.haptics == false
        return SelfTestReport(
            scenario: 13,
            pass: pass,
            detail: pass ? "missing fields keep defaults; siblings survive" : "missing engine did not fall back cleanly")
    }

    private struct Pair: Sendable {
        var source: URL
        var output: URL
        var sourceFP: SourceFingerprint
        var outputFP: SourceFingerprint
    }

    private static func makePair(dir: URL, source: String, output: String, sourceBytes: Data, outputBytes: Data) async throws -> Pair {
        try await JobFileWork.runDetached {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sourceURL = dir.appendingPathComponent(source)
            let outputURL = dir.appendingPathComponent(output)
            try sourceBytes.write(to: sourceURL)
            try outputBytes.write(to: outputURL)
            return Pair(
                source: sourceURL,
                output: outputURL,
                sourceFP: try SourceFingerprint.capture(sourceURL),
                outputFP: try SourceFingerprint.capture(outputURL))
        }
    }

    private static func recapture(_ pair: Pair, sourceBytes: Data, outputBytes: Data, thenEditSource: Data? = nil, thenEditOutput: Data? = nil) async throws -> Pair {
        try await JobFileWork.runDetached {
            try sourceBytes.write(to: pair.source)
            try outputBytes.write(to: pair.output)
            let sourceFP = try SourceFingerprint.capture(pair.source)
            let outputFP = try SourceFingerprint.capture(pair.output)
            if let thenEditSource { try thenEditSource.write(to: pair.source) }
            if let thenEditOutput { try thenEditOutput.write(to: pair.output) }
            return Pair(source: pair.source, output: pair.output, sourceFP: sourceFP, outputFP: outputFP)
        }
    }

    private static func replace(_ pair: Pair) async throws -> Result<ReplaceRecord, ReplaceError> {
        let request = ReplaceRequest(
            jobID: JobID(),
            original: pair.source,
            output: pair.output,
            kind: .png,
            sourceFingerprint: pair.sourceFP,
            outputFingerprint: pair.outputFP,
            displayName: pair.source.lastPathComponent)
        return try await JobFileWork.run(request.jobID) {
            do {
                return .success(try ReplaceService.replace(request))
            } catch let error as ReplaceError {
                return .failure(error)
            }
        }
    }

    private static func undo(_ record: ReplaceRecord) async throws -> Result<URL?, ReplaceError> {
        try await JobFileWork.run(record.jobID) {
            do {
                return .success(try ReplaceService.undo(record).url)
            } catch let error as ReplaceError {
                return .failure(error)
            }
        }
    }

    private static func read(_ url: URL) async throws -> Data {
        try await JobFileWork.runDetached { try Data(contentsOf: url) }
    }

    private static func write(_ url: URL, _ data: Data) async throws {
        try await JobFileWork.runDetached { try data.write(to: url) }
    }

    private static func remove(_ url: URL) async throws {
        try await JobFileWork.runDetached { try FileManager.default.removeItem(at: url) }
    }

    private static func exists(_ url: URL) async -> Bool {
        (try? await JobFileWork.runDetached { FileManager.default.fileExists(atPath: url.path) }) ?? false
    }
}

private extension SelfTestReport {
    var passing: SelfTestReport {
        var copy = self
        copy.pass = true
        return copy
    }
}

/// Opens the tray, resigns it, and reopens it during dismiss. Also checks the drag-session and pill geometry rules.
@MainActor
enum KeySelfTest {
    static func run() async {
        var failed = false
        let geometry = geometryReports()
        for report in geometry {
            report.emit()
            if !report.pass { failed = true }
        }
        let keyboard = await keyboardReports()
        for report in keyboard {
            report.emit()
            if !report.pass { failed = true }
        }
        HotkeyService.shared.unregister()
        PanelCoordinator.shared?.releaseCommandKeys()
        exit(failed ? 1 : 0)
    }

    private static func geometryReports() -> [SelfTestReport] {
        var model = DragSessionModel()
        let freshDown = model.beginGesture()
        model.noteTracking()
        let schedules = model.endGesture()
        let pending = model.endPending
        let clickEnds = model.beginGesture()
        let cleared = !model.tracking && !model.endPending
        let idleUp = model.endGesture()
        let pass7 = !freshDown && schedules && pending && clickEnds && cleared && !idleUp
        let drag = SelfTestReport(
            scenario: 7,
            pass: pass7,
            detail: pass7 ? "a later click ends the previous drag session" : "drag session flags did not match")

        let expanded = DropzoneMetrics.pillSize(phase: .ready, proximity: true)
        let pill = DropzoneMetrics.pillRect(size: expanded, anchor: .topCenter)
        let margin = CGPoint(x: pill.minX - 8, y: pill.midY)
        let corner = CGPoint(x: pill.minX + 0.5, y: pill.minY + 0.5)
        let inside = CGPoint(x: pill.midX, y: pill.midY)
        let panel = CGRect(origin: .zero, size: DropzoneMetrics.panel)
        let pass8 = panel.contains(margin)
            && !DropzoneMetrics.contains(margin, pill: pill, puck: false)
            && !DropzoneMetrics.contains(corner, pill: pill, puck: false)
            && DropzoneMetrics.contains(inside, pill: pill, puck: false)
        let drop = SelfTestReport(
            scenario: 8,
            pass: pass8,
            detail: pass8 ? "margin and capsule corner are outside the pill" : "pill geometry accepted a margin point")
        return [drag, drop]
    }

    private static func keyboardReports() async -> [SelfTestReport] {
        let settings = SettingsStore()
        let store = JobStore(settings: settings)
        let coordinator = PanelCoordinator(store: store, settings: settings)
        store.start()
        coordinator.install()
        NSApp.activate()
        coordinator.showTray(makeKey: true)
        try? await Task.sleep(for: .milliseconds(80))
        if coordinator.tray.isKeyWindow == false {
            coordinator.tray.makeKey()
            coordinator.installCommandKeysIfSafe()
        }
        let expected = TrayHotkeyChord.tray.count
        let shown = coordinator.trayOpen && coordinator.trayPresented && coordinator.tray.isKeyWindow
            && HotkeyService.shared.trayChordCount == expected

        coordinator.beginPanelSession()
        coordinator.installCommandKeysIfSafe()
        let duringPanel = HotkeyService.shared.trayChordCount == 0

        coordinator.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: coordinator.tray))
        let afterResign = HotkeyService.shared.trayChordCount == 0 && coordinator.trayOpen

        coordinator.endPanelSession()
        coordinator.tray.makeKey()
        coordinator.installCommandKeysIfSafe()
        let restored = coordinator.tray.isKeyWindow && HotkeyService.shared.trayChordCount == expected

        coordinator.applicationFocusChanged(active: false)
        let blurred = HotkeyService.shared.trayChordCount == 0
        coordinator.applicationFocusChanged(active: true)
        coordinator.tray.makeKey()
        coordinator.installCommandKeysIfSafe()
        let refocused = HotkeyService.shared.trayChordCount == expected

        let pass2 = shown && duringPanel && afterResign && restored && blurred && refocused
        let keys = SelfTestReport(
            scenario: 2,
            pass: pass2,
            detail: pass2
                ? "command keys drop on resign, panel, and deactivation"
                : "shown \(shown) panel \(duringPanel) resign \(afterResign) restored \(restored) blur \(blurred) focus \(refocused) count \(HotkeyService.shared.trayChordCount)")

        coordinator.dismissTray()
        try? await Task.sleep(for: .milliseconds(40))
        coordinator.showTray(makeKey: true)
        try? await Task.sleep(for: .milliseconds(400))
        let visible = coordinator.trayOpen && coordinator.trayPresented && coordinator.tray.isVisible
        let holdsKeys = HotkeyService.shared.trayChordCount
        let keysFollowFocus = coordinator.tray.isKeyWindow ? holdsKeys == expected : holdsKeys == 0
        let pass6 = visible && keysFollowFocus
        let reopen = SelfTestReport(
            scenario: 6,
            pass: pass6,
            detail: pass6
                ? "reopen during dismiss kept the tray visible"
                : "open \(coordinator.trayOpen) presented \(coordinator.trayPresented) visible \(coordinator.tray.isVisible) key \(coordinator.tray.isKeyWindow) chords \(holdsKeys)")
        coordinator.dismissTray()
        return [keys, reopen]
    }
}

/// History safety. Prints one JSON line per scenario and exits non-zero on a failure.
///
/// Isolation is installed before any scenario. No scenario reads or writes
/// `~/Library/Application Support/Logn` or the `app.ologn.mac` defaults domain.
@MainActor
enum HistorySelfTest {
    struct Scratch {
        var root: URL
        var support: URL
        var sentinel: URL
        var suiteName: String
    }

    static func run() async {
        let scratch = installScratch()
        var reports: [(String, Bool, String)] = []
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await demoWritesNothing(scratch))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await quitKeepsHistory(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await malformedKeepsSiblings(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await reusedOutputRefused(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await resolvedLocationRoundTrips(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await staleSaveLosesToClear(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await undoPersistsRemoval(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await folderReplaceDisabled(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await sourceStampGatesReveal(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await historyCapBoundsLiveCards(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await permissionFailureRestores(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(await quickLookRespectsTrayGeneration(scratch.root))
        await HistoryWriter.shared.resetAppliedGeneration()
        reports.append(scratchSentinelIntact(scratch))
        var failed = false
        for (name, pass, detail) in reports {
            let safe = detail
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "'")
            print("{\"scenario\":\"\(name)\",\"pass\":\(pass),\"detail\":\"\(safe)\"}")
            fflush(stdout)
            if !pass { failed = true }
        }
        exit(failed ? 1 : 0)
    }

    /// Scratch app support, scratch defaults, and a sentinel in each. Registered for exit cleanup.
    private static func installScratch() -> Scratch {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ologn-history-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let sentinel = support.appendingPathComponent("SENTINEL")
        try? Data("sentinel-do-not-touch".utf8).write(to: sentinel)
        HistoryStore.directoryOverride = support
        let suiteName = root.appendingPathComponent("defaults-suite").path
        SelfTestIsolation.directory = root
        SelfTestIsolation.suiteName = suiteName
        SelfTestIsolation.cleanUpAtExit()
        // Fail closed: never fall back to the user's real defaults domain.
        guard let suite = UserDefaults(suiteName: suiteName) else {
            SelfTestIsolation.abort("could not create the scratch defaults suite")
        }
        suite.set("sentinel", forKey: "ologn.sentinel")
        SettingsStorage.defaults = suite
        SettingsStorage.persistsWrites = true
        return Scratch(root: root, support: support, sentinel: sentinel, suiteName: suiteName)
    }

    private static func demoWritesNothing(_ scratch: Scratch) async -> (String, Bool, String) {
        let beforeTemps = demoTempNames()
        let beforeSentinel = (try? Data(contentsOf: scratch.sentinel)) ?? Data()
        let beforeSupport = directoryNames(scratch.support)
        let beforeSettings = suiteData(scratch.suiteName, key: Logn.defaultsKey)
        let beforeSentinelKey = suiteString(scratch.suiteName, key: "ologn.sentinel")
        SettingsStorage.persistsWrites = false
        defer { SettingsStorage.persistsWrites = true }
        let settings = SettingsStore()
        settings.skipLoginItem = true
        let store = JobStore(settings: settings, simulated: true)
        store.persistsHistory = false
        store.start(loadHistory: false)
        let fixture = Demo.installPopulatedPreview(into: store)
        var thumbs = 0
        for item in fixture.items {
            let url = item.outputURL ?? item.job.request.source
            if await ThumbnailLoader.image(for: url, side: 38) != nil { thumbs += 1 }
        }
        if let cancelled = store.items.first(where: { if case .cancelled = $0.job.state { return true }; return false }) {
            store.retry(cancelled.id)
        }
        if let compressed = store.items.first(where: { $0.outputFingerprint != nil && !$0.replaced }) {
            await store.replaceOriginal(compressed.id)
            await store.trashOutput(compressed.id)
        }
        settings.setLaunchAtLogin(true)
        settings.settings.engine.suffix = "-probe"
        settings.settings.engine.archiveFormat = .zip
        let pass = thumbs == fixture.items.count
            && beforeTemps == demoTempNames()
            && beforeSentinel == ((try? Data(contentsOf: scratch.sentinel)) ?? Data())
            && beforeSupport == directoryNames(scratch.support)
            && beforeSettings == suiteData(scratch.suiteName, key: Logn.defaultsKey)
            && beforeSentinelKey == "sentinel"
            && suiteString(scratch.suiteName, key: "ologn.sentinel") == "sentinel"
        return ("demo-writes-nothing", pass, pass
            ? "populated demo wrote nothing under scratch support, temp, or defaults"
            : "thumbs \(thumbs)/\(fixture.items.count) temps \(demoTempNames()) support \(directoryNames(scratch.support))")
    }

    private static func quitKeepsHistory(_ root: URL) async -> (String, Bool, String) {
        let directory = root.appendingPathComponent("quit", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let source = directory.appendingPathComponent("keep-source.txt")
        let output = directory.appendingPathComponent("keep-output.txt")
        do {
            let stamps = try await writePair(source: source, output: output, sourceBytes: Data("source".utf8), outputBytes: Data("output".utf8))
            guard let entry = entry(source: source, output: output, sourceStamp: stamps.source, outputStamp: stamps.output) else {
                return ("quit-keeps-history", false, "could not build an entry")
            }
            guard try await JobFileWork.runDetached({
                HistoryStore.writeFile([entry], url: HistoryStore.fileURL)
            }) else {
                return ("quit-keeps-history", false, "could not write history")
            }
            let before = try Data(contentsOf: HistoryStore.fileURL)
            let store = JobStore(settings: SettingsStore())
            store.start()
            store.flushHistoryForQuit()
            let after = try Data(contentsOf: HistoryStore.fileURL)
            await wait(store)
            let pass = before == after && store.historyPhase == .restored
            return ("quit-keeps-history", pass, pass
                ? "flush during load left the file untouched"
                : "history changed during load or restore failed")
        } catch {
            return ("quit-keeps-history", false, "\(error)")
        }
    }

    private static func malformedKeepsSiblings(_ root: URL) async -> (String, Bool, String) {
        let directory = root.appendingPathComponent("malformed", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let first = directory.appendingPathComponent("one.txt")
        let firstOut = directory.appendingPathComponent("one-out.txt")
        let second = directory.appendingPathComponent("two.txt")
        let secondOut = directory.appendingPathComponent("two-out.txt")
        do {
            let left = try await writePair(source: first, output: firstOut, sourceBytes: Data("one".utf8), outputBytes: Data("one-out".utf8))
            let right = try await writePair(source: second, output: secondOut, sourceBytes: Data("two".utf8), outputBytes: Data("two-out".utf8))
            guard let entryA = entry(source: first, output: firstOut, sourceStamp: left.source, outputStamp: left.output),
                  let entryB = entry(source: second, output: secondOut, sourceStamp: right.source, outputStamp: right.output)
            else { return ("malformed-entry", false, "could not build entries") }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom(HistoryDates.encode)
            let encodedA = try encoder.encode(entryA)
            let encodedB = try encoder.encode(entryB)
            let raw = "[\(String(decoding: encodedA, as: UTF8.self)),{\"outcome\":\"compressed\"},\(String(decoding: encodedB, as: UTF8.self))]"
            try await JobFileWork.runDetached {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(raw.utf8).write(to: HistoryStore.fileURL, options: .atomic)
            }
            let loaded = await HistoryStore.load(keepingDays: 7)
            guard case .restored(let items) = loaded else {
                return ("malformed-entry", false, "the whole file was rejected")
            }
            let again = await HistoryStore.load(keepingDays: 7)
            guard case .restored(let second) = again else {
                return ("malformed-entry", false, "the second load failed")
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let corruptNames = names.filter { $0.hasPrefix("history.corrupt-") && $0.hasSuffix(".json") }
            let corrupt = corruptNames.first.flatMap { try? String(contentsOfFile: directory.appendingPathComponent($0).path, encoding: .utf8) } ?? ""
            let kept = Set(items.map { $0.job.request.source.lastPathComponent })
            let keptAgain = Set(second.map { $0.job.request.source.lastPathComponent })
            let live = (try? String(contentsOf: HistoryStore.fileURL, encoding: .utf8)) ?? ""
            let pass = items.count == 2
                && second.count == 2
                && kept == ["one.txt", "two.txt"]
                && keptAgain == kept
                && corruptNames.count == 1
                && corrupt.contains("\"outcome\":\"compressed\"")
                && live.contains("one.txt")
                && live.contains("two.txt")
            return ("malformed-entry", pass, pass
                ? "two loads kept both cards and the corrupt original was copied aside"
                : "first \(kept.sorted()) second \(keptAgain.sorted()) corrupt \(corruptNames)")
        } catch {
            return ("malformed-entry", false, "\(error)")
        }
    }

    private static func reusedOutputRefused(_ root: URL) async -> (String, Bool, String) {
        let live = await liveRaceRefused(root)
        guard live.1 else { return live }
        let directory = root.appendingPathComponent("reused", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let source = directory.appendingPathComponent("photo.txt")
        let output = directory.appendingPathComponent("photo-min.txt")
        do {
            let stamps = try await writePair(source: source, output: output, sourceBytes: Data("original-source-is-larger".utf8), outputBytes: Data("out".utf8))
            guard let entry = entry(source: source, output: output, sourceStamp: stamps.source, outputStamp: stamps.output) else {
                return ("reused-output", false, "could not build an entry")
            }
            try await JobFileWork.runDetached {
                HistoryStore.writeFile([entry], url: HistoryStore.fileURL)
                try Data("a different file took this name".utf8).write(to: output, options: .atomic)
            }
            let before = try Data(contentsOf: output)
            let store = JobStore(settings: SettingsStore())
            store.start(loadHistory: true)
            await wait(store)
            store.persistsHistory = false
            guard store.historyPhase == .restored, let id = store.items.first?.id else {
                return ("reused-output", false, "restore did not produce a card")
            }
            let claimed = await store.claimOutput(id)
            await store.trashOutput(id)
            await store.replaceOriginal(id)
            let coordinator = PanelCoordinator(store: store, settings: SettingsStore())
            let pill = await coordinator.urlsForDoneClick([id])
            let after = try Data(contentsOf: output)
            let message = store.items.first?.actionError ?? ""
            let pass = claimed == nil && pill.isEmpty && before == after && message == "The compressed file is no longer the one Logn wrote"
            return ("reused-output", pass, pass
                ? "live race, restore, trash, replace, and the Done pill refused the reused name"
                : "claim \(claimed?.path ?? "nil") pill \(pill.count) message \(message)")
        } catch {
            return ("reused-output", false, "\(error)")
        }
    }

    /// The stamp is already on the card when the terminal event lands. Replacing the file
    /// after that must not become the card's identity, and the Done pill must not hand it out.
    private static func liveRaceRefused(_ root: URL) async -> (String, Bool, String) {
        let directory = root.appendingPathComponent("reused-live", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let source = directory.appendingPathComponent("notes.txt")
        do {
            let prose = String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 400)
            try await JobFileWork.runDetached {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(prose.utf8).write(to: source)
            }
            let settings = SettingsStore()
            let store = JobStore(settings: settings)
            store.persistsHistory = false
            store.start(loadHistory: false)
            let batch = store.submit([source], mode: .lossless)
            let status = await store.waitForBatch(batch, timeout: .seconds(30))
            guard status == "compressed", let item = store.items.first,
                  let stamp = item.outputFingerprint, let url = item.outputURL
            else {
                return ("reused-output", false, "live job \(status) stamp missing")
            }
            let published = try await JobFileWork.runDetached { try SourceFingerprint.capture(url) }
            guard published == stamp else {
                return ("reused-output", false, "engine stamp does not match the published file")
            }
            try await JobFileWork.runDetached {
                try Data("usurper-took-this-name".utf8).write(to: url, options: .atomic)
            }
            let claimed = await store.claimOutput(item.id)
            let coordinator = PanelCoordinator(store: store, settings: settings)
            let pill = await coordinator.urlsForDoneClick([item.id])
            let pass = claimed == nil && pill.isEmpty
            return ("reused-output", pass, pass
                ? "live"
                : "live claim \(claimed?.path ?? "nil") pill \(pill.count)")
        } catch {
            return ("reused-output", false, "live \(error)")
        }
    }

    private static func resolvedLocationRoundTrips(_ root: URL) async -> (String, Bool, String) {
        let directory = root.appendingPathComponent("resolved", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let source = directory.appendingPathComponent("scan.png")
        let output = directory.appendingPathComponent("scan-min.png")
        let original = Data("ORIGINAL-PNG-BYTES".utf8)
        let compressed = Data("MIN".utf8)
        do {
            let stamps = try await writePair(source: source, output: output, sourceBytes: original, outputBytes: compressed)
            guard let stored = entry(
                source: source,
                output: output,
                sourceStamp: stamps.source,
                outputStamp: stamps.output,
                kind: .png
            ) else {
                return ("resolved-location", false, "terminal item did not encode")
            }
            guard try await JobFileWork.runDetached({
                HistoryStore.writeFile([stored], url: HistoryStore.fileURL)
            }) else {
                return ("resolved-location", false, "could not write history")
            }
            let settings = SettingsStore()
            let store = JobStore(settings: settings)
            store.start()
            await wait(store)
            guard let id = store.items.first?.id else {
                return ("resolved-location", false, "restore did not produce a card")
            }
            await store.replaceOriginal(id)
            let installed = try await JobFileWork.runDetached { try Data(contentsOf: source) }
            let outputGone = try await JobFileWork.runDetached { !FileManager.default.fileExists(atPath: output.path) }
            guard installed == compressed, outputGone else {
                return ("resolved-location", false, "replace did not install the output onto the original")
            }
            await store.undoLastReplace()
            let restoredOriginal = try await JobFileWork.runDetached { try Data(contentsOf: source) }
            let restoredOutput = try await JobFileWork.runDetached { try Data(contentsOf: output) }
            let cardURL = store.items.first?.outputURL?.lastPathComponent
            await store.persistHistoryNow(minimumDays: 7)
            let again = JobStore(settings: settings)
            again.start()
            await wait(again)
            let second = again.items.first?.outputURL?.lastPathComponent
            let pass = restoredOriginal == original
                && restoredOutput == compressed
                && cardURL == "scan-min.png"
                && second == "scan-min.png"
            return ("resolved-location", pass, pass
                ? "replace and undo restored scan-min.png and the reloaded card kept it"
                : "card \(cardURL ?? "nil") second \(second ?? "nil")")
        } catch {
            return ("resolved-location", false, "\(error)")
        }
    }

    private static func staleSaveLosesToClear(_ root: URL) async -> (String, Bool, String) {
        let directory = root.appendingPathComponent("stale", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let first = directory.appendingPathComponent("keep.txt")
        let firstOut = directory.appendingPathComponent("keep-min.txt")
        let second = directory.appendingPathComponent("drop.txt")
        let secondOut = directory.appendingPathComponent("drop-min.txt")
        do {
            let left = try await writePair(source: first, output: firstOut, sourceBytes: Data("keep-source".utf8), outputBytes: Data("k".utf8))
            let right = try await writePair(source: second, output: secondOut, sourceBytes: Data("drop-source".utf8), outputBytes: Data("d".utf8))
            guard let entryA = entry(source: first, output: firstOut, sourceStamp: left.source, outputStamp: left.output),
                  let entryB = entry(source: second, output: secondOut, sourceStamp: right.source, outputStamp: right.output)
            else { return ("stale-clear", false, "could not build entries") }
            guard try await JobFileWork.runDetached({
                HistoryStore.writeFile([entryA, entryB], url: HistoryStore.fileURL)
            }) else {
                return ("stale-clear", false, "could not write history")
            }
            let store = JobStore(settings: SettingsStore())
            store.start()
            await wait(store)
            guard store.items.count == 2, let doomed = store.items.last else {
                return ("stale-clear", false, "restore did not produce two cards")
            }
            store.remove(doomed.id)
            store.clearFinished()
            var exists = true
            for _ in 0..<40 {
                exists = FileManager.default.fileExists(atPath: HistoryStore.fileURL.path)
                if !exists { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let pass = !exists && store.items.isEmpty
            return ("stale-clear", pass, pass
                ? "the older save did not recreate the file the clear removed"
                : "exists \(exists) cards \(store.items.count)")
        } catch {
            return ("stale-clear", false, "\(error)")
        }
    }

    private static func undoPersistsRemoval(_ root: URL) async -> (String, Bool, String) {
        let directory = root.appendingPathComponent("undo-persist", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let source = directory.appendingPathComponent("card.txt")
        let output = directory.appendingPathComponent("card-min.txt")
        do {
            let stamps = try await writePair(source: source, output: output, sourceBytes: Data("card-source".utf8), outputBytes: Data("c".utf8))
            guard let stored = entry(source: source, output: output, sourceStamp: stamps.source, outputStamp: stamps.output) else {
                return ("undo-persists", false, "could not build an entry")
            }
            guard try await JobFileWork.runDetached({
                HistoryStore.writeFile([stored], url: HistoryStore.fileURL)
            }) else {
                return ("undo-persists", false, "could not write history")
            }
            let store = JobStore(settings: SettingsStore())
            store.start()
            await wait(store)
            guard store.items.count == 1 else {
                return ("undo-persists", false, "restore did not produce a card")
            }
            store.clearFinished()
            await store.undoLastReplace()
            var loaded = await HistoryStore.load(keepingDays: 7)
            for _ in 0..<40 {
                if case .restored(let items) = loaded, items.count == 1 { break }
                try? await Task.sleep(for: .milliseconds(50))
                loaded = await HistoryStore.load(keepingDays: 7)
            }
            guard case .restored(let items) = loaded else {
                return ("undo-persists", false, "history did not load after undo")
            }
            let pass = store.items.count == 1 && items.count == 1
                && items[0].job.request.source.lastPathComponent == "card.txt"
            return ("undo-persists", pass, pass
                ? "undo of clear wrote the card back to history"
                : "memory \(store.items.count) file \(items.count)")
        } catch {
            return ("undo-persists", false, "\(error)")
        }
    }

    private static func folderReplaceDisabled(_ root: URL) async -> (String, Bool, String) {
        let directory = root.appendingPathComponent("folder", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let source = directory.appendingPathComponent("Album", isDirectory: true)
        let output = directory.appendingPathComponent("Album.tar.xz")
        do {
            let stamps = try await JobFileWork.runDetached { () throws -> (SourceFingerprint, SourceFingerprint) in
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try Data("child-bytes-that-are-long-enough".utf8).write(to: source.appendingPathComponent("a.txt"))
                try Data("xz".utf8).write(to: output)
                return (try SourceFingerprint.capture(source), try SourceFingerprint.capture(output))
            }
            let result = JobResult(
                outcome: .compressed,
                kind: .folder,
                method: "tar.xz",
                lossless: true,
                verified: true,
                inputBytes: stamps.0.size,
                outputBytes: stamps.1.size,
                outputURL: output,
                note: nil,
                duration: 0.1,
                sourceFingerprint: stamps.0,
                outputFingerprint: stamps.1)
            let job = Job(
                id: JobID(),
                request: JobRequest(source: source, mode: .lossless, settings: EngineSettings()),
                kind: .folder,
                inputBytes: stamps.0.size,
                createdAt: Date(),
                state: .finished(result))
            var item = JobItem(job: job)
            item.outputFingerprint = stamps.1
            item.pin = OutputPin.pinned(output)
            let before = try Data(contentsOf: output)
            let store = JobStore(settings: SettingsStore())
            store.installPreview([item], sessionSaved: result.savedBytes, toast: nil)
            let help = store.items[0].replaceOriginalHelp
            let enabled = store.items[0].canReplaceOriginal
            await store.replaceOriginal(item.id)
            let after = try Data(contentsOf: output)
            let sourceStill = FileManager.default.fileExists(atPath: source.path)
            let message = store.items.first?.actionError ?? ""
            let pass = !enabled && sourceStill && before == after && message == help
                && help == "Replace Original is unavailable for folders. The archive keeps the original folder."
            return ("folder-replace", pass, pass
                ? "folder replace is disabled and explains that the archive keeps the folder"
                : "enabled \(enabled) message \(message)")
        } catch {
            return ("folder-replace", false, "\(error)")
        }
    }

    private static func sourceStampGatesReveal(_ root: URL) async -> (String, Bool, String) {
        let directory = root.appendingPathComponent("source-stamp", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let source = directory.appendingPathComponent("notes.txt")
        do {
            let stamp = try await JobFileWork.runDetached { () throws -> SourceFingerprint in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("original-notes".utf8).write(to: source)
                return try SourceFingerprint.capture(source)
            }
            let result = JobResult(
                outcome: .alreadyOptimal,
                kind: .generic,
                method: "",
                lossless: true,
                verified: true,
                inputBytes: stamp.size,
                outputBytes: stamp.size,
                outputURL: nil,
                note: nil,
                duration: 0.01,
                sourceFingerprint: stamp)
            let job = Job(
                id: JobID(),
                request: JobRequest(source: source, mode: .lossless, settings: EngineSettings()),
                kind: .generic,
                inputBytes: stamp.size,
                createdAt: Date(),
                state: .finished(result))
            let item = JobItem(job: job)
            let store = JobStore(settings: SettingsStore())
            store.persistsHistory = false
            store.installPreview([item], sessionSaved: 0, toast: nil)
            let matched = await store.claimActionURL(item.id)
            try await JobFileWork.runDetached {
                try Data("rewritten-notes-now".utf8).write(to: source, options: .atomic)
            }
            let refused = await store.claimActionURL(item.id)
            let message = store.items.first?.actionError ?? ""
            let pass = matched == source && refused == nil && message == "The original changed after compression"
            return ("source-stamp", pass, pass
                ? "an output-less card reveals its source only while the stamp matches"
                : "matched \(matched?.path ?? "nil") message \(message)")
        } catch {
            return ("source-stamp", false, "\(error)")
        }
    }

    private static func historyCapBoundsLiveCards(_ root: URL) async -> (String, Bool, String) {
        let directory = root.appendingPathComponent("cap", isDirectory: true)
        HistoryStore.directoryOverride = directory
        do {
            var entries: [HistoryEntry] = []
            let now = Date()
            for index in 0..<2_001 {
                let name = String(format: "cap-%04d.txt", index)
                let source = directory.appendingPathComponent(name)
                let output = directory.appendingPathComponent(String(format: "cap-%04d-min.txt", index))
                let sourceStamp = SourceFingerprint(size: 20, modificationDate: now, fileID: UInt64(index + 1))
                let outputStamp = SourceFingerprint(size: 4, modificationDate: now, fileID: UInt64(index + 10_000))
                guard let stored = entry(
                    source: source,
                    output: output,
                    sourceStamp: sourceStamp,
                    outputStamp: outputStamp,
                    createdAt: now.addingTimeInterval(Double(-index))
                ) else {
                    return ("history-cap", false, "could not build entry \(index)")
                }
                entries.append(stored)
            }
            let storedEntries = entries
            guard try await JobFileWork.runDetached({
                HistoryStore.writeFile(storedEntries, url: HistoryStore.fileURL)
            }) else {
                return ("history-cap", false, "could not write history")
            }
            let settings = SettingsStore()
            let store = JobStore(settings: settings)
            store.start()
            await wait(store)
            guard store.items.count == HistoryStore.cap else {
                return ("history-cap", false, "load kept \(store.items.count)")
            }
            let fresh = directory.appendingPathComponent("fresh.txt")
            let prose = String(repeating: "cap the live history after a terminal job\n", count: 80)
            try await JobFileWork.runDetached { try Data(prose.utf8).write(to: fresh) }
            let batch = store.submit([fresh], mode: .lossless)
            let status = await store.waitForBatch(batch, timeout: .seconds(30))
            let names = Set(store.items.map { $0.job.request.source.lastPathComponent })
            let terminal = store.items.filter { $0.job.state.isTerminal }.count
            let pass = status == "compressed"
                && terminal == HistoryStore.cap
                && names.contains("fresh.txt")
                && !names.contains("cap-2000.txt")
                && !names.contains("cap-1999.txt")
            return ("history-cap", pass, pass
                ? "load and a new terminal job both stay at \(HistoryStore.cap)"
                : "status \(status) terminal \(terminal) has fresh \(names.contains("fresh.txt"))")
        } catch {
            return ("history-cap", false, "\(error)")
        }
    }

    private static func permissionFailureRestores(_ root: URL) async -> (String, Bool, String) {
        let directory = root.appendingPathComponent("permission", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let source = directory.appendingPathComponent("locked.pdf")
        let job = Job(
            id: JobID(),
            request: JobRequest(source: source, mode: .smart, settings: EngineSettings()),
            kind: .pdf,
            inputBytes: 512,
            createdAt: Date(),
            state: .failed(.outputNotWritable("No write permission")))
        guard let stored = HistoryEntry(JobItem(job: job)) else {
            return ("permission-restore", false, "failed card did not encode")
        }
        do {
            try await JobFileWork.runDetached {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                HistoryStore.writeFile([stored], url: HistoryStore.fileURL)
            }
            let loaded = await HistoryStore.load(keepingDays: 7)
            guard case .restored(let items) = loaded, let item = items.first else {
                return ("permission-restore", false, "load did not restore the card")
            }
            let permission: Bool
            if case .failed(.outputNotWritable) = item.job.state { permission = true } else { permission = false }
            let pass = stored.failureKind == "outputNotWritable" && permission
            return ("permission-restore", pass, pass
                ? "a permission failure round-trips as outputNotWritable"
                : "kind \(stored.failureKind ?? "nil") state \(String(describing: item.job.state))")
        } catch {
            return ("permission-restore", false, "\(error)")
        }
    }

    private static func quickLookRespectsTrayGeneration(_ root: URL) async -> (String, Bool, String) {
        if screenLocked() {
            return ("quicklook-generation", true, "skipped: screen locked")
        }
        let directory = root.appendingPathComponent("quicklook", isDirectory: true)
        HistoryStore.directoryOverride = directory
        let source = directory.appendingPathComponent("photo.txt")
        let output = directory.appendingPathComponent("photo-min.txt")
        do {
            let stamps = try await writePair(
                source: source,
                output: output,
                sourceBytes: Data("quicklook-source-bytes".utf8),
                outputBytes: Data("ql".utf8))
            guard let stored = entry(source: source, output: output, sourceStamp: stamps.source, outputStamp: stamps.output) else {
                return ("quicklook-generation", false, "could not build an entry")
            }
            guard try await JobFileWork.runDetached({
                HistoryStore.writeFile([stored], url: HistoryStore.fileURL)
            }) else {
                return ("quicklook-generation", false, "could not write history")
            }
            let settings = SettingsStore()
            let store = JobStore(settings: settings)
            store.start()
            await wait(store)
            store.persistsHistory = false
            guard let item = store.items.first else {
                return ("quicklook-generation", false, "restore did not produce a card")
            }
            let coordinator = PanelCoordinator(store: store, settings: settings)
            coordinator.install()
            coordinator.showTray(makeKey: false, immediate: true)
            store.selectedID = item.id
            let release = OSAllocatedUnfairLock(initialState: false)
            let started = OSAllocatedUnfairLock(initialState: false)
            let blocker = Task {
                try? await JobFileWork.run(item.id) {
                    started.withLock { $0 = true }
                    let deadline = Date().addingTimeInterval(3)
                    while !release.withLock({ $0 }), Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
            }
            let ready = Date().addingTimeInterval(2)
            while !started.withLock({ $0 }), Date() < ready {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard started.withLock({ $0 }) else {
                release.withLock { $0 = true }
                await blocker.value
                return ("quicklook-generation", false, "file queue did not block")
            }
            let before = coordinator.quickLookPresentations
            coordinator.previewItem(item)
            coordinator.dismissTray()
            release.withLock { $0 = true }
            await blocker.value
            try? await Task.sleep(for: .milliseconds(300))
            coordinator.dismissTray()
            let pass = coordinator.quickLookPresentations == before && coordinator.tray.previewURLs.isEmpty
            return ("quicklook-generation", pass, pass
                ? "a dismiss during the claim did not present Quick Look"
                : "presentations \(coordinator.quickLookPresentations)")
        } catch {
            return ("quicklook-generation", false, "\(error)")
        }
    }

    private static func scratchSentinelIntact(_ scratch: Scratch) -> (String, Bool, String) {
        let bytes = (try? Data(contentsOf: scratch.sentinel)) ?? Data()
        let key = suiteString(scratch.suiteName, key: "ologn.sentinel")
        let pass = bytes == Data("sentinel-do-not-touch".utf8) && key == "sentinel"
        return ("scratch-sentinel", pass, pass
            ? "scratch sentinel file and defaults key survived"
            : "key \(key ?? "nil")")
    }

    private static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private static func demoTempNames() -> [String] {
        let root = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("ologn-demo") }.sorted()
    }

    private static func directoryNames(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private static func suiteData(_ name: String, key: String) -> Data? {
        UserDefaults(suiteName: name)?.data(forKey: key)
    }

    private static func suiteString(_ name: String, key: String) -> String? {
        UserDefaults(suiteName: name)?.string(forKey: key)
    }

    private static func writePair(source: URL, output: URL, sourceBytes: Data, outputBytes: Data) async throws -> (source: SourceFingerprint, output: SourceFingerprint) {
        try await JobFileWork.runDetached {
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sourceBytes.write(to: source, options: .atomic)
            try outputBytes.write(to: output, options: .atomic)
            return (try SourceFingerprint.capture(source), try SourceFingerprint.capture(output))
        }
    }

    private static func entry(
        source: URL,
        output: URL,
        sourceStamp: SourceFingerprint,
        outputStamp: SourceFingerprint,
        createdAt: Date = Date(),
        kind: FileKind = .generic
    ) -> HistoryEntry? {
        let result = JobResult(
            outcome: .compressed,
            kind: kind,
            method: "xz",
            lossless: true,
            verified: true,
            inputBytes: sourceStamp.size,
            outputBytes: outputStamp.size,
            outputURL: output,
            note: nil,
            duration: 0.01,
            sourceFingerprint: sourceStamp,
            outputFingerprint: outputStamp)
        let job = Job(
            id: JobID(),
            request: JobRequest(source: source, mode: .smart, settings: EngineSettings()),
            kind: kind,
            inputBytes: sourceStamp.size,
            createdAt: createdAt,
            state: .finished(result))
        var item = JobItem(job: job)
        item.outputFingerprint = outputStamp
        item.pin = .pinned(output)
        return HistoryEntry(item)
    }

    private static func wait(_ store: JobStore) async {
        for _ in 0..<100 {
            if store.historyPhase != .loading { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
