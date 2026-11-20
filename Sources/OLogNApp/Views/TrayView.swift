import SwiftUI
import OLogNKit

struct TrayView: View {
    @Environment(JobStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(PanelCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            ControlBar()
            if store.pausedReason != nil, !coordinator.settingsOpen {
                diskBanner
            }
            if coordinator.settingsOpen {
                SettingsDeck()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    IntakeWell()
                        .frame(width: coordinator.intakeWidth)
                    queue
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .adaptiveGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), role: .panel)
        .overlay {
            if contrastBorder {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
            }
        }
        .opacity(coordinator.trayPresented ? 1 : 0)
        .offset(y: slide)
        .overlay(alignment: .bottom) {
            if !coordinator.settingsOpen {
                UndoToast()
            }
        }
        .animation(trayMotion, value: coordinator.trayPresented)
        .animation(settingsMotion, value: coordinator.settingsOpen)
    }

    @Environment(\.colorSchemeContrast) private var contrast
    private var contrastBorder: Bool { contrast == .increased }

    private var slide: CGFloat {
        if coordinator.reduceMotion || coordinator.trayPresented { return 0 }
        return 28
    }

    private var trayMotion: Animation {
        coordinator.reduceMotion
            ? .linear(duration: 0.14)
            : .spring(response: 0.30, dampingFraction: 0.86)
    }

    private var settingsMotion: Animation {
        LognMotion.spring(response: 0.24, damping: 0.90, reduce: coordinator.reduceMotion)
    }

    private var queue: some View {
        Group {
            if store.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Color.primary.opacity(0.72))
                    Text("No recent jobs")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.82))
                    HStack(spacing: 4) {
                        Text("Drop anywhere, browse on the left, or press")
                            .font(LognFont.meta)
                            .foregroundStyle(Color.primary.opacity(0.82))
                        Keycap(text: "⌘V")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { row in
                            switch row.kind {
                            case .header(let count, let saved):
                                BatchHeader(count: count, saved: saved)
                            case .card(let item, let grouped, let gapBefore):
                                JobCard(item: item, grouped: grouped)
                                    .padding(.top, gapBefore ? 8 : 0)
                                    .transition(cardTransition)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.bottom, 8)
                    .padding(.trailing, 4)
                }
                .scrollClipDisabled(false)
                .mask {
                    if store.items.count > 3 {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 10)
                        }
                    } else {
                        Color.black
                    }
                }
                .animation(cardSpring, value: store.items.map(\.id.raw))
            }
        }
    }

    private var cardTransition: AnyTransition {
        if coordinator.reduceMotion { return .opacity }
        return .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity)
    }

    private var cardSpring: Animation {
        LognMotion.spring(response: 0.26, damping: 0.85, reduce: coordinator.reduceMotion)
    }

    private var rows: [QueueRow] {
        QueueRow.make(from: store.items)
    }

    private var diskBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LognColor.coralText(scheme))
            Text(diskCopy)
                .lineLimit(1)
                .foregroundStyle(LognColor.coralText(scheme))
            Spacer(minLength: 8)
            Button("Resume") { store.resume() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Color(red: 0xDC / 255, green: 0x26 / 255, blue: 0x26 / 255), in: Capsule())
            Button("Cancel Queue") { store.cancelAll() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(cancelInk)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .overlay {
                    Capsule().strokeBorder(cancelInk.opacity(0.70), lineWidth: 1)
                }
        }
        .font(LognFont.control)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(LognColor.coralFill(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var cancelInk: Color {
        scheme == .dark
            ? Color(red: 0xFE / 255, green: 0xCA / 255, blue: 0xCA / 255)
            : Color(red: 0x99 / 255, green: 0x1B / 255, blue: 0x1B / 255)
    }

    private var diskCopy: String {
        if store.pausedReason == "disk full" {
            return "Disk full — paused \(max(store.active, store.queuedCount)) remaining jobs"
        }
        return store.pausedReason ?? ""
    }
}

struct QueueRow: Identifiable {
    enum Kind {
        case header(count: Int, saved: Int64)
        case card(JobItem, grouped: Bool, gapBefore: Bool)
    }

    var id: String
    var kind: Kind

    static func make(from items: [JobItem]) -> [QueueRow] {
        var counts: [UUID: Int] = [:]
        var saved: [UUID: Int64] = [:]
        for item in items {
            guard let batch = item.job.request.batchID else { continue }
            counts[batch, default: 0] += 1
            if case .finished(let result) = item.job.state {
                saved[batch, default: 0] += result.savedBytes
            }
        }
        var seen = Set<UUID>()
        var rows: [QueueRow] = []
        var previousGrouped = false
        for item in items {
            if let batch = item.job.request.batchID, (counts[batch] ?? 0) > 1, seen.insert(batch).inserted {
                rows.append(QueueRow(
                    id: "batch-\(batch.uuidString)",
                    kind: .header(count: counts[batch] ?? 0, saved: saved[batch] ?? 0)))
            }
            let grouped = item.job.request.batchID.map { (counts[$0] ?? 0) > 1 } ?? false
            let gapBefore = previousGrouped && !grouped
            rows.append(QueueRow(
                id: item.id.raw.uuidString,
                kind: .card(item, grouped: grouped, gapBefore: gapBefore)))
            previousGrouped = grouped
        }
        return rows
    }
}
