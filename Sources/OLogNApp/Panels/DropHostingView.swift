import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OLogNKit

enum DropPhase: Equatable {
    case hidden
    case puck
    case ready
    case compressing
    case done
    case optimal
    case failed
    case cancelled
}

enum DropzoneMetrics {
    static let panel = CGSize(width: 304, height: 96)

    static func pillSize(phase: DropPhase, proximity: Bool) -> CGSize {
        switch phase {
        case .hidden:
            return .zero
        case .puck:
            return CGSize(width: 40, height: 40)
        case .ready:
            return proximity ? CGSize(width: 280, height: 76) : CGSize(width: 228, height: 60)
        case .compressing:
            return CGSize(width: 216, height: 52)
        case .done, .optimal:
            return CGSize(width: 268, height: 58)
        case .failed, .cancelled:
            return CGSize(width: 236, height: 52)
        }
    }

    static func pillRect(size: CGSize, anchor: DropzoneAnchor, panel: CGSize = panel) -> CGRect {
        guard size.width > 0 else { return .zero }
        let inset: CGFloat = 6
        switch anchor {
        case .topCenter:
            return CGRect(
                x: (panel.width - size.width) / 2,
                y: panel.height - inset - size.height,
                width: size.width,
                height: size.height)
        case .rightCenter:
            return CGRect(
                x: panel.width - inset - size.width,
                y: (panel.height - size.height) / 2,
                width: size.width,
                height: size.height)
        case .leftCenter:
            return CGRect(
                x: inset,
                y: (panel.height - size.height) / 2,
                width: size.width,
                height: size.height)
        }
    }

    static func contains(_ point: CGPoint, pill: CGRect, puck: Bool) -> Bool {
        if puck { return rounded(point, in: pill, radius: 12) }
        return capsule(point, in: pill)
    }

    static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private static func capsule(_ point: CGPoint, in rect: CGRect) -> Bool {
        let radius = rect.height / 2
        let left = CGPoint(x: rect.minX + radius, y: rect.midY)
        let right = CGPoint(x: rect.maxX - radius, y: rect.midY)
        if point.x >= left.x, point.x <= right.x, abs(point.y - rect.midY) <= radius { return true }
        if hypot(point.x - left.x, point.y - left.y) <= radius { return true }
        if hypot(point.x - right.x, point.y - right.y) <= radius { return true }
        return false
    }

    private static func rounded(_ point: CGPoint, in rect: CGRect, radius: CGFloat) -> Bool {
        let inset = rect.insetBy(dx: radius, dy: radius)
        if inset.contains(point) { return true }
        let cx = min(max(point.x, inset.minX), inset.maxX)
        let cy = min(max(point.y, inset.minY), inset.maxY)
        return hypot(point.x - cx, point.y - cy) <= radius
    }
}

@MainActor
enum DragURLs {
    static func urls(from info: NSDraggingInfo) -> [URL] {
        urls(from: info.draggingPasteboard)
    }

    static func urls(from board: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    static func isSelfDrag(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.types?.contains(Logn.selfDragType) == true
    }

    /// The file is handed out only after `claim` proves Logn still owns it.
    static func claimingProvider(_ claim: @escaping @MainActor () async -> URL?) -> NSItemProvider {
        let handle = ClaimHandle(claim)
        let provider = NSItemProvider()
        let marker = Logn.selfDragType.rawValue
        provider.registerDataRepresentation(forTypeIdentifier: marker, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task { @MainActor in
                if let url = await handle.claim() {
                    completion(url, false, nil)
                } else {
                    completion(nil, false, CocoaError(.fileReadNoPermission))
                }
            }
            return nil
        }
        return provider
    }

    static func provider(urls: [URL]) -> NSItemProvider {
        let provider = NSItemProvider()
        let marker = Logn.selfDragType.rawValue
        provider.registerDataRepresentation(forTypeIdentifier: marker, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        if let url = urls.first {
            provider.suggestedName = url.lastPathComponent
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                completion(url, false, nil)
                return nil
            }
        }
        return provider
    }
}

/// Holds a main-actor claim so the item provider's sendable callback can hop back.
private final class ClaimHandle: @unchecked Sendable {
    let claim: @MainActor () async -> URL?
    init(_ claim: @escaping @MainActor () async -> URL?) {
        self.claim = claim
    }
}

@MainActor
final class DropHostingView: NSView {
    let hosting: NSHostingView<AnyView>
    weak var coordinator: PanelCoordinator? {
        didSet { dragWell.coordinator = coordinator }
    }
    private let dragWell = DoneDragWell()
    private var tracking: NSTrackingArea?

    init(root: AnyView) {
        hosting = NSHostingView(rootView: root)
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: 96))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        addSubview(hosting)
        dragWell.isHidden = true
        addSubview(dragWell)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        hosting.unregisterDraggedTypes()
        syncDragWell()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let coordinator, coordinator.phase != .hidden else { return nil }
        let size = DropzoneMetrics.pillSize(phase: coordinator.phase, proximity: coordinator.proximity)
        let pill = DropzoneMetrics.pillRect(size: size, anchor: coordinator.anchor)
        let puck = coordinator.phase == .puck
        guard DropzoneMetrics.contains(point, pill: pill, puck: puck) else { return nil }
        syncDragWell()
        if !dragWell.isHidden, dragWell.frame.contains(point) {
            return dragWell
        }
        return hosting.hitTest(convert(point, to: hosting)) ?? self
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.puckHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.puckHovered(false)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !DragURLs.isSelfDrag(sender), targetsPill(sender) else { return [] }
        updateAim(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !DragURLs.isSelfDrag(sender), targetsPill(sender) else { return [] }
        updateAim(sender)
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !DragURLs.isSelfDrag(sender), targetsPill(sender) else { return false }
        let urls = DragURLs.urls(from: sender)
        guard !urls.isEmpty, let coordinator else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let size = DropzoneMetrics.pillSize(phase: coordinator.phase == .puck ? .puck : .ready, proximity: coordinator.proximity)
        let pill = DropzoneMetrics.pillRect(size: size, anchor: coordinator.anchor)
        let mode = coordinator.mode(atLocalX: point.x, pill: pill)
        let shift = NSEvent.modifierFlags.contains(.shift)
        coordinator.acceptDrop(urls: urls, mode: mode, openTray: shift, pinToStatus: false)
        return true
    }

    /// The visible capsule, not the panel's rectangle. The margin around the pill belongs to the app underneath.
    private func targetsPill(_ sender: any NSDraggingInfo) -> Bool {
        guard let coordinator else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let phase: DropPhase = coordinator.phase == .puck ? .puck : .ready
        let proximity = phase == .puck ? false : coordinator.proximity
        let size = DropzoneMetrics.pillSize(phase: phase, proximity: proximity)
        let pill = DropzoneMetrics.pillRect(size: size, anchor: coordinator.anchor)
        return DropzoneMetrics.contains(point, pill: pill, puck: phase == .puck)
    }

    private func updateAim(_ sender: any NSDraggingInfo) {
        guard let coordinator else { return }
        let point = convert(sender.draggingLocation, from: nil)
        coordinator.pointerEnteredPill(localX: point.x)
    }

    /// The done pill except the trailing chevron. SwiftUI `.onDrag` can only offer one file.
    private func syncDragWell() {
        guard let coordinator, coordinator.phase == .done || coordinator.phase == .optimal else {
            dragWell.isHidden = true
            return
        }
        let size = DropzoneMetrics.pillSize(phase: coordinator.phase, proximity: coordinator.proximity)
        var pill = DropzoneMetrics.pillRect(size: size, anchor: coordinator.anchor)
        pill.size.width = max(40, pill.width - 38)
        dragWell.frame = pill
        dragWell.isHidden = false
    }
}

/// One dragging item per output. A click that does not move still opens the files.
@MainActor
final class DoneDragWell: NSView, NSDraggingSource {
    weak var coordinator: PanelCoordinator?
    private var down: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        down = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - down.x, point.y - down.y) >= 4 else { return }
        self.down = nil
        beginFileDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        down = nil
        coordinator?.activateDone()
    }

    private func beginFileDrag(_ event: NSEvent) {
        let origin = convert(event.locationInWindow, from: nil)
        Task { @MainActor in
            let urls = await self.coordinator?.provenDoneURLs() ?? []
            guard !urls.isEmpty else { return }
            let items: [NSDraggingItem] = urls.map { url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let image = NSWorkspace.shared.icon(forFile: url.path)
                item.setDraggingFrame(NSRect(origin: origin, size: NSSize(width: 32, height: 32)), contents: image)
                return item
            }
            self.beginDraggingSession(with: items, event: event, source: self)
        }
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        session.draggingPasteboard.setData(Data(), forType: Logn.selfDragType)
    }
}
