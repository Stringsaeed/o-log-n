import SwiftUI

struct TrayToast: Equatable {
    var message: String
    var offerUndo = false
    var offerDismiss = false
}

struct UndoToast: View {
    @Environment(JobStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let toast = store.toast {
            HStack(spacing: 10) {
                Text(toast.message)
                    .font(LognFont.toast)
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if toast.offerUndo {
                    Button {
                        Task { await store.undoLastReplace() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Undo")
                            Keycap(text: "⌘Z")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LognColor.accent(scheme))
                    .accessibilityLabel("Undo replace")
                }
                if toast.offerDismiss {
                    Button("Dismiss") { store.dismissBlockedUndo() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(LognColor.amberText(scheme))
                        .accessibilityLabel("Dismiss undo")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(toastFill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            }
            .padding(.bottom, 10)
            .transition(.opacity)
        }
    }

    private var toastFill: Color {
        scheme == .dark
            ? Color(red: 0.12, green: 0.16, blue: 0.24)
            : Color(red: 0.93, green: 0.95, blue: 0.99)
    }
}
