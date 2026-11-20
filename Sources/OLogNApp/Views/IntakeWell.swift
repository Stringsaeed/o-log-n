import SwiftUI
import OLogNKit

struct IntakeWell: View {
    @Environment(JobStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(PanelCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button {
            coordinator.browse()
        } label: {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: coordinator.trayDragActive ? "arrow.down.doc.fill" : "square.and.arrow.down")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: 42, height: 42)
                    .background {
                        Circle().fill(coordinator.trayDragActive ? LognColor.accentFill(scheme) : Color.primary.opacity(0.06))
                    }
                    .bounceEffect(coordinator.trayDragActive, enabled: !coordinator.reduceMotion)
                Text(prompt)
                    .font(LognFont.control)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                if coordinator.trayDragActive {
                    Text(aimCaption)
                        .font(LognFont.meta)
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .multilineTextAlignment(.center)
                } else {
                    HStack(spacing: 4) {
                        Text("Click to browse ·")
                            .font(LognFont.meta)
                            .foregroundStyle(Color.primary.opacity(0.72))
                        Keycap(text: "⌘V")
                    }
                }
                if coordinator.trayDragActive {
                    HStack(spacing: 8) {
                        aimChip(.smart)
                        aimChip(.lossless)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                if store.active > 0 {
                    statusStrip
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                wellFill,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        coordinator.trayDragActive ? LognColor.accent(scheme) : Color.primary.opacity(hovering ? 0.42 : 0.22),
                        style: StrokeStyle(lineWidth: coordinator.trayDragActive ? 2 : 1, dash: coordinator.trayDragActive ? [] : [5, 4]))
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            let animation = LognMotion.spring(response: 0.18, damping: 0.88, reduce: coordinator.reduceMotion)
            withAnimation(animation) { hovering = inside }
        }
        .accessibilityLabel("Drop files or folders. Click to browse.")
    }

    private var iconTint: Color {
        if coordinator.trayDragActive { return LognColor.accent(scheme) }
        return hovering ? Color.primary : Color.primary.opacity(0.82)
    }

    private var wellFill: Color {
        if coordinator.trayDragActive { return LognColor.accentFill(scheme) }
        return LognColor.wellFill(scheme, hovered: hovering)
    }

    private var prompt: String {
        if coordinator.trayDragActive {
            return "Drop for \(aim.title)"
        }
        return "Drop files or folders"
    }

    private var aimCaption: String {
        if aim == .smart {
            return "Drop for Smart (\(settings.settings.engine.quality.title))"
        }
        return "Drop for Lossless"
    }

    private var aim: CompressionMode {
        coordinator.trayAim ?? settings.settings.defaultMode
    }

    private func aimChip(_ mode: CompressionMode) -> some View {
        Text(mode.title)
            .font(LognFont.meta)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(aim == mode ? LognColor.accentFill(scheme) : Color.clear, in: Capsule())
            .overlay {
                Capsule().strokeBorder(aim == mode ? LognColor.accentBorder(scheme) : Color.primary.opacity(0.15))
            }
            .opacity(aim == mode ? 1 : 0.62)
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LognColor.accent(scheme))
                .pulseEffect(active: store.active > 0, enabled: !coordinator.reduceMotion)
            Text(store.throughputLabel)
                .font(LognFont.badge)
                .lineLimit(1)
                .ticker(value: store.throughputLabel, enabled: !coordinator.reduceMotion)
            Spacer(minLength: 4)
            Button("Cancel All") { store.cancelAll() }
                .buttonStyle(.plain)
                .font(LognFont.meta)
        }
        .frame(height: 24)
    }
}
