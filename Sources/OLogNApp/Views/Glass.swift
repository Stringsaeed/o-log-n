import SwiftUI

enum GlassRole {
    case panel
    case pill
    case toast
}

struct AdaptiveGlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(PanelCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    let shape: S
    var role: GlassRole = .panel
    var interactive: Bool = false
    var hovered: Bool = false

    private var flat: Bool { reduceTransparency || coordinator.forceReduceTransparency }

    func body(content: Content) -> some View {
        let strong = contrast == .increased
        switch role {
        case .pill:
            content.background { pillChrome(strong: strong) }
        case .panel, .toast:
            if flat {
                content
                    .background(Color(nsColor: .windowBackgroundColor), in: shape)
                    .overlay {
                        shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: strong ? 1.5 : 1)
                    }
            } else {
                content
                    .background { shape.fill(stabilizer) }
                    .glassEffect(glass, in: shape)
                    .overlay {
                        shape.strokeBorder(rim, lineWidth: strong ? 1.5 : 1)
                    }
            }
        }
    }

    private var glass: Glass {
        interactive ? .regular.interactive() : .regular
    }

    private var stabilizer: Color {
        scheme == .dark
            ? Color(red: 0x14 / 255, green: 0x17 / 255, blue: 0x1C / 255).opacity(role == .toast ? 0.72 : 0.54)
            : Color.white.opacity(role == .toast ? 0.78 : 0.62)
    }

    private var rim: Color {
        if contrast == .increased { return Color.primary.opacity(0.55) }
        return scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.48)
    }

    private func pillChrome(strong: Bool) -> some View {
        let fill = LognColor.flatOrGlassFill(scheme, flat: flat, hovered: hovered)
        let stroke = strong
            ? Color.primary.opacity(0.55)
            : (flat ? Color(nsColor: .separatorColor) : Color.primary.opacity(scheme == .dark ? 0.14 : 0.10))
        let width: CGFloat = strong ? 1.5 : (flat ? 1 : 0.5)
        return Capsule()
            .fill(fill)
            .overlay {
                Capsule().strokeBorder(stroke, lineWidth: width)
            }
    }
}

extension View {
    func adaptiveGlass<S: InsettableShape>(
        _ shape: S,
        role: GlassRole = .panel,
        interactive: Bool = false,
        hovered: Bool = false
    ) -> some View {
        modifier(AdaptiveGlassSurface(shape: shape, role: role, interactive: interactive, hovered: hovered))
    }
}

/// Pushes the in-app Reduce Motion / Reduce Transparency overrides into SwiftUI.
struct AccessibilityOverride: ViewModifier {
    @Environment(PanelCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceTransparency) private var systemTransparency
    @Environment(\.accessibilityReduceMotion) private var systemMotion

    func body(content: Content) -> some View {
        content
            .environment(\._accessibilityReduceTransparency, coordinator.forceReduceTransparency || systemTransparency)
            .environment(\._accessibilityReduceMotion, coordinator.forceReduceMotion || systemMotion)
    }
}
