import AppKit

enum Haptics {
    @MainActor
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern, enabled: Bool) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
