import AppKit
import OLogNKit

@MainActor
final class StatusItemController: NSObject {
    static weak var shared: StatusItemController?

    let store: JobStore
    let settings: SettingsStore
    let coordinator: PanelCoordinator
    private var item: NSStatusItem?
    private let dropView = StatusDropView()

    init(store: JobStore, settings: SettingsStore, coordinator: PanelCoordinator) {
        self.store = store
        self.settings = settings
        self.coordinator = coordinator
        super.init()
    }

    var buttonFrame: CGRect? {
        item?.button?.window?.frame
    }

    func install() {
        Self.shared = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        guard let button = item.button else { return }
        let image = StatusGlyph.image(side: 18)
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(Logn.displayName)
        dropView.controller = self
        dropView.frame = button.bounds
        dropView.autoresizingMask = [.width, .height]
        button.addSubview(dropView)
        refresh()
    }

    var windowNumber: Int { item?.button?.window?.windowNumber ?? 0 }

    func refresh() {
        guard let item, let button = item.button else { return }
        let fraction = progressFraction()
        let image = StatusGlyph.image(side: 18, progress: fraction)
        image.isTemplate = true
        button.image = image
        if fraction != nil {
            button.title = "\(Int(((fraction ?? 0) * 100).rounded()))%"
            item.length = 68
        } else {
            button.title = ""
            item.length = 28
        }
        dropView.frame = button.bounds
    }

    func handleClick(_ event: NSEvent) {
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popMenu()
        } else {
            coordinator.toggleTray()
        }
    }

    func acceptDrop(_ urls: [URL]) {
        coordinator.statusItemDropped(urls)
    }

    /// Weighted fraction while jobs run and both the tray and the dropzone are hidden.
    private func progressFraction() -> Double? {
        guard store.active > 0, !coordinator.trayOpen else { return nil }
        switch coordinator.phase {
        case .hidden, .puck:
            break
        default:
            return nil
        }
        let pending = store.items.filter { !$0.job.state.isTerminal }
        guard !pending.isEmpty else { return nil }
        let total = pending.reduce(Double(0)) { $0 + Double(max($1.job.inputBytes, 1)) }
        guard total > 0 else { return nil }
        let done = pending.reduce(Double(0)) { partial, item in
            let weight = Double(max(item.job.inputBytes, 1))
            let fraction: Double
            switch item.job.state {
            case .running(let value): fraction = value
            case .queued: fraction = 0
            default: fraction = 1
            }
            return partial + weight * fraction
        }
        return min(1, max(0, done / total))
    }

    private func popMenu() {
        guard let button = item?.button else { return }
        let menu = NSMenu()
        menu.addItem(entry("Open Tray (⌃⌥Space)", #selector(openTray(_:))))
        menu.addItem(.separator())
        let smart = entry("Default Mode: Smart", #selector(chooseSmart(_:)))
        smart.state = settings.settings.defaultMode == .smart ? .on : .off
        menu.addItem(smart)
        let lossless = entry("Default Mode: Lossless", #selector(chooseLossless(_:)))
        lossless.state = settings.settings.defaultMode == .lossless ? .on : .off
        menu.addItem(lossless)
        let pin = entry("Pin Dropzone Puck", #selector(pinPuck(_:)))
        pin.state = settings.settings.presence == .always ? .on : .off
        menu.addItem(pin)
        menu.addItem(.separator())
        menu.addItem(entry("Settings… (⌘,)", #selector(openSettings(_:))))
        menu.addItem(entry("Quit Logn (⌘Q)", #selector(quit(_:))))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func entry(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openTray(_ sender: Any?) {
        coordinator.showTray(makeKey: true)
    }

    @objc private func chooseSmart(_ sender: Any?) {
        settings.settings.defaultMode = .smart
    }

    @objc private func chooseLossless(_ sender: Any?) {
        settings.settings.defaultMode = .lossless
    }

    @objc private func pinPuck(_ sender: Any?) {
        settings.togglePinnedPuck()
    }

    @objc private func openSettings(_ sender: Any?) {
        coordinator.showTray(makeKey: true)
        if !coordinator.settingsOpen { coordinator.toggleSettings() }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

@MainActor
final class StatusDropView: NSView {
    weak var controller: StatusItemController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override var isOpaque: Bool { false }

    override func mouseUp(with event: NSEvent) { controller?.handleClick(event) }
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) { controller?.handleClick(event) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        DragURLs.isSelfDrag(sender) ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        DragURLs.isSelfDrag(sender) ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !DragURLs.isSelfDrag(sender) else { return false }
        let urls = DragURLs.urls(from: sender)
        guard !urls.isEmpty else { return false }
        controller?.acceptDrop(urls)
        return true
    }
}
