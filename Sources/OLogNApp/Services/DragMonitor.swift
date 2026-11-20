import AppKit

/// Decides when a file-drag session starts and when a later click must end it.
///
/// A mouse-down ends a session that is still tracking or waiting out the drop delay.
/// A mouse-up of a real drag only arms that delay; the monitor fires it 150 ms later
/// so a drop can land. A click that never moves 24 pt does not arm a new delay.
struct DragSessionModel {
    private(set) var tracking = false
    private(set) var endPending = false

    /// Returns whether the caller should end the previous session immediately.
    mutating func beginGesture() -> Bool {
        let endPrevious = tracking || endPending
        tracking = false
        endPending = false
        return endPrevious
    }

    mutating func noteTracking() {
        tracking = true
        endPending = false
    }

    /// Returns whether the caller should schedule the delayed end.
    mutating func endGesture() -> Bool {
        let wasTracking = tracking
        tracking = false
        if wasTracking { endPending = true }
        return wasTracking
    }

    mutating func fireDelayedEnd() {
        endPending = false
    }
}

/// Watches file drags. Reads only `changeCount` and pasteboard types, never file contents.
///
/// The global monitor sees other apps. A click in one of our own windows is invisible to that
/// monitor, so a local monitor applies the same session rules.
@MainActor
final class DragMonitor {
    static weak var shared: DragMonitor?

    var onBegan: () -> Void = {}
    var onMoved: () -> Void = {}
    var onEnded: () -> Void = {}

    private var monitor: Any?
    private var localMonitor: Any?
    private var origin: CGPoint?
    private var originCount = 0
    private var session = DragSessionModel()
    private var lastProbe: ContinuousClock.Instant?
    private var endToken = 0

    var isRunning: Bool { monitor != nil }

    @discardableResult
    func start() -> Bool {
        if monitor != nil { return true }
        Self.shared = self
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            let type = event.type
            let location = NSEvent.mouseLocation
            if Thread.isMainThread {
                MainActor.assumeIsolated { DragMonitor.shared?.handle(type: type, location: location) }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { DragMonitor.shared?.handle(type: type, location: location) }
                }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            let type = event.type
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { DragMonitor.shared?.handle(type: type, location: location) }
            return event
        }
        return monitor != nil
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
        origin = nil
        session = DragSessionModel()
        if Self.shared === self { Self.shared = nil }
    }

    private func handle(type: NSEvent.EventType, location: CGPoint) {
        switch type {
        case .leftMouseDown:
            endToken += 1
            let endPrevious = session.beginGesture()
            origin = location
            originCount = NSPasteboard(name: .drag).changeCount
            lastProbe = nil
            if endPrevious { onEnded() }
        case .leftMouseDragged:
            guard let origin else { return }
            let distance = hypot(location.x - origin.x, location.y - origin.y)
            if !session.tracking {
                guard distance >= 24 else { return }
                let now = ContinuousClock.now
                if let lastProbe, lastProbe.duration(to: now) < .milliseconds(50) { return }
                self.lastProbe = now
                let board = NSPasteboard(name: .drag)
                let types = board.types ?? []
                let isFile = types.contains(.fileURL)
                let isSelf = types.contains(Logn.selfDragType)
                guard board.changeCount != originCount, isFile, !isSelf else { return }
                session.noteTracking()
                onBegan()
            }
            onMoved()
        case .leftMouseUp:
            origin = nil
            guard session.endGesture() else { return }
            endToken += 1
            let token = endToken
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard token == self.endToken else { return }
                self.session.fireDelayedEnd()
                self.onEnded()
            }
        default:
            break
        }
    }
}
