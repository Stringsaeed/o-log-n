import AppKit
import Quartz
import SwiftUI
import OLogNKit

// Invariant: no Reveal, Preview, Copy, drag-out, Trash Output, Replace or Undo may act on a file
// unless its identity matches a stamp the engine recorded. Destructive operations must re-check
// identity on the same queue immediately before acting.
//
// Reveal, Preview, Copy, and drag-out ask the store to compare that stamp immediately before a
// URL is handed to Finder, Quick Look, or the pasteboard. The Done pill resolves job ids, not a
// cached path. Quick Look presents only when the tray generation and the selected job still match.

@MainActor
@Observable
final class PanelCoordinator: NSObject, NSWindowDelegate {
    static weak var shared: PanelCoordinator?

    let store: JobStore
    let settings: SettingsStore

    private(set) var tray: TrayPanel!
    private(set) var drop: DropzonePanel!
    private var trayHost: TrayHostingView!
    private var dropHost: DropHostingView!

    var phase: DropPhase = .hidden
    var proximity = false
    var pointerInside = false
    var optionDown = false
    var anchor: DropzoneAnchor = .topCenter
    var headline = ""
    var subline = ""
    var progress = 0.0
    var pillHovered = false
    var dropPresented = false
    var trayPresented = false
    var trayOpen = false
    var settingsOpen = false
    var trayDragActive = false
    var trayAim: CompressionMode?
    var screenWidth: CGFloat = 1440
    var onSurfaceChange: () -> Void = {}

    private var rawAim: CompressionMode?
    private var lastHaptic: CompressionMode?
    private var dragSession = false
    private var dropBatch: UUID?
    private var completionShown = false
    private(set) var doneURLs: [URL] = []
    /// Job ids the Done pill and its drag well may reveal. Paths in `doneURLs` are display only.
    var doneJobIDs: [JobID] = []
    /// Times `presentQuickLook` actually handed a URL to the panel.
    private(set) var quickLookPresentations = 0
    private var dwellToken = 0
    private var visibilityToken = 0
    private var shownAt: ContinuousClock.Instant?
    private var suspendDismiss = false
    private var panelSession = false
    private var quickLookUp = false
    private var trayGeneration = 0
    private var dropScreen: NSScreen?
    private var keyMonitor: Any?
    private var passGlobal: Any?
    private var passLocal: Any?
    private var pinnedToStatus = false

    /// In-process simulation for screenshots. Never written to system settings.
    var forceReduceMotion = false
    var forceReduceTransparency = false
    var reduceMotion: Bool {
        forceReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    var intakeWidth: CGFloat { screenWidth >= 1600 ? 264 : 224 }

    var targeted: CompressionMode? {
        guard pointerInside else { return nil }
        let base = rawAim ?? settings.settings.defaultMode
        return optionDown ? base.flipped : base
    }

    init(store: JobStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        super.init()
    }

    func install() {
        Self.shared = self
        HotkeyService.shared.onTrayChord = { [weak self] id in
            self?.performTrayChord(id)
        }
        tray = TrayPanel()
        tray.delegate = self
        drop = DropzonePanel()
        trayHost = TrayHostingView(root: AnyView(
            TrayView()
                .modifier(AccessibilityOverride())
                .environment(store)
                .environment(settings)
                .environment(self)))
        trayHost.coordinator = self
        tray.contentView = trayHost
        dropHost = DropHostingView(root: AnyView(
            DropzoneView()
                .modifier(AccessibilityOverride())
                .environment(store)
                .environment(settings)
                .environment(self)))
        dropHost.coordinator = self
        drop.contentView = dropHost
        installPassMonitor()
        store.onChange = { [weak self] in self?.refreshDropzone() }
        screenWidth = ScreenLocator.primary().frame.width
        let center = NotificationCenter.default
        for name: Notification.Name in [NSText.didBeginEditingNotification, NSText.didEndEditingNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    PanelCoordinator.shared?.installCommandKeysIfSafe()
                }
            }
        }
    }

    /// The tray owns the Quick Look panel. Dismissing the tray must close that panel
    /// and drop the preview item, or a hidden window keeps controlling it.
    private func closeControlledPreview() {
        quickLookUp = false
        tray?.previewURLs = []
        tray?.previewTitle = ""
        if QLPreviewPanel.sharedPreviewPanelExists() {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
    }

    func applyPresence() {
        switch settings.effectivePresence {
        case .off:
            hideDropzone(animated: false)
        case .always:
            guard phase == .hidden || phase == .puck else { return }
            placeDropzone(pinToStatus: false)
            phase = .puck
            proximity = false
            pointerInside = false
            showDropzone(animated: false)
        case .onDrag:
            guard !dragSession else { return }
            if phase == .hidden || phase == .puck || phase == .ready {
                hideDropzone(animated: false)
            }
        }
    }

    func toggleTray() {
        if trayOpen { dismissTray() } else { showTray(makeKey: true) }
    }

    func showTray(makeKey: Bool, immediate: Bool = false) {
        guard tray != nil else { return }
        trayGeneration += 1
        let generation = trayGeneration
        placeTray()
        trayOpen = true
        shownAt = ContinuousClock.now
        installKeyMonitor()
        if immediate || tray.isVisible {
            // A reopen during the dismiss animation must not leave the tray hidden while key.
            trayPresented = true
            if makeKey {
                tray.makeKey()
            }
            if !tray.isVisible {
                if makeKey {
                    tray.makeKeyAndOrderFront(nil)
                } else {
                    tray.orderFrontRegardless()
                }
            }
        } else {
            trayPresented = false
            if makeKey {
                tray.makeKeyAndOrderFront(nil)
            } else {
                tray.orderFrontRegardless()
            }
            let motion = reduceMotion
            Task { @MainActor in
                guard generation == self.trayGeneration, self.trayOpen else { return }
                let animation: Animation = motion ? .linear(duration: 0.14) : .spring(response: 0.30, dampingFraction: 0.86)
                withAnimation(animation) { self.trayPresented = true }
            }
        }
        installCommandKeysIfSafe()
        onSurfaceChange()
    }

    func dismissTray() {
        guard trayOpen, tray != nil else { return }
        trayOpen = false
        settingsOpen = false
        closeControlledPreview()
        trayGeneration += 1
        let generation = trayGeneration
        removeKeyMonitor()
        releaseCommandKeys()
        let motion = reduceMotion
        let animation: Animation = motion ? .linear(duration: 0.14) : .spring(response: 0.21, dampingFraction: 0.98)
        withAnimation(animation) { trayPresented = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(motion ? 150 : 230))
            guard generation == self.trayGeneration, !self.trayOpen else { return }
            self.tray.orderOut(nil)
            self.onSurfaceChange()
        }
        onSurfaceChange()
    }

    func toggleSettings() {
        if !trayOpen { showTray(makeKey: true) }
        let animation: Animation = reduceMotion ? .linear(duration: 0.14) : .spring(response: 0.24, dampingFraction: 0.90)
        withAnimation(animation) { settingsOpen.toggle() }
    }

    func fileDragBegan() {
        guard settings.effectivePresence != .off else { return }
        dragSession = true
        dwellToken += 1
        completionShown = false
        placeDropzone(pinToStatus: false)
        phase = .ready
        fileDragMoved()
        showDropzone(animated: !drop.isVisible)
        setDropClickThrough()
    }

    func fileDragMoved() {
        guard dragSession, drop != nil else { return }
        if settings.effectivePresence == .onDrag, !pinnedToStatus {
            let screen = ScreenLocator.underMouse()
            if dropScreen == nil || screen !== dropScreen {
                placeDropzone(pinToStatus: false)
            }
        }
        guard phase == .ready || phase == .puck || phase == .hidden else { return }
        optionDown = NSEvent.modifierFlags.contains(.option)
        let mouse = NSEvent.mouseLocation
        let puckRect = DropzoneMetrics.pillRect(size: CGSize(width: 40, height: 40), anchor: anchor)
            .offsetBy(dx: drop!.frame.minX, dy: drop!.frame.minY)
        let expanded = DropzoneMetrics.pillRect(
            size: CGSize(width: 280, height: 76),
            anchor: anchor
        ).offsetBy(dx: drop!.frame.minX, dy: drop!.frame.minY)
        let near = DropzoneMetrics.distance(mouse, to: settings.effectivePresence == .always && phase == .puck ? puckRect : expanded) <= 96
            || expanded.contains(mouse)
            || puckRect.contains(mouse)
        if near || settings.effectivePresence == .onDrag {
            phase = .ready
        }
        proximity = near || pointerInside
        let local = CGPoint(x: mouse.x - drop!.frame.minX, y: mouse.y - drop!.frame.minY)
        let pill = DropzoneMetrics.pillRect(
            size: DropzoneMetrics.pillSize(phase: .ready, proximity: proximity),
            anchor: anchor)
        let inside = DropzoneMetrics.contains(local, pill: pill, puck: false)
        pointerInside = inside
        if inside {
            rawAim = abs(local.x - pill.midX) <= 3 ? nil : (local.x < pill.midX ? .smart : .lossless)
        } else {
            rawAim = nil
        }
        hapticIfNeeded()
    }

    func fileDragEnded() {
        dragSession = false
        setDropClickThrough()
        guard phase == .ready || phase == .puck else { return }
        if settings.effectivePresence == .always {
            phase = .puck
            proximity = false
            pointerInside = false
            rawAim = nil
            lastHaptic = nil
        } else {
            hideDropzone(animated: true)
        }
    }

    func pointerEnteredPill(localX: CGFloat) {
        guard phase == .ready || phase == .puck || phase == .hidden else { return }
        phase = .ready
        proximity = true
        pointerInside = true
        optionDown = NSEvent.modifierFlags.contains(.option)
        let pill = DropzoneMetrics.pillRect(size: CGSize(width: 280, height: 76), anchor: anchor)
        rawAim = abs(localX - pill.midX) <= 3 ? nil : (localX < pill.midX ? .smart : .lossless)
        hapticIfNeeded()
    }

    func puckHovered(_ inside: Bool) {
        guard !dragSession, settings.effectivePresence == .always else { return }
        if inside, phase == .puck {
            phase = .ready
            proximity = true
        } else if !inside, phase == .ready, dropBatch == nil {
            phase = .puck
            proximity = false
            pointerInside = false
            rawAim = nil
        }
    }

    func mode(atLocalX x: CGFloat, pill: CGRect) -> CompressionMode {
        let base: CompressionMode
        if abs(x - pill.midX) <= 3 {
            base = settings.settings.defaultMode
        } else {
            base = x < pill.midX ? .smart : .lossless
        }
        return NSEvent.modifierFlags.contains(.option) ? base.flipped : base
    }

    func acceptDrop(urls: [URL], mode: CompressionMode, openTray: Bool, pinToStatus: Bool) {
        let files = urls.filter { !$0.path.isEmpty }
        guard !files.isEmpty else { return }
        dragSession = false
        dwellToken += 1
        settings.settings.defaultMode = mode
        haptic(.levelChange)
        if pinToStatus { placeDropzone(pinToStatus: true) }
        dropBatch = store.submit(files, mode: mode)
        completionShown = false
        doneURLs = []
        doneJobIDs = []
        phase = .compressing
        headline = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        subline = "\(mode.title) · 0%"
        progress = 0
        showDropzone(animated: !drop.isVisible)
        if openTray {
            showTray(makeKey: true)
            store.selectedID = store.items.first?.id
        }
        refreshDropzone()
    }

    func activateDone() {
        let ids = doneJobIDs.isEmpty ? sourceJobIDs() : doneJobIDs
        dismissDropzoneNow()
        Task { @MainActor in
            let urls = await self.urlsForDoneClick(ids)
            if !urls.isEmpty {
                self.reveal(urls)
            }
        }
    }

    func openTrayFromDone() {
        showTray(makeKey: false)
    }

    func cancelDropBatch() {
        guard let dropBatch else { return }
        for item in store.items where item.job.request.batchID == dropBatch && !item.job.state.isTerminal {
            store.cancel(item.id)
        }
    }

    func browse() {
        beginPanelSession()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Compress"
        let mode = settings.settings.defaultMode
        panel.begin { [weak self] response in
            let urls = panel.urls
            Task { @MainActor in
                self?.endPanelSession()
                guard response == .OK else { return }
                self?.store.submit(urls, mode: mode)
            }
        }
    }

    func chooseOutputFolder() {
        beginPanelSession()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.begin { [weak self] response in
            let url = panel.url
            Task { @MainActor in
                guard let self else { return }
                self.endPanelSession()
                guard response == .OK, let url else { return }
                self.settings.settings.engine.output = .folder(url)
            }
        }
    }

    func revealOutputFolder() {
        if case .folder(let url) = settings.settings.engine.output {
            reveal([url])
        }
    }

    func pasteFromClipboard() {
        if store.simulated {
            store.showToast("Clipboard image queued")
            return
        }
        let board = NSPasteboard.general
        let urls = DragURLs.urls(from: board)
        if !urls.isEmpty {
            store.submit(urls, mode: settings.settings.defaultMode)
            return
        }
        let data = board.data(forType: .png) ?? pngData(board.data(forType: .tiff))
        guard let data else {
            store.showToast("Couldn't save the clipboard image")
            return
        }
        let folder: URL
        if case .folder(let url) = settings.settings.engine.output {
            folder = url
        } else {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        let stem = "Clipboard-\(clipboardStamp.string(from: Date()))"
        let mode = settings.settings.defaultMode
        Task { @MainActor in
            do {
                let url = try await JobFileWork.runDetached {
                    try ExclusiveFile.create(directory: folder, stem: stem, ext: "png", contents: data)
                }
                self.store.submit([url], mode: mode)
            } catch {
                self.store.showToast("Couldn't save the clipboard image")
            }
        }
    }

    func revealSelected() {
        guard let item = selectedItem() else { return }
        let id = item.id
        Task { @MainActor in
            guard let url = await self.store.claimActionURL(id) else { return }
            self.reveal([url])
        }
    }

    func copySelected() {
        guard let item = selectedItem(), item.outputURL != nil else { return }
        let id = item.id
        Task { @MainActor in
            guard let url = await self.store.claimOutput(id) else { return }
            let board = NSPasteboard.general
            board.clearContents()
            board.writeObjects([url as NSURL])
        }
    }

    func replaceSelected() {
        guard let id = store.selectedID else { return }
        Task { await store.replaceOriginal(id) }
    }

    func previewItem(_ item: JobItem) {
        store.selectedID = item.id
        showQuickLook(for: item)
    }

    func quickLookEnded() {
        quickLookUp = false
        if trayOpen, let tray {
            tray.makeKey()
        }
        installCommandKeysIfSafe()
    }

    /// An open panel or Quick Look holds no tray command keys, even if the tray is still key.
    func beginPanelSession() {
        panelSession = true
        suspendDismiss = true
        releaseCommandKeys()
    }

    func endPanelSession() {
        panelSession = false
        suspendDismiss = false
        installCommandKeysIfSafe()
    }

    func applicationFocusChanged(active: Bool) {
        if active {
            installCommandKeysIfSafe()
        } else {
            releaseCommandKeys()
        }
    }

    func releaseCommandKeys() {
        HotkeyService.shared.removeTrayChords()
    }

    func installCommandKeysIfSafe() {
        guard trayOpen, let tray, tray.isKeyWindow, !blocksCommandKeys, !fieldEditorActive else {
            releaseCommandKeys()
            return
        }
        HotkeyService.shared.installTrayChords(TrayHotkeyChord.tray)
    }

    /// A field editor must receive editing chords, including ⌘⌫. Esc stays with the tray.
    private var fieldEditorActive: Bool {
        guard let tray, let responder = tray.firstResponder else { return false }
        return responder is NSTextView
    }

    func clickOutside() {
        guard trayOpen, !suspendDismiss, !quickLookUp else { return }
        if NSApp.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }) { return }
        let point = NSEvent.mouseLocation
        if tray!.frame.contains(point) { return }
        if let frame = statusFrame(), frame.insetBy(dx: -4, dy: -4).contains(point) { return }
        dismissTray()
    }

    func consumeKey(_ key: KeyChord) -> Bool {
        guard trayOpen, let tray, tray.isKeyWindow else { return false }
        if key.keyCode == 53 {
            if quickLookUp {
                QLPreviewPanel.shared()?.orderOut(nil)
                quickLookUp = false
                return true
            }
            if settingsOpen {
                settingsOpen = false
                tray.makeFirstResponder(nil)
                return true
            }
            dismissTray()
            return true
        }
        guard !blocksCommandKeys else { return false }
        if let responder = tray.firstResponder, responder is NSTextView { return false }
        if key.command, key.characters == "," {
            toggleSettings()
            return true
        }
        if key.command, key.characters == "q", !key.option, !key.control {
            NSApp.terminate(nil)
            return true
        }
        if key.command, key.characters == "v" { pasteFromClipboard(); return true }
        if key.command, key.characters == "o" { browse(); return true }
        if key.command, key.characters == "z" {
            Task { await store.undoLastReplace() }
            return true
        }
        if key.command, key.characters == "1" { settings.settings.defaultMode = .smart; return true }
        if key.command, key.characters == "2" { settings.settings.defaultMode = .lossless; return true }
        if key.command, key.characters == "c" { copySelected(); return true }
        if key.command, key.characters == "r" { replaceSelected(); return true }
        if key.command, key.option, key.keyCode == 51 {
            if let id = store.selectedID {
                Task { await store.trashOutput(id) }
            }
            return true
        }
        if key.command, key.keyCode == 51 { if let id = store.selectedID { store.remove(id) }; return true }
        if key.command, key.characters == ".", key.shift { store.cancelAll(); return true }
        if key.command, key.characters == "." || (key.keyCode == 51 && !key.command) {
            cancelSelectedOrRemove()
            return true
        }
        if key.keyCode == 49 && !key.command {
            showQuickLook()
            return true
        }
        if key.keyCode == 36 && !key.command {
            revealSelected()
            return true
        }
        if key.keyCode == 126 {
            key.command ? store.selectEdge(first: true) : store.moveSelection(-1)
            return true
        }
        if key.keyCode == 125 {
            key.command ? store.selectEdge(first: false) : store.moveSelection(1)
            return true
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === tray, trayOpen else { return }
        installCommandKeysIfSafe()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === tray else { return }
        // Release before any dismiss guard. A panel, Quick Look, or the first 300 ms
        // may keep the tray up, but none of them may keep command keys.
        releaseCommandKeys()
        guard trayOpen, !suspendDismiss, !quickLookUp, !panelSession else { return }
        if let shownAt, shownAt.duration(to: .now) < .milliseconds(300) { return }
        if openPanelVisible { return }
        dismissTray()
    }

    func setTrayDrag(active: Bool, localX: CGFloat?) {
        trayDragActive = active
        guard active, let localX else { trayAim = nil; return }
        let wellMax = 12 + intakeWidth
        let base: CompressionMode
        if localX <= wellMax {
            base = localX < 12 + intakeWidth / 2 ? .smart : .lossless
        } else {
            base = settings.settings.defaultMode
        }
        trayAim = NSEvent.modifierFlags.contains(.option) ? base.flipped : base
    }

    func statusItemDropped(_ urls: [URL]) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        acceptDrop(urls: urls, mode: settings.settings.defaultMode, openTray: shift, pinToStatus: true)
    }

    private func refreshDropzone() {
        guard let batch = dropBatch else { onSurfaceChange(); return }
        let jobs = store.items.filter { $0.job.request.batchID == batch }
        guard !jobs.isEmpty else { onSurfaceChange(); return }
        let pending = jobs.filter { !$0.job.state.isTerminal }
        if !pending.isEmpty {
            phase = .compressing
            progress = weighted(jobs)
            let saved = savedBytes(jobs)
            if jobs.count == 1 {
                headline = jobs[0].job.request.source.lastPathComponent
                subline = "\(jobs[0].job.request.mode.title) · \(Int((progress * 100).rounded()))%"
            } else {
                headline = "\(jobs.count) files (\(pending.count) left)"
                subline = "−\(ByteText.string(saved)) so far"
            }
            onSurfaceChange()
            return
        }
        guard !completionShown else { onSurfaceChange(); return }
        completionShown = true
        let saved = savedBytes(jobs)
        let failed = jobs.filter { if case .failed = $0.job.state { return true }; return false }
        let allCancelled = jobs.allSatisfy { if case .cancelled = $0.job.state { return true }; return false }
        doneJobIDs = jobs.compactMap { item -> JobID? in
            guard case .finished(let result) = item.job.state, result.outcome == .compressed else { return nil }
            return item.outputURL == nil ? nil : item.id
        }
        doneURLs = jobs.compactMap { item -> URL? in
            guard doneJobIDs.contains(item.id) else { return nil }
            return item.outputURL
        }
        if allCancelled {
            phase = .cancelled
            headline = "Cancelled"
            subline = ""
            armDwell(1.8)
        } else if doneURLs.isEmpty, let first = failed.first {
            phase = .failed
            headline = errorLine(first)
            subline = "Open Tray"
            armDwell(4)
        } else if saved > 0 {
            phase = .done
            let input = jobs.reduce(Int64(0)) { $0 + $1.job.inputBytes }
            headline = ByteText.percent(input > 0 ? Double(saved) / Double(input) : 0)
            subline = "Saved \(ByteText.string(saved)) · Drag or click"
            haptic(.generic)
            armDwell(6)
        } else {
            phase = .optimal
            headline = "Already optimal"
            subline = "0 B saved · Original kept"
            armDwell(4)
        }
        onSurfaceChange()
    }

    private func weighted(_ jobs: [JobItem]) -> Double {
        let total = jobs.reduce(Int64(0)) { $0 + max($1.job.inputBytes, 1) }
        let done = jobs.reduce(Double(0)) { partial, item in
            let weight = Double(max(item.job.inputBytes, 1))
            let fraction: Double
            switch item.job.state {
            case .queued: fraction = 0
            case .running(let value): fraction = value
            case .finished, .failed, .cancelled: fraction = 1
            }
            return partial + weight * fraction
        }
        return min(1, done / Double(total))
    }

    private func savedBytes(_ jobs: [JobItem]) -> Int64 {
        jobs.reduce(0) { partial, item in
            guard case .finished(let result) = item.job.state else { return partial }
            return partial + result.savedBytes
        }
    }

    private func errorLine(_ item: JobItem) -> String {
        guard case .failed(let error) = item.job.state else { return "Read failed · Open Tray" }
        switch error {
        case .unreadable:
            return "Read failed · Open Tray"
        case .outputNotWritable:
            return "No write permission"
        case .diskFull:
            return "Disk full"
        case .verificationFailed(let detail), .codec(let detail):
            if detail.isEmpty { return "Read failed · Open Tray" }
            return detail.count > 48 ? String(detail.prefix(48)) : detail
        }
    }

    private func armDwell(_ seconds: Double) {
        dwellToken += 1
        let token = dwellToken
        Task { @MainActor in
            var left = seconds
            while left > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                guard token == self.dwellToken else { return }
                if !self.pillHovered { left -= 0.1 }
            }
            guard token == self.dwellToken else { return }
            self.finishPill()
        }
    }

    private func finishPill() {
        dropBatch = nil
        doneURLs = []
        doneJobIDs = []
        if settings.effectivePresence == .always {
            phase = .puck
            proximity = false
            pointerInside = false
            rawAim = nil
            onSurfaceChange()
        } else {
            hideDropzone(animated: true)
        }
    }

    private func dismissDropzoneNow() {
        dwellToken += 1
        dropBatch = nil
        if settings.effectivePresence == .always {
            phase = .puck
            proximity = false
        } else {
            hideDropzone(animated: true)
        }
    }

    private func sourceJobIDs() -> [JobID] {
        guard let batch = dropBatch else { return [] }
        return store.items.filter { $0.job.request.batchID == batch }.map(\.id)
    }

    /// URLs the Done pill may hand to Finder. Each id is checked against its stamp now.
    func urlsForDoneClick(_ ids: [JobID]) async -> [URL] {
        var proven: [URL] = []
        for id in ids {
            if let claimed = await store.claimActionURL(id) {
                proven.append(claimed)
            }
        }
        return proven
    }

    private func selectedItem() -> JobItem? {
        guard let id = store.selectedID else { return store.items.first }
        return store.items.first { $0.id == id }
    }

    private func cancelSelectedOrRemove() {
        guard let item = selectedItem(), !item.job.state.isTerminal else { return }
        store.cancel(item.id)
    }

    private func showQuickLook() {
        guard let item = selectedItem() else { return }
        showQuickLook(for: item)
    }

    private func showQuickLook(for item: JobItem) {
        let id = item.id
        let generation = trayGeneration
        Task { @MainActor in
            let url = await self.store.claimActionURL(id)
            guard let url else { return }
            guard generation == self.trayGeneration, self.trayOpen, self.store.selectedID == id else { return }
            guard let current = self.store.items.first(where: { $0.id == id }) else { return }
            self.presentQuickLook(url: url, item: current)
        }
    }

    private func presentQuickLook(url: URL, item: JobItem) {
        quickLookPresentations += 1
        var title = item.job.request.source.lastPathComponent
        if case .finished(let result) = item.job.state {
            title = "Compressed · \(ByteText.string(result.outputBytes)) (\(ByteText.percent(result.savedFraction)))"
        }
        tray.previewURLs = [url]
        tray.previewTitle = title
        quickLookUp = true
        releaseCommandKeys()
        tray.showQuickLook()
    }

    private func placeTray() {
        let screen = ScreenLocator.underMouse()
        screenWidth = screen.frame.width
        let frame = PanelGeometry.trayFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        tray.setFrame(frame, display: true)
    }

    private func placeDropzone(pinToStatus: Bool) {
        pinnedToStatus = pinToStatus
        if pinToStatus, let frame = frameUnderStatus() {
            anchor = .topCenter
            dropScreen = NSScreen.screens.first { $0.frame.intersects(frame) }
            drop.setFrame(frame, display: true)
            return
        }
        let screen: NSScreen
        switch settings.effectivePresence {
        case .onDrag:
            screen = ScreenLocator.underMouse()
            anchor = .topCenter
        case .always, .off:
            screen = ScreenLocator.primary()
            anchor = settings.settings.anchor
        }
        dropScreen = screen
        let frame = PanelGeometry.dropzoneFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            anchor: anchor)
        drop.setFrame(frame, display: true)
    }

    private func frameUnderStatus() -> CGRect? {
        guard let status = statusFrame() else { return nil }
        var frame = CGRect(x: status.midX - 152, y: status.minY - 8 - 96, width: 304, height: 96)
        let screen = NSScreen.screens.first { $0.frame.intersects(status) } ?? ScreenLocator.primary()
        frame.origin.x = min(max(frame.origin.x, screen.frame.minX + 8), screen.frame.maxX - frame.width - 8)
        return frame
    }

    private func statusFrame() -> CGRect? {
        StatusItemController.shared?.buttonFrame
    }

    private func showDropzone(animated: Bool) {
        guard drop != nil else { return }
        visibilityToken += 1
        if animated, !drop.isVisible {
            dropPresented = false
            drop.orderFrontRegardless()
            let motion = reduceMotion
            Task { @MainActor in
                let animation: Animation = motion ? .linear(duration: 0.14) : .spring(response: 0.28, dampingFraction: 0.82)
                withAnimation(animation) { self.dropPresented = true }
            }
        } else {
            dropPresented = true
            if !drop.isVisible { drop.orderFrontRegardless() }
        }
        setDropClickThrough()
        onSurfaceChange()
    }

    private func hideDropzone(animated: Bool) {
        guard drop != nil else { return }
        visibilityToken += 1
        let token = visibilityToken
        let close = {
            guard token == self.visibilityToken else { return }
            self.phase = .hidden
            self.proximity = false
            self.pointerInside = false
            self.rawAim = nil
            self.drop.orderOut(nil)
            self.onSurfaceChange()
        }
        guard animated, drop.isVisible else {
            dropPresented = false
            close()
            return
        }
        let motion = reduceMotion
        let animation: Animation = motion ? .linear(duration: 0.14) : .spring(response: 0.20, dampingFraction: 0.96)
        withAnimation(animation) { dropPresented = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(motion ? 160 : 210))
            close()
        }
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        Haptics.perform(pattern, enabled: settings.settings.haptics)
    }

    /// Keeps a screenshot surface up when the panel is not the key window.
    func holdForDemo() {
        suspendDismiss = true
    }

    /// Demo-only. Production `PanelGeometry` is unchanged; this grows the live panel so every card fits.
    func fitDemoTray(height: CGFloat) {
        guard let tray else { return }
        let screen = tray.screen ?? ScreenLocator.primary()
        var frame = tray.frame
        frame.size.height = min(height, screen.visibleFrame.height - 40)
        frame.origin.y = screen.frame.minY + 12
        tray.setFrame(frame, display: true)
        tray.contentView?.layoutSubtreeIfNeeded()
    }

    func presentDemoDrop(aim: CompressionMode) {
        guard drop != nil else { return }
        holdForDemo()
        placeDropzone(pinToStatus: false)
        phase = .ready
        proximity = true
        pointerInside = true
        rawAim = aim
        optionDown = false
        pillHovered = false
        dropPresented = true
        showDropzone(animated: false)
    }

    func presentDemoCompressing(headline: String, subline: String) {
        guard drop != nil else { return }
        holdForDemo()
        placeDropzone(pinToStatus: false)
        phase = .compressing
        proximity = false
        pointerInside = false
        rawAim = nil
        self.headline = headline
        self.subline = subline
        progress = 0.40
        doneURLs = []
        doneJobIDs = []
        dropPresented = true
        showDropzone(animated: false)
    }

    func presentDemoPuck() {
        guard drop != nil else { return }
        holdForDemo()
        placeDropzone(pinToStatus: false)
        phase = .puck
        proximity = false
        pointerInside = false
        rawAim = nil
        dropPresented = true
        showDropzone(animated: false)
    }

    func presentDemoDone(url: URL?, headline: String, subline: String) {
        guard drop != nil else { return }
        holdForDemo()
        placeDropzone(pinToStatus: false)
        phase = .done
        proximity = false
        pointerInside = false
        rawAim = nil
        self.headline = headline
        self.subline = subline
        progress = 1
        if let url {
            doneURLs = [url]
            doneJobIDs = store.items.filter { $0.outputURL == url }.map(\.id)
        }
        dropPresented = true
        showDropzone(animated: false)
    }

    func provenDoneURLs() async -> [URL] {
        await urlsForDoneClick(doneJobIDs)
    }

    var trayWindowNumber: Int { tray?.windowNumber ?? 0 }
    var dropWindowNumber: Int { drop?.windowNumber ?? 0 }

    private func hapticIfNeeded() {
        guard let targeted, targeted != lastHaptic else { return }
        lastHaptic = targeted
        haptic(.alignment)
    }

    private func reveal(_ urls: [URL]) {
        suspendDismiss = true
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.suspendDismiss = false
        }
    }

    private func pngData(_ data: Data?) -> Data? {
        guard let data, let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func installPassMonitor() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        passGlobal = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { PanelCoordinator.shared?.setDropClickThrough() }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { PanelCoordinator.shared?.setDropClickThrough() }
                }
            }
        }
        passLocal = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { PanelCoordinator.shared?.setDropClickThrough() }
            return event
        }
    }

    /// Clicks outside the pill fall through to the window below. A file drag keeps the panel live so the drop can land.
    private func setDropClickThrough() {
        guard let drop, drop.isVisible, phase != .hidden else { return }
        if dragSession {
            drop.ignoresMouseEvents = false
            return
        }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - drop.frame.minX, y: mouse.y - drop.frame.minY)
        let size = DropzoneMetrics.pillSize(phase: phase, proximity: proximity)
        let pill = DropzoneMetrics.pillRect(size: size, anchor: anchor)
        let inside = DropzoneMetrics.contains(local, pill: pill, puck: phase == .puck)
        drop.ignoresMouseEvents = !inside
    }

    private var blocksCommandKeys: Bool {
        panelSession || quickLookUp || openPanelVisible
    }

    private var openPanelVisible: Bool {
        NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible }
    }

    func performTrayChord(_ id: UInt32) {
        guard trayOpen, let tray, tray.isKeyWindow, !blocksCommandKeys else { return }
        guard let spec = TrayHotkeyChord.tray.first(where: { $0.id == id }) else { return }
        if fieldEditorActive {
            forwardEditing(spec)
            return
        }
        let chord = KeyChord(
            keyCode: UInt16(spec.keyCode),
            characters: spec.characters,
            command: true,
            option: spec.option,
            shift: spec.shift,
            control: false)
        _ = consumeKey(chord)
    }

    private func forwardEditing(_ spec: TrayHotkeyChord) {
        let selector: Selector?
        switch spec.characters {
        case "v": selector = #selector(NSText.paste(_:))
        case "c": selector = #selector(NSText.copy(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        case "z": selector = Selector(("undo:"))
        case "" where spec.keyCode == 51 && !spec.option:
            selector = #selector(NSText.deleteToBeginningOfLine(_:))
        default: selector = nil
        }
        if let selector {
            NSApp.sendAction(selector, to: nil, from: nil)
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let window = event.window
            let chord = KeyChord(event)
            let consume = MainActor.assumeIsolated { () -> Bool in
                guard let coordinator = PanelCoordinator.shared, let tray = coordinator.tray else { return false }
                guard window === tray, tray.isKeyWindow else { return false }
                return coordinator.consumeKey(chord)
            }
            return consume ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct KeyChord: Sendable {
    var keyCode: UInt16
    var characters: String
    var command: Bool
    var option: Bool
    var shift: Bool
    var control: Bool

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        command = flags.contains(.command)
        option = flags.contains(.option)
        shift = flags.contains(.shift)
        control = flags.contains(.control)
    }

    init(keyCode: UInt16, characters: String, command: Bool, option: Bool, shift: Bool, control: Bool) {
        self.keyCode = keyCode
        self.characters = characters
        self.command = command
        self.option = option
        self.shift = shift
        self.control = control
    }
}

private let clipboardStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter
}()

@MainActor
final class TrayHostingView: NSView {
    let hosting: NSHostingView<AnyView>
    weak var coordinator: PanelCoordinator?

    init(root: AnyView) {
        hosting = NSHostingView(rootView: root)
        super.init(frame: .zero)
        hosting.sizingOptions = []
        addSubview(hosting)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        hosting.unregisterDraggedTypes()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !DragURLs.isSelfDrag(sender) else { return [] }
        update(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !DragURLs.isSelfDrag(sender) else { return [] }
        update(sender)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        coordinator?.setTrayDrag(active: false, localX: nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !DragURLs.isSelfDrag(sender), let coordinator else { return false }
        let urls = DragURLs.urls(from: sender)
        guard !urls.isEmpty else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        coordinator.setTrayDrag(active: true, localX: point.x)
        let mode = coordinator.trayAim ?? coordinator.settings.settings.defaultMode
        coordinator.setTrayDrag(active: false, localX: nil)
        let shift = NSEvent.modifierFlags.contains(.shift)
        coordinator.acceptDrop(urls: urls, mode: mode, openTray: shift, pinToStatus: false)
        return true
    }

    private func update(_ sender: any NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        coordinator?.setTrayDrag(active: true, localX: point.x)
    }
}
