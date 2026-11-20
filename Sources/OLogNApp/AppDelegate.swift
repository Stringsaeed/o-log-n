import AppKit
import Darwin
import OLogNKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore!
    private let drag = DragMonitor()
    private var store: JobStore!
    private var coordinator: PanelCoordinator!
    private var status: StatusItemController!
    private var outsideGlobal: Any?
    private var outsideLocal: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let glyphDir = argument(after: "--render-glyphs") {
            GlyphRaster.write(into: glyphDir)
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest-history") {
            Task { await HistorySelfTest.run() }
            return
        }
        let demoSurface = argument(after: "--demo-open")
        let demo = CommandLine.arguments.contains("--demo") || demoSurface != nil
        let testing = CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains("--selftest-replace")
            || CommandLine.arguments.contains("--selftest-keys")
            || CommandLine.arguments.contains("--bench-tray")
        if testing {
            installSelfTestIsolation()
        }
        if demo {
            SettingsStorage.persistsWrites = false
        }
        settings = SettingsStore()
        if demo {
            settings.skipLoginItem = true
        }
        applyAppearance()
        if CommandLine.arguments.contains("--selftest-replace") {
            Task { await ReplaceSelfTest.run() }
            return
        }
        if CommandLine.arguments.contains("--selftest-keys") {
            Task { await KeySelfTest.run() }
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            Task { await self.selfTest() }
            return
        }
        if CommandLine.arguments.contains("--bench-tray") {
            benchTray()
            return
        }
        if demo {
            launchDemo(surface: demoSurface ?? "tray")
            return
        }
        launchNormal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ChildProcesses.terminateAll()
        store?.flushHistoryForQuit()
    }

    /// Selftests must not read or write the user's history or `settings.v1`.
    private func installSelfTestIsolation() {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ologn-support-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        HistoryStore.directoryOverride = directory
        // An absolute-path suite keeps the selftest's plist inside the temp dir (cfprefsd otherwise
        // re-creates an empty ~/Library/Preferences/<suite>.plist after we delete it at exit).
        let suiteName = directory.appendingPathComponent("selftest-defaults").path
        SelfTestIsolation.directory = directory
        SelfTestIsolation.suiteName = suiteName
        SelfTestIsolation.cleanUpAtExit()
        // Fail closed: without a scratch suite, a selftest would fall back to the user's real defaults.
        guard let suite = UserDefaults(suiteName: suiteName) else {
            SelfTestIsolation.abort("could not create the scratch defaults suite")
        }
        SettingsStorage.defaults = suite
        SettingsStorage.persistsWrites = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidResignActive(_ notification: Notification) {
        coordinator?.applicationFocusChanged(active: false)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator?.applicationFocusChanged(active: true)
    }

    private func installClickOutside() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        outsideGlobal = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { PanelCoordinator.shared?.clickOutside() }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PanelCoordinator.shared?.clickOutside() }
                }
            }
        }
        outsideLocal = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { PanelCoordinator.shared?.clickOutside() }
            return event
        }
    }

    private func launchNormal() {
        store = JobStore(settings: settings)
        coordinator = PanelCoordinator(store: store, settings: settings)
        status = StatusItemController(store: store, settings: settings, coordinator: coordinator)
        store.start()
        coordinator.install()
        settings.onChange = { [weak self] in
            guard let self else { return }
            _ = HotkeyService.shared.sync(
                keyCode: self.settings.settings.hotkeyKeyCode,
                modifiers: self.settings.settings.hotkeyModifiers)
            self.coordinator.applyPresence()
            self.status.refresh()
        }
        HotkeyService.shared.onFire = { [weak coordinator] in
            coordinator?.toggleTray()
        }
        coordinator.onSurfaceChange = { [weak status] in
            status?.refresh()
        }
        drag.onBegan = { [weak coordinator] in coordinator?.fileDragBegan() }
        drag.onMoved = { [weak coordinator] in coordinator?.fileDragMoved() }
        drag.onEnded = { [weak coordinator] in coordinator?.fileDragEnded() }
        _ = HotkeyService.shared.sync(
            keyCode: settings.settings.hotkeyKeyCode,
            modifiers: settings.settings.hotkeyModifiers)
        if !drag.start() { settings.noteDragUnavailable() }
        coordinator.applyPresence()
        status.install()
        installClickOutside()
        settings.syncLoginItem()
    }

    private func launchDemo(surface: String) {
        store = JobStore(settings: settings, simulated: true)
        store.persistsHistory = false
        coordinator = PanelCoordinator(store: store, settings: settings)
        coordinator.forceReduceMotion = CommandLine.arguments.contains("--reduce-motion")
        coordinator.forceReduceTransparency = CommandLine.arguments.contains("--reduce-transparency")
        status = StatusItemController(store: store, settings: settings, coordinator: coordinator)
        coordinator.install()
        store.start(loadHistory: false)
        let empty = CommandLine.arguments.contains("--demo-empty")
        var fixture: Demo.Fixture?
        if empty {
            store.installPreview([], sessionSaved: 0, toast: nil)
        } else {
            fixture = Demo.installPopulatedPreview(
                into: store,
                paused: surface == "tray" ? "disk full" : nil)
        }
        coordinator.holdForDemo()
        status.install()
        switch surface {
        case "settings":
            coordinator.settingsOpen = true
            coordinator.showTray(makeKey: true, immediate: true)
        case "dropzone-smart":
            coordinator.presentDemoDrop(aim: .smart)
        case "dropzone-lossless":
            coordinator.presentDemoDrop(aim: .lossless)
        case "dropzone-compressing":
            coordinator.presentDemoCompressing(headline: "Coast.mov", subline: "40% · 12 MB/s")
        case "dropzone-puck":
            coordinator.presentDemoPuck()
        case "dropzone-done":
            coordinator.presentDemoDone(
                url: fixture?.previewURL,
                headline: fixture?.doneHeadline ?? "−64%",
                subline: fixture?.doneSubline ?? "")
        default:
            coordinator.showTray(makeKey: true, immediate: true)
        }
        if let raw = argument(after: "--demo-height"), let height = Double(raw), height > 0 {
            coordinator.fitDemoTray(height: height)
        }
        if CommandLine.arguments.contains("--demo-drag") {
            coordinator.setTrayDrag(active: true, localX: 40)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            self.writeDemoReady()
        }
    }

    private func benchTray() {
        store = JobStore(settings: settings)
        store.persistsHistory = false
        coordinator = PanelCoordinator(store: store, settings: settings)
        coordinator.install()
        store.start(loadHistory: false)
        store.installPreview(Demo.benchItems(200), sessionSaved: 1_200_000, toast: nil)
        let start = ContinuousClock.now
        coordinator.showTray(makeKey: false, immediate: true)
        coordinator.tray.contentView?.layoutSubtreeIfNeeded()
        let milliseconds = start.duration(to: .now) / .milliseconds(1)
        print("{\"trayOpenMs\":\(String(format: "%.2f", milliseconds))}")
        fflush(stdout)
        exit(milliseconds < 100 ? 0 : 1)
    }

    private func applyAppearance() {
        switch argument(after: "--appearance") {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            break
        }
    }

    private func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag) else { return nil }
        let next = args.index(after: index)
        guard next < args.endIndex else { return nil }
        let value = args[next]
        if value.hasPrefix("--") { return nil }
        return value
    }

    private func writeDemoReady() {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let payload = """
        {"tray":\(coordinator.trayWindowNumber),"drop":\(coordinator.dropWindowNumber),"status":\(status.windowNumber),"trayRect":\(screenRect(coordinator.tray.frame, screenHeight: screenHeight)),"dropRect":\(screenRect(coordinator.drop.frame, screenHeight: screenHeight))}
        """
        print("demo-ready \(payload)")
        fflush(stdout)
    }

    /// `screencapture -R` uses a top-left origin on the primary display.
    private func screenRect(_ frame: CGRect, screenHeight: CGFloat) -> String {
        let y = screenHeight - frame.origin.y - frame.height
        return String(format: "[%.1f,%.1f,%.1f,%.1f]", frame.origin.x, y, frame.width, frame.height)
    }

    /// Builds both panels offscreen, round-trips the hotkey and drag monitor, and compresses 1 MiB of text.
    /// Then persists that job and round-trips `AppSettings`. Autosave stays off so a late write cannot
    /// replace the file after the temp directory is removed.
    private func selfTest() async {
        guard let screen = NSScreen.screens.first else {
            print("{\"error\":\"no screen\"}")
            fflush(stdout)
            exit(2)
        }
        store = JobStore(settings: settings)
        store.persistsHistory = false
        coordinator = PanelCoordinator(store: store, settings: settings)
        store.start(loadHistory: false)
        coordinator.install()
        let trayFrame = PanelGeometry.trayFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let anchor: DropzoneAnchor = settings.settings.presence == .onDrag ? .topCenter : settings.settings.anchor
        let dropFrame = PanelGeometry.dropzoneFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            anchor: anchor)
        coordinator.tray.setFrame(trayFrame, display: false)
        coordinator.drop.setFrame(dropFrame, display: false)
        coordinator.tray.orderOut(nil)
        coordinator.drop.orderOut(nil)

        let hotkeyStatus = HotkeyService.shared.sync(
            keyCode: settings.settings.hotkeyKeyCode,
            modifiers: settings.settings.hotkeyModifiers)
        HotkeyService.shared.unregister()

        let monitorOK = drag.start()
        drag.stop()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ologn-selftest-\(UUID().uuidString)", isDirectory: true)
        var job = "failed"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("repetitive.txt")
            var bytes = Data()
            bytes.reserveCapacity(1_048_576)
            let unit = Data("Logn compresses repetitive text.\n".utf8)
            while bytes.count < 1_048_576 {
                bytes.append(unit)
            }
            try Data(bytes.prefix(1_048_576)).write(to: file, options: .atomic)
            let batch = store.submit([file], mode: .lossless)
            job = await store.waitForBatch(batch, timeout: .seconds(90))
        } catch {
            job = "failed"
        }
        await store.persistHistoryNow(minimumDays: 7)
        let historyOK = historyFileHasEntries()
        let settingsOK = settingsRoundTrip()
        try? FileManager.default.removeItem(at: directory)
        if !historyOK { fputs("history persist failed\n", stderr) }
        if !settingsOK { fputs("settings round-trip failed\n", stderr) }

        let line = "{\"trayFrame\":\(json(trayFrame)),\"dropzoneFrame\":\(json(dropFrame)),\"hotkeyStatus\":\(hotkeyStatus),\"dragMonitor\":\(monitorOK),\"job\":\"\(job)\",\"presence\":\"\(settings.settings.presence.rawValue)\"}"
        print(line)
        fflush(stdout)
        fflush(stderr)
        exit(hotkeyStatus == noErr && job == "compressed" && historyOK && settingsOK ? 0 : 1)
    }

    private func historyFileHasEntries() -> Bool {
        guard let data = try? Data(contentsOf: HistoryStore.fileURL),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return false }
        return !entries.isEmpty
    }

    private func settingsRoundTrip() -> Bool {
        let snapshot = settings.settings
        SettingsStorage.save(snapshot)
        SettingsStorage.defaults.synchronize()
        return SettingsStorage.load() == snapshot
    }

    private func json(_ rect: CGRect) -> String {
        "[\(num(rect.origin.x)),\(num(rect.origin.y)),\(num(rect.size.width)),\(num(rect.size.height))]"
    }

    private func num(_ value: CGFloat) -> String {
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        if abs(value - rounded) < 0.001 { return String(Int(rounded)) }
        return String(format: "%.3f", Double(value))
    }
}

enum GlyphRaster {
    @MainActor static func write(into directory: String) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        save(StatusGlyph.image(side: 18), name: "menu-glyph.png", to: folder)
        save(StatusGlyph.image(side: 18, progress: 0.40), name: "menu-glyph-progress.png", to: folder)
    }

    /// 18 pt glyph at @2x, so the bitmap is 36×36.
    private static func save(_ image: NSImage, name: String, to folder: URL) {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 36,
            pixelsHigh: 36,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 18, height: 18).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: folder.appendingPathComponent(name))
    }
}

/// Leftovers from a selftest run: a temp app-support directory and a `UserDefaults` suite plist.
enum SelfTestIsolation {
    nonisolated(unsafe) static var directory: URL?
    nonisolated(unsafe) static var suiteName: String?

    /// Selftests end with `exit()` from arbitrary executors. The atexit hook must be registered from a
    /// nonisolated context: a closure formed inside a @MainActor method inherits that isolation and traps
    /// when `exit()` runs it off the main thread.
    nonisolated static func cleanUpAtExit() {
        atexit { SelfTestIsolation.cleanUp() }
    }

    /// Stops a selftest before it can touch real data. Exit code 3 = isolation could not be installed.
    nonisolated static func abort(_ reason: String) -> Never {
        print("{\"scenario\":\"isolation\",\"pass\":false,\"detail\":\"\(reason)\"}")
        fflush(stdout)
        exit(3)
    }

    nonisolated static func cleanUp() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        guard let suiteName else { return }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(atPath: suiteName + ".plist")
    }
}
