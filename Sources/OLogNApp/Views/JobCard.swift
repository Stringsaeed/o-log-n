import AppKit
import SwiftUI
import OLogNKit

struct JobCard: View {
    let item: JobItem
    var grouped = false
    @Environment(JobStore.self) private var store
    @Environment(PanelCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    @State private var thumbHovered = false

    var body: some View {
        let selected = store.selectedID == item.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.job.request.source.lastPathComponent)
                        .font(LognFont.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(meta)
                        .font(LognFont.meta)
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                sizeColumn
                    .frame(width: 152, alignment: .trailing)
                badge
                    .frame(width: 72, alignment: .trailing)
                actions
                    .frame(width: 116, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
            if let actionError = item.actionError, !actionError.isEmpty {
                Text(actionError)
                    .font(LognFont.meta)
                    .foregroundStyle(LognColor.coralText(scheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { cardBackground(selected: selected) }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor(selected: selected), lineWidth: borderWidth(selected: selected))
        }
        .overlay(alignment: .leading) {
            if grouped {
                Capsule()
                    .fill(LognColor.accent(scheme))
                    .frame(width: 2)
                    .padding(.vertical, 10)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            store.selectedID = item.id
            coordinator.revealSelected()
        }
        .onTapGesture { store.selectedID = item.id }
        .animation(LognMotion.spring(response: 0.16, damping: 0.90, reduce: coordinator.reduceMotion), value: hovering)
        .animation(LognMotion.spring(response: 0.16, damping: 0.90, reduce: coordinator.reduceMotion), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            ForEach(cardCommands) { command in
                Button(command.title) {
                    guard command.enabled else { return }
                    store.selectedID = item.id
                    command.run()
                }
                .disabled(!command.enabled)
            }
        }
    }

    private var thumbnail: some View {
        let preview = item.outputURL ?? item.job.request.source
        return FileThumbnailView(url: preview, size: 38, cornerRadius: 8)
            .opacity(thumbOpacity)
            .scaleEffect(!coordinator.reduceMotion && thumbHovered && item.outputURL != nil ? 1.05 : 1)
            .shadow(color: .black.opacity(thumbHovered && item.outputURL != nil ? 0.20 : 0), radius: 4, y: 1)
            .onHover { thumbHovered = $0 }
            .help(item.outputURL == nil ? "" : "Drag compressed file")
            .onDrag {
                guard item.outputURL != nil else { return NSItemProvider() }
                let id = item.id
                return DragURLs.claimingProvider {
                    await store.claimOutput(id)
                }
            }
    }

    @ViewBuilder
    private var sizeColumn: some View {
        switch item.job.state {
        case .queued:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
        case .running(let fraction):
            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteText.string(item.job.inputBytes))
                    .font(LognFont.metric)
                    .foregroundStyle(Color.primary.opacity(0.82))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10)).frame(width: 112, height: 5)
                    Capsule()
                        .fill(LognColor.accent(scheme))
                        .frame(width: max(5, 112 * fraction), height: 5)
                }
            }
        case .finished(let result):
            if result.outcome == .alreadyOptimal || result.outputURL == nil {
                Text(ByteText.string(result.inputBytes))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            } else {
                HStack(spacing: 4) {
                    Text(ByteText.string(result.inputBytes))
                        .font(.system(size: 12, weight: .regular).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.82))
                    Text("→")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.72))
                    Text(ByteText.string(result.outputBytes))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .lineLimit(1)
            }
        case .failed, .cancelled:
            Text(ByteText.string(item.job.inputBytes))
                .font(.system(size: 12, weight: .regular).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.82))
        }
    }

    private var badge: some View {
        HStack(spacing: 3) {
            if let symbol = badgeSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .bounceEffect(item.replaced, enabled: !coordinator.reduceMotion && item.replaced)
            }
            Text(badgeText)
                .font(LognFont.badge)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .ticker(value: badgeText, enabled: !coordinator.reduceMotion)
        }
        .foregroundStyle(badgeColor)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(badgeFill, in: Capsule())
    }

    private var actions: some View {
        HStack(spacing: 2) {
            ForEach(pointerCommands) { command in
                ActionIconButton(systemName: command.symbol, help: command.help, coral: command.coral) {
                    store.selectedID = item.id
                    // Stay hittable when disabled so the tooltip can explain why. The action does not run.
                    guard command.enabled else { return }
                    command.run()
                }
                .opacity(commandOpacity(command))
                .allowsHitTesting(command.resting || hovering || store.selectedID == item.id)
            }
        }
    }

    private func commandOpacity(_ command: CardCommand) -> Double {
        guard command.enabled else { return 0.3 }
        if command.resting || hovering || store.selectedID == item.id { return 1 }
        return 0
    }

    private func cardBackground(selected: Bool) -> some View {
        let state: LognColor.CardChrome = selected ? .selected : (hovering ? .hovered : .idle)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return shape.fill(LognColor.cardFill(scheme, state: state))
            .overlay {
                if selected {
                    shape.fill(LognColor.accentFill(scheme).opacity(0.35))
                }
            }
    }

    private func borderColor(selected: Bool) -> Color {
        if isFailed { return LognColor.coralText(scheme) }
        if selected { return LognColor.accentBorder(scheme) }
        if contrast == .increased { return Color.primary.opacity(0.55) }
        return LognColor.cardBorder(scheme)
    }

    private func borderWidth(selected: Bool) -> CGFloat {
        let base: CGFloat
        if isFailed { base = 1 }
        else if selected { base = 1.25 }
        else { base = 0.5 }
        if contrast == .increased { return max(base, 1.5) }
        return base
    }

    private var meta: String {
        let kind = item.job.kind.label
        let mode = item.job.request.mode.title
        switch item.job.state {
        case .queued:
            return "\(kind) · \(mode) · Queued"
        case .running:
            if let rate = store.bytesPerSecond(for: item.id) {
                return "\(kind) · \(mode) · \(ByteText.rate(rate))"
            }
            return "\(kind) · \(mode)"
        case .finished(let result):
            if item.replaced {
                if let note = item.replacedNote { return note }
                return "\(kind) · \(mode) · Replaced original"
            }
            if result.outcome == .alreadyOptimal || result.method.isEmpty {
                return "\(kind) · \(mode) · No smaller output possible"
            }
            var detail = result.method
            if detail.hasPrefix(kind) {
                detail = detail.dropFirst(kind.count).trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
            }
            if detail.isEmpty { return "\(kind) · \(mode)" }
            return "\(kind) · \(mode) · \(detail)"
        case .cancelled:
            return "Cancelled — original untouched"
        case .failed(let error):
            return failureText(error)
        }
    }

    private func failureText(_ error: JobError) -> String {
        switch error {
        case .unreadable(let detail):
            return detail.isEmpty ? "Read failed" : detail
        case .outputNotWritable(let detail):
            return detail.isEmpty ? "No write permission" : detail
        case .diskFull:
            return "Disk full"
        case .verificationFailed(let detail), .codec(let detail):
            return detail.isEmpty ? "Couldn't compress" : detail
        }
    }

    private var badgeText: String {
        switch item.job.state {
        case .queued: "Waiting"
        case .running(let fraction): "\(Int((fraction * 100).rounded()))%"
        case .finished(let result):
            result.outcome == .compressed && result.savedBytes > 0
                ? ByteText.percent(result.savedFraction)
                : "Optimal"
        case .cancelled: "Stopped"
        case .failed: "Failed"
        }
    }

    private var badgeSymbol: String? {
        if item.replaced { return "checkmark.circle.fill" }
        switch item.job.state {
        case .finished(let result) where result.outcome != .compressed || result.savedBytes <= 0:
            return "equal.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return nil
        }
    }

    private var badgeColor: Color {
        switch item.job.state {
        case .finished(let result) where result.savedBytes > 0 || item.replaced:
            LognColor.emeraldText(scheme)
        case .running:
            LognColor.cobaltText(scheme)
        case .failed:
            LognColor.coralText(scheme)
        default:
            Color.primary.opacity(0.78)
        }
    }

    private var badgeFill: Color {
        switch item.job.state {
        case .finished(let result) where result.savedBytes > 0 || item.replaced:
            LognColor.emeraldText(scheme).opacity(0.13)
        case .running:
            LognColor.cobaltText(scheme).opacity(0.13)
        case .failed:
            LognColor.coralText(scheme).opacity(0.13)
        default:
            Color.primary.opacity(0.12)
        }
    }

    private var thumbOpacity: Double {
        switch item.job.state {
        case .queued: 0.82
        case .cancelled: 0.60
        default: 1
        }
    }

    private var isFailed: Bool {
        if case .failed = item.job.state { return true }
        return false
    }

    private var isPermission: Bool {
        if case .failed(.outputNotWritable) = item.job.state { return true }
        return false
    }

    private var showRetry: Bool {
        switch item.job.state {
        case .cancelled, .failed: true
        default: false
        }
    }

    private var canReplace: Bool {
        item.canReplaceOriginal
    }

    /// Pointer buttons and VoiceOver actions come from this one list.
    private var cardCommands: [CardCommand] {
        var commands: [CardCommand] = [
            CardCommand(id: "reveal", title: "Reveal in Finder", symbol: "folder", help: "Reveal in Finder", resting: false) {
                coordinator.revealSelected()
            },
        ]
        commands.append(CardCommand(
            id: "copy",
            title: "Copy Compressed File",
            symbol: "doc.on.doc",
            help: "Copy",
            enabled: item.outputURL != nil && item.outputFingerprint != nil,
            resting: false
        ) {
            coordinator.copySelected()
        })
        if showRetry {
            if isPermission {
                commands.append(CardCommand(
                    id: "folder",
                    title: "Choose Folder…",
                    symbol: "folder.badge.plus",
                    help: "Choose Folder…",
                    resting: true
                ) {
                    coordinator.chooseOutputFolder()
                })
            } else {
                commands.append(CardCommand(
                    id: "retry",
                    title: "Retry",
                    symbol: "arrow.clockwise",
                    help: "Retry",
                    resting: true
                ) {
                    store.retry(item.id)
                })
            }
        } else {
            commands.append(CardCommand(
                id: "replace",
                title: "Replace Original (Moves Original to Trash)",
                symbol: "arrow.2.squarepath",
                help: item.replaceOriginalHelp,
                enabled: canReplace,
                resting: false
            ) {
                coordinator.replaceSelected()
            })
        }
        commands.append(CardCommand(
            id: "preview",
            title: "Preview with Quick Look",
            symbol: "eye",
            help: "Quick Look",
            resting: false
        ) {
            coordinator.previewItem(item)
        })
        let terminal = item.job.state.isTerminal
        commands.append(CardCommand(
            id: "close",
            title: terminal ? "Remove from List" : "Cancel Compression",
            symbol: "xmark",
            help: terminal ? "Remove" : "Cancel",
            resting: false,
            coral: true
        ) {
            if terminal {
                store.remove(item.id)
            } else {
                store.cancel(item.id)
            }
        })
        return commands
    }

    /// Quick Look stays a VoiceOver action. Five pointer buttons do not fit the 116 pt slot.
    private var pointerCommands: [CardCommand] {
        cardCommands.filter { $0.id != "preview" }
    }

    private var voiceLabel: String {
        let name = item.job.request.source.lastPathComponent
        let summary: String
        switch item.job.state {
        case .queued:
            summary = "\(name), waiting"
        case .running(let fraction):
            summary = "\(name), \(Int((fraction * 100).rounded())) percent"
        case .cancelled:
            summary = "\(name), stopped"
        case .failed:
            summary = "\(name), failed. \(meta)"
        case .finished(let result):
            if item.replaced {
                summary = "\(name), replaced. \(item.replacedNote ?? meta)"
            } else if result.outcome == .alreadyOptimal || result.outputURL == nil {
                summary = "\(name), already optimal. \(ByteText.string(result.inputBytes))"
            } else {
                summary = "\(name), completed. \(ByteText.string(result.inputBytes)) → \(ByteText.string(result.outputBytes)), saved \(ByteText.percent(result.savedFraction))"
            }
        }
        if let actionError = item.actionError, !actionError.isEmpty {
            return "\(summary). \(actionError)"
        }
        return summary
    }
}

struct CardCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var help: String
    var enabled = true
    var resting = false
    var coral = false
    let run: () -> Void
}

struct ActionIconButton: View {
    let systemName: String
    var help: String
    var coral = false
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(coral && hovered ? LognColor.coralText(scheme) : Color.primary)
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.12 : 0))
                }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
