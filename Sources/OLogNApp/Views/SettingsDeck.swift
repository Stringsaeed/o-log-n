import SwiftUI
import OLogNKit

/// Three columns, five rows. At a 248 pt tray the workspace under the control
/// bar is 176 pt, so this deck does not scroll.
struct SettingsDeck: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PanelCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            column("Presence") {
                modeRow
                menuRow("Dropzone", settings.settings.presence.title) {
                    ForEach(DropzonePresence.allCases, id: \.self) { presence in
                        Button(presence.title) { settings.settings.presence = presence }
                    }
                    if settings.settings.presence == .always {
                        Divider()
                        Button("Anchor: Top center") { settings.settings.anchor = .topCenter }
                        Button("Anchor: Right center") { settings.settings.anchor = .rightCenter }
                        Button("Anchor: Left center") { settings.settings.anchor = .leftCenter }
                    }
                }
                .accessibilityLabel("Dropzone presence")
                shortcutRow
                toggleRow("Launch at login", isOn: launchAtLogin)
                if let loginError = settings.loginError {
                    note(loginError)
                }
                toggleRow("Haptics", isOn: haptics)
                if let fallback = settings.fallbackNote {
                    note(fallback)
                }
            }
            column("Compression") {
                menuRow("Quality", settings.settings.engine.quality.title) {
                    ForEach(QualityPreset.allCases, id: \.self) { preset in
                        Button(preset.title) { settings.settings.engine.quality = preset }
                    }
                }
                .accessibilityLabel("Quality")
                menuRow("Format", settings.settings.engine.imageConversion.title) {
                    ForEach(ImageConversion.allCases, id: \.self) { conversion in
                        Button(conversion.title) { settings.settings.engine.imageConversion = conversion }
                    }
                }
                .accessibilityLabel("Format conversion")
                menuRow("Archive", settings.settings.engine.archiveFormat.title) {
                    ForEach(ArchiveFormat.allCases, id: \.self) { format in
                        Button(format.title) { settings.settings.engine.archiveFormat = format }
                    }
                }
                .accessibilityLabel("Archive format")
                menuRow("Lossless JPEG", jpegTitle) {
                    Button("Identical pixels · 1–2%") { settings.settings.engine.jpegLossless = .pixelExact }
                    Button("Progressive · 4–10%") { settings.settings.engine.jpegLossless = .progressive }
                }
                .accessibilityLabel("Lossless JPEG")
                toggleRow("Strip metadata in Smart", isOn: strip)
            }
            column("Output") {
                menuRow("Output", outputTitle) {
                    Button("Next to file (\(settings.settings.engine.suffix))") {
                        settings.settings.engine.output = .nextToOriginal
                    }
                    if case .folder(let url) = settings.settings.engine.output {
                        Button("Reveal \(url.lastPathComponent)") { coordinator.revealOutputFolder() }
                    }
                    Button("Choose Folder…") { coordinator.chooseOutputFolder() }
                }
                .accessibilityLabel("Output location")
                suffixRow
                menuRow("Workers", settings.settings.engine.maxCPUJobs.map(String.init) ?? "Auto") {
                    Button("Auto") { settings.settings.engine.maxCPUJobs = nil }
                    ForEach([1, 2, 4, 8], id: \.self) { count in
                        Button("\(count)") { settings.settings.engine.maxCPUJobs = count }
                    }
                }
                .accessibilityLabel("Workers")
                .help("Auto uses the P-core count. A change applies to jobs still waiting.")
                toggleRow("Preserve dates", isOn: dates)
                menuRow("History", historyTitle) {
                    Button("On Quit") { settings.settings.historyDays = 0 }
                    Button("24h") { settings.settings.historyDays = 1 }
                    Button("7 days") { settings.settings.historyDays = 7 }
                }
                .accessibilityLabel("History")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private func column<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .textCase(.uppercase)
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(scheme == .dark ? 0.05 : 0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(LognFont.meta)
            .foregroundStyle(LognColor.amberText(scheme))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeRow: some View {
        HStack {
            Text("Mode")
                .font(LognFont.meta)
                .foregroundStyle(Color.primary.opacity(0.82))
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(CompressionMode.allCases, id: \.self) { mode in
                    let on = settings.settings.defaultMode == mode
                    Button(mode.title) { settings.settings.defaultMode = mode }
                        .buttonStyle(.plain)
                        .font(LognFont.control)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.75))
                        .background {
                            if on { Capsule().fill(LognColor.segmentThumb(scheme)) }
                        }
                        .focusEffectDisabled()
                }
            }
            .padding(2)
            .background { Capsule().fill(Color.primary.opacity(0.07)) }
        }
        .frame(minHeight: 24)
        .accessibilityLabel("Default mode")
    }

    private var shortcutRow: some View {
        HStack(spacing: 8) {
            Text("Shortcut")
                .font(LognFont.meta)
                .foregroundStyle(Color.primary.opacity(0.82))
            Spacer(minLength: 8)
            Text(hotkeyLabel)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)))
            Button("Reset") { settings.resetHotkey() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .frame(minHeight: 24)
        .accessibilityLabel("Shortcut \(hotkeyLabel)")
    }

    private var suffixRow: some View {
        HStack(spacing: 8) {
            Text("Suffix")
                .font(LognFont.meta)
                .foregroundStyle(Color.primary.opacity(0.82))
            Spacer(minLength: 8)
            TextField("Suffix", text: suffix)
                .textFieldStyle(.roundedBorder)
                .font(LognFont.meta)
                .frame(maxWidth: 120)
        }
        .frame(minHeight: 24)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(LognFont.meta)
                .foregroundStyle(Color.primary.opacity(0.82))
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(minHeight: 24)
    }

    private func menuRow<Content: View>(_ title: String, _ value: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(LognFont.meta)
                .foregroundStyle(Color.primary.opacity(0.82))
                .lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                content()
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.72))
                }
                .font(LognFont.control)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 24)
    }

    private var hotkeyLabel: String {
        let mods = settings.settings.hotkeyModifiers
        var symbols = ""
        if mods & (1 << 12) != 0 { symbols += "⌃" }
        if mods & (1 << 11) != 0 { symbols += "⌥" }
        if mods & (1 << 9) != 0 { symbols += "⇧" }
        if mods & (1 << 8) != 0 { symbols += "⌘" }
        let key = settings.settings.hotkeyKeyCode == 49 ? "Space" : "Key \(settings.settings.hotkeyKeyCode)"
        return symbols + key
    }

    private var jpegTitle: String {
        switch settings.settings.engine.jpegLossless {
        case .pixelExact: "Identical pixels · 1–2%"
        case .progressive: "Progressive · 4–10%"
        }
    }

    private var outputTitle: String {
        switch settings.settings.engine.output {
        case .nextToOriginal: "Next to file"
        case .folder(let url): url.lastPathComponent
        }
    }

    private var historyTitle: String {
        switch settings.settings.historyDays {
        case 0: "On Quit"
        case 1: "24h"
        default: "\(settings.settings.historyDays) days"
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { settings.settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) })
    }

    private var haptics: Binding<Bool> {
        Binding(get: { settings.settings.haptics }, set: { settings.settings.haptics = $0 })
    }

    private var strip: Binding<Bool> {
        Binding(
            get: { settings.settings.engine.stripMetadataInSmart },
            set: { settings.settings.engine.stripMetadataInSmart = $0 })
    }

    private var dates: Binding<Bool> {
        Binding(
            get: { settings.settings.engine.preserveDates },
            set: { settings.settings.engine.preserveDates = $0 })
    }

    private var suffix: Binding<String> {
        Binding(
            get: { settings.settings.engine.suffix },
            set: { settings.settings.engine.suffix = $0 })
    }
}
