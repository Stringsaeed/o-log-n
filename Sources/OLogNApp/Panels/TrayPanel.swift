import AppKit
@preconcurrency import Quartz

@MainActor
final class TrayPanel: NSPanel {
    var previewURLs: [URL] = []
    var previewTitle = "Logn"

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovable = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showQuickLook() {
        QuickLookController.toggle(self)
    }
}

extension TrayPanel {
    @objc override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    @objc override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
        }
    }

    @objc override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            PanelCoordinator.shared?.quickLookEnded()
        }
    }
}

extension TrayPanel: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let pair: (URL, String)? = MainActor.assumeIsolated {
            guard previewURLs.indices.contains(index) else { return nil }
            return (previewURLs[index], previewTitle)
        }
        guard let pair else { return nil }
        return PreviewFile(url: pair.0, title: pair.1)
    }
}
