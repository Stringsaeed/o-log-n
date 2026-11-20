import AppKit
import SwiftUI
import OLogNKit

struct DropzoneView: View {
    @Environment(PanelCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Namespace private var glassNS
    @State private var cancelVisible = false

    private var flat: Bool { reduceTransparency || coordinator.forceReduceTransparency }
    private var calm: Bool { coordinator.reduceMotion }

    var body: some View {
        let size = DropzoneMetrics.pillSize(phase: coordinator.phase, proximity: coordinator.proximity)
        let rect = DropzoneMetrics.pillRect(size: size, anchor: coordinator.anchor)
        let hiddenY: CGFloat = calm ? (96 - rect.maxY) : (96 - rect.maxY - 24)
        let hiddenScale: CGFloat = calm ? 1 : 0.86
        ZStack(alignment: .topLeading) {
            Color.clear
            if coordinator.phase != .hidden, size.width > 0 {
                glassWrap
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(coordinator.dropPresented ? 1 : hiddenScale, anchor: .top)
                    .offset(
                        x: rect.minX,
                        y: coordinator.dropPresented ? (96 - rect.maxY) : hiddenY)
                    .opacity(coordinator.dropPresented ? 1 : 0)
                    .onHover { hovering in
                        coordinator.pillHovered = hovering
                        if coordinator.phase == .compressing { cancelVisible = hovering }
                    }
            }
        }
        .frame(width: DropzoneMetrics.panel.width, height: DropzoneMetrics.panel.height)
        .animation(summon, value: coordinator.dropPresented)
        .animation(aimSpring, value: coordinator.targeted)
        .animation(phaseSpring, value: coordinator.phase)
        .animation(aimSpring, value: size.width)
        .animation(aimSpring, value: size.height)
    }

    private var summon: Animation {
        LognMotion.spring(response: 0.28, damping: 0.82, reduce: calm)
    }

    private var aimSpring: Animation {
        LognMotion.spring(response: 0.22, damping: 0.86, reduce: calm)
    }

    private var phaseSpring: Animation {
        LognMotion.spring(response: 0.24, damping: 0.84, reduce: calm)
    }

    @ViewBuilder
    private var glassWrap: some View {
        if flat {
            pill
        } else {
            GlassEffectContainer(spacing: 12) {
                pill.glassEffectID("dropzone-pill", in: glassNS)
            }
        }
    }

    @ViewBuilder
    private var pill: some View {
        if coordinator.phase == .puck {
            pillChrome(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            pillChrome(Capsule())
        }
    }

    private func pillChrome<S: InsettableShape>(_ shape: S) -> some View {
        let stack = ZStack {
            content
            if coordinator.optionDown, coordinator.phase == .ready {
                Text("⌥")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LognColor.accent(scheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(LognColor.accentFill(scheme), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .offset(y: 4)
            }
        }
        return stack
            .adaptiveGlass(shape, role: .panel, interactive: coordinator.phase == .ready)
            .overlay {
                shape.strokeBorder(rimColor, lineWidth: contrast == .increased ? 1.5 : 1)
            }
            .shadow(
                color: coordinator.pointerInside ? LognColor.accent(scheme).opacity(0.32) : .black.opacity(0.24),
                radius: coordinator.pointerInside ? 10 : 6,
                y: 2)
    }

    private var rimColor: Color {
        if coordinator.pointerInside { return LognColor.accentBorder(scheme) }
        return scheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.55)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .hidden:
            Color.clear
        case .puck:
            Image(nsImage: StatusGlyph.image(side: 18))
                .renderingMode(.template)
                .opacity(0.75)
                .accessibilityLabel(Logn.displayName)
        case .ready:
            readyHalves
        case .compressing:
            compressing
        case .done, .optimal:
            result
        case .failed:
            message(systemImage: "exclamationmark.triangle.fill", tint: LognColor.coralText(scheme))
                .onTapGesture { coordinator.openTrayFromDone() }
        case .cancelled:
            message(systemImage: "xmark.circle", tint: .secondary)
        }
    }

    private var readyHalves: some View {
        HStack(spacing: 6) {
            half(.smart)
            half(.lossless)
        }
        .padding(6)
        .overlay {
            Rectangle()
                .fill(Color.primary.opacity(coordinator.targeted == nil ? 0.18 : 0.06))
                .frame(width: 1, height: 28)
        }
    }

    private func half(_ mode: CompressionMode) -> some View {
        let aimed = coordinator.targeted == mode && coordinator.pointerInside
        let dimmed = coordinator.pointerInside && coordinator.targeted != nil && coordinator.targeted != mode
        return VStack(spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: mode == .smart ? "sparkles" : "checkmark.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(titleInk(aimed: aimed, dimmed: dimmed))
                    .bounceUpByLayer(aimed, enabled: !calm)
                Text(mode.title)
                    .font(LognFont.dropzoneMode)
                    .foregroundStyle(titleInk(aimed: aimed, dimmed: dimmed))
            }
            Text(caption(for: mode))
                .font(.system(size: 11, weight: aimed ? .semibold : .medium))
                .foregroundStyle(captionInk(aimed: aimed, dimmed: dimmed))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if aimed {
                if flat {
                    Capsule().fill(LognColor.accentFill(scheme))
                } else {
                    Capsule()
                        .fill(LognColor.accentFill(scheme))
                        .glassEffect(
                            .regular.tint(LognColor.accent(scheme).opacity(0.28)).interactive(),
                            in: Capsule())
                        .matchedGeometryEffect(id: "aim-pill", in: glassNS)
                }
            }
        }
        .overlay {
            if aimed {
                Capsule().strokeBorder(LognColor.accentBorder(scheme), lineWidth: 1)
            }
        }
        .scaleEffect(!calm && aimed ? 1.03 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode == .smart
            ? "Smart — drop to compress smaller, visually identical"
            : "Lossless — drop to compress with exact quality")
        .accessibilityAddTraits(.isButton)
    }

    /// Aimed ink stays at least 4.5:1 on the cobalt aim fill. The dimmed half is
    /// not given a second opacity, which previously pushed it under the contrast floor.
    private var aimedInk: Color {
        scheme == .dark
            ? Color(red: 0xBF / 255, green: 0xDB / 255, blue: 0xFE / 255)
            : Color(red: 0x1E / 255, green: 0x40 / 255, blue: 0xAF / 255)
    }

    private func titleInk(aimed: Bool, dimmed: Bool) -> Color {
        if aimed { return aimedInk }
        return Color.primary.opacity(dimmed ? 0.72 : 0.90)
    }

    private func captionInk(aimed: Bool, dimmed: Bool) -> Color {
        if aimed { return aimedInk }
        return Color.primary.opacity(dimmed ? 0.62 : 0.72)
    }

    /// Both halves always have a second line so the titles share a baseline.
    /// Lossless says "Exact quality": the output matches the picture, not the file's bytes.
    private func caption(for mode: CompressionMode) -> String {
        guard coordinator.phase == .ready else { return " " }
        if coordinator.pointerInside, coordinator.targeted == mode {
            return mode == .smart ? "Drop to shrink" : "Drop exact"
        }
        return mode == .smart ? "Smallest" : "Exact quality"
    }

    private var compressing: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, coordinator.progress))
                    .stroke(LognColor.accent(scheme), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(coordinator.headline)
                    .font(LognFont.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(coordinator.subline)
                    .font(LognFont.badge)
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)
                    .ticker(value: coordinator.subline, enabled: !calm)
            }
            Spacer(minLength: 0)
            Button {
                coordinator.cancelDropBatch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .opacity(cancelVisible ? 1 : 0)
            .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 12)
    }

    private var result: some View {
        HStack(spacing: 8) {
            FileThumbnailView(url: coordinator.doneURLs.first, size: 36, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 1) {
                if coordinator.phase == .done {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(coordinator.headline)
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                            .ticker(value: coordinator.headline, enabled: !calm)
                    }
                    .foregroundStyle(LognColor.emeraldText(scheme))
                    .lineLimit(1)
                } else {
                    Text(coordinator.headline)
                        .font(LognFont.filename)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(coordinator.subline)
                    .font(LognFont.dropzoneSub)
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if coordinator.phase == .optimal {
                Image(systemName: "equal.circle")
                    .foregroundStyle(Color.primary.opacity(0.82))
            }
            Button {
                coordinator.openTrayFromDone()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Open Tray")
            .accessibilityLabel("Open Tray")
        }
        .padding(.horizontal, 10)
        .contentShape(Capsule())
        .onTapGesture { coordinator.activateDone() }
    }

    private func message(systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(coordinator.headline)
                    .font(LognFont.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !coordinator.subline.isEmpty {
                    Text(coordinator.subline)
                        .font(LognFont.dropzoneSub)
                        .foregroundStyle(Color.primary.opacity(0.78))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }
}


