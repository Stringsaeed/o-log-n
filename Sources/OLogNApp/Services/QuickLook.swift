import AppKit
@preconcurrency import Quartz

/// Quick Look for a compressed file. `TrayPanel` stays the panel controller so the
/// preview shares the tray's key window; this type owns the preview item and the toggle.
enum QuickLookController {
    @MainActor
    static func toggle(_ panel: TrayPanel) {
        guard !panel.previewURLs.isEmpty else { return }
        panel.makeKey()
        let preview = QLPreviewPanel.shared()
        if QLPreviewPanel.sharedPreviewPanelExists(), preview?.isVisible == true {
            preview?.orderOut(nil)
            PanelCoordinator.shared?.quickLookEnded()
            return
        }
        preview?.makeKeyAndOrderFront(nil)
    }
}

final class PreviewFile: NSObject, QLPreviewItem, @unchecked Sendable {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}
