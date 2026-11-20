import SwiftUI
import OLogNKit

struct ControlBar: View {
    @Environment(JobStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(PanelCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Namespace private var modeNS
    @State private var clearHover = false
    @State private var gearHover = false

    var body: some View {
        HStack(spacing: 8) {
            if coordinator.settingsOpen {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
            } else {
                modeControl
                qualityControl
                formatControl
                outputControl
                Spacer(minLength: 8)
                savings
                clearButton
            }
            Button {
                coordinator.toggleSettings()
            } label: {
                Image(systemName: coordinator.settingsOpen ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(coordinator.settingsOpen ? LognColor.accent(scheme) : Color.primary)
                    .background {
                        Circle().fill(Color.primary.opacity(gearHover ? (scheme == .dark ? 0.13 : 0.09) : 0.06))
                    }
                    .rotateEffect(coordinator.settingsOpen, enabled: !coordinator.reduceMotion)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { gearHover = $0 }
            .accessibilityLabel("Settings")
        }
        .frame(height: 40)
    }

    private var modeControl: some View {
        HStack(spacing: 2) {
            ForEach(CompressionMode.allCases, id: \.self) { mode in
                let selected = settings.settings.defaultMode == mode
                Button {
                    let animation = LognMotion.spring(response: 0.22, damping: 0.88, reduce: coordinator.reduceMotion)
                    withAnimation(animation) { settings.settings.defaultMode = mode }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode == .smart ? "sparkles" : "checkmark.shield")
                            .font(.system(size: 11, weight: .semibold))
                        Text(mode.title)
                            .font(LognFont.control)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.75))
                    .background {
                        if selected {
                            Capsule()
                                .fill(LognColor.segmentThumb(scheme))
                                .overlay {
                                    Capsule().strokeBorder(
                                        Color.white.opacity(scheme == .dark ? 0.24 : 0.6),
                                        lineWidth: 0.5)
                                }
                                .matchedGeometryEffect(id: "mode-thumb", in: modeNS)
                        }
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(2)
        .frame(width: 184, height: 30)
        .background { SoftPillBackground(hovered: false) }
        .accessibilityLabel("Mode")
    }

    @ViewBuilder
    private var qualityControl: some View {
        if settings.settings.defaultMode == .lossless {
            Text("Exact quality")
                .font(LognFont.control)
                .foregroundStyle(Color.primary.opacity(0.82))
                .frame(width: 116, height: 30)
                .background { SoftPillBackground(hovered: false) }
        } else {
            Menu {
                ForEach(QualityPreset.allCases, id: \.self) { preset in
                    Button(preset.title) { settings.settings.engine.quality = preset }
                }
            } label: {
                pillLabel(settings.settings.engine.quality.title, symbol: nil)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 116, height: 30)
            .accessibilityLabel("Quality")
        }
    }

    private var formatControl: some View {
        let tinted = settings.settings.engine.imageConversion != .keep
            || settings.settings.engine.archiveFormat == .zip
        return Menu {
            ForEach(ImageConversion.allCases, id: \.self) { conversion in
                Button(conversion.title) { settings.settings.engine.imageConversion = conversion }
            }
            Section("Folders & Archives") {
                Button("Smallest (.tar.xz)") { settings.settings.engine.archiveFormat = .xz }
                Button("Opens everywhere (.zip)") { settings.settings.engine.archiveFormat = .zip }
            }
        } label: {
            pillLabel(shortFormat, symbol: tinted ? "arrow.right.circle.fill" : nil, tinted: tinted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 128, height: 30)
        .accessibilityLabel("Format conversion")
    }

    private var outputControl: some View {
        Menu {
            Button("Next to file (\(settings.settings.engine.suffix))") {
                settings.settings.engine.output = .nextToOriginal
            }
            if case .folder(let url) = settings.settings.engine.output {
                Button("Reveal \(url.lastPathComponent)") { coordinator.revealOutputFolder() }
            }
            Button("Choose Folder…") { coordinator.chooseOutputFolder() }
        } label: {
            pillLabel(outputTitle, symbol: "folder")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 190)
        .frame(height: 30)
        .accessibilityLabel("Output location")
    }

    private var savings: some View {
        HStack(spacing: 4) {
            Text("Saved")
                .font(LognFont.control)
                .foregroundStyle(Color.primary.opacity(0.82))
            Text(ByteText.string(store.savedBytesSession))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(store.savedBytesSession > 0 ? LognColor.emeraldText(scheme) : Color.primary.opacity(0.82))
                .ticker(value: store.savedBytesSession, enabled: !coordinator.reduceMotion)
            Text("this session")
                .font(LognFont.control)
                .foregroundStyle(Color.primary.opacity(0.82))
        }
        .lineLimit(1)
        .help("Savings since Logn was opened")
    }

    private var hasTerminalJobs: Bool {
        store.items.contains { $0.job.state.isTerminal }
    }

    private var clearButton: some View {
        Button("Clear Done") { store.clearFinished() }
            .buttonStyle(.plain)
            .font(LognFont.control)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background { SoftPillBackground(hovered: clearHover && hasTerminalJobs) }
            .opacity(hasTerminalJobs ? 1 : 0.38)
            .allowsHitTesting(hasTerminalJobs)
            .onHover { clearHover = $0 }
            .accessibilityLabel("Clear done")
    }

    private func pillLabel(_ title: String, symbol: String?, tinted: Bool = false) -> some View {
        HStack(spacing: 0) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tinted ? LognColor.accent(scheme) : Color.primary.opacity(0.82))
                    .padding(.trailing, 4)
            }
            Text(title)
                .font(LognFont.control)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
        }
        .foregroundStyle(tinted ? LognColor.accent(scheme) : Color.primary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background { SoftPillBackground(hovered: false) }
    }

    private var shortFormat: String {
        let image: String
        switch settings.settings.engine.imageConversion {
        case .keep: image = "Keep Format"
        case .heic: image = "→ HEIC"
        case .avif: image = "→ AVIF"
        }
        guard settings.settings.engine.archiveFormat == .zip else { return image }
        if settings.settings.engine.imageConversion == .keep { return ".zip" }
        return "\(image) · .zip"
    }

    private var outputTitle: String {
        switch settings.settings.engine.output {
        case .nextToOriginal:
            "Next to file (\(settings.settings.engine.suffix))"
        case .folder(let url):
            "Folder: \(url.lastPathComponent)"
        }
    }
}

struct SoftPillBackground: View {
    var hovered: Bool
    @Environment(PanelCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let flat = reduceTransparency || coordinator.forceReduceTransparency
        let fill = LognColor.flatOrGlassFill(scheme, flat: flat, hovered: hovered)
        let strong = contrast == .increased
        let stroke = strong
            ? Color.primary.opacity(0.55)
            : (flat ? Color(nsColor: .separatorColor) : Color.primary.opacity(scheme == .dark ? 0.14 : 0.10))
        Capsule()
            .fill(fill)
            .overlay {
                Capsule().strokeBorder(stroke, lineWidth: strong ? 1.5 : (flat ? 1 : 0.5))
            }
    }
}
