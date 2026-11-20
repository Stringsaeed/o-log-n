import AppKit
import QuickLookThumbnailing
import SwiftUI
import OLogNKit

enum Logn {
    static let displayName = "Logn"
    static let selfDragType = NSPasteboard.PasteboardType("app.ologn.mac.self-drag")
    static let defaultsKey = "settings.v1"
}

enum LognFont {
    static let dropzoneMode = Font.system(size: 14, weight: .semibold)
    static let dropzoneSub = Font.system(size: 11, weight: .medium)
    static let control = Font.system(size: 12.5, weight: .medium)
    static let filename = Font.system(size: 13, weight: .semibold)
    static let meta = Font.system(size: 11.5, weight: .regular)
    static let metric = Font.system(size: 12, weight: .medium).monospacedDigit()
    static let badge = Font.system(size: 11.5, weight: .semibold).monospacedDigit()
    static let toast = Font.system(size: 12.5, weight: .medium)
}

enum LognMotion {
    static func spring(response: Double, damping: Double, reduce: Bool) -> Animation {
        reduce ? .linear(duration: 0.12) : .spring(response: response, dampingFraction: damping)
    }
}

enum LognColor {
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255)
            : Color(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255)
    }

    static func accentFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? accent(scheme).opacity(0.28) : accent(scheme).opacity(0.16)
    }

    static func accentBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x60 / 255, green: 0xA5 / 255, blue: 0xFA / 255).opacity(0.65)
            : accent(scheme).opacity(0.45)
    }

    static func segmentThumb(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.92)
    }

    static func emeraldText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255)
            : Color(red: 0x0A / 255, green: 0x7B / 255, blue: 0x3E / 255)
    }

    static func emeraldFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255).opacity(0.18)
            : Color(red: 16 / 255, green: 185 / 255, blue: 129 / 255).opacity(0.15)
    }

    static func cobaltText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x60 / 255, green: 0xA5 / 255, blue: 0xFA / 255)
            : Color(red: 0x1D / 255, green: 0x4E / 255, blue: 0xD8 / 255)
    }

    static func coralText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xFC / 255, green: 0xA5 / 255, blue: 0xA5 / 255)
            : Color(red: 0xB9 / 255, green: 0x1C / 255, blue: 0x1C / 255)
    }

    static func coralFill(_ scheme: ColorScheme) -> Color {
        coralText(scheme).opacity(0.16)
    }

    static func amberText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
            : Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)
    }

    enum CardChrome {
        case idle, hovered, selected
    }

    static func cardFill(_ scheme: ColorScheme, state: CardChrome) -> Color {
        switch (scheme, state) {
        case (.dark, .idle): Color.white.opacity(0.06)
        case (.dark, .hovered): Color.white.opacity(0.10)
        case (.dark, .selected): Color.white.opacity(0.11)
        case (_, .idle): Color.white.opacity(0.52)
        case (_, .hovered): Color.white.opacity(0.72)
        case (_, .selected): Color.white.opacity(0.80)
        }
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.06)
    }

    /// Flat pills need their own fill. `controlBackgroundColor` matches the window and disappears.
    static func flatOrGlassFill(_ scheme: ColorScheme, flat: Bool, hovered: Bool) -> Color {
        if flat {
            return scheme == .dark
                ? Color.white.opacity(hovered ? 0.14 : 0.09)
                : Color.black.opacity(hovered ? 0.09 : 0.055)
        }
        return Color.primary.opacity(scheme == .dark ? (hovered ? 0.13 : 0.08) : (hovered ? 0.09 : 0.05))
    }

    static func wellFill(_ scheme: ColorScheme, hovered: Bool) -> Color {
        let base: Double = scheme == .dark ? 0.24 : 0.045
        return Color.black.opacity(base + (hovered ? 0.03 : 0))
    }
}

enum ByteText {
    static func string(_ bytes: Int64) -> String {
        let magnitude = Double(abs(bytes))
        switch magnitude {
        case 999_500_000...:
            return String(format: "%.2f GB", magnitude / 1_000_000_000)
        case 999_500...:
            return String(format: "%.1f MB", magnitude / 1_000_000)
        case 1_000...:
            return String(format: "%.0f KB", magnitude / 1_000)
        default:
            return "\(Int(magnitude)) B"
        }
    }

    static func percent(_ fraction: Double) -> String {
        if fraction <= 0 { return "0%" }
        if fraction < 0.01 { return "<−1%" }
        if fraction >= 0.9995 { return ">−99.9%" }
        if fraction >= 0.995 {
            return String(format: "−%.1f%%", min(99.9, fraction * 100))
        }
        return "−\(Int((fraction * 100).rounded()))%"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        string(Int64(bytesPerSecond.rounded())) + "/s"
    }
}

extension CompressionMode {
    var flipped: CompressionMode { self == .smart ? .lossless : .smart }
    var title: String { self == .smart ? "Smart" : "Lossless" }
}

extension QualityPreset {
    var title: String {
        switch self {
        case .compact: "Compact"
        case .balanced: "Balanced"
        case .studio: "Studio"
        }
    }
}

extension ArchiveFormat {
    var title: String {
        switch self {
        case .xz: "Smallest (.tar.xz)"
        case .zip: "Opens everywhere (.zip)"
        }
    }
}

extension ImageConversion {
    var title: String {
        switch self {
        case .keep: "Keep Format"
        case .heic: "Images → HEIC"
        case .avif: "Images → AVIF"
        }
    }
}

extension FileKind {
    var label: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .pdf: "PDF"
        case .video: "Video"
        case .audio: "Audio"
        case .folder: "Folder"
        case .generic: "File"
        }
    }
}

extension DropzonePresence {
    var title: String {
        switch self {
        case .onDrag: "While dragging"
        case .always: "Always"
        case .off: "Off"
        }
    }
}

extension View {
    @ViewBuilder
    func ticker<V: Equatable>(value: V, enabled: Bool) -> some View {
        if enabled {
            self.contentTransition(.numericText()).animation(.snappy(duration: 0.20), value: value)
        } else {
            self
        }
    }

    @ViewBuilder
    func bounceEffect<V: Equatable>(_ value: V, enabled: Bool) -> some View {
        if enabled { self.symbolEffect(.bounce, value: value) } else { self }
    }

    @ViewBuilder
    func bounceUpByLayer<V: Equatable>(_ value: V, enabled: Bool) -> some View {
        if enabled { self.symbolEffect(.bounce.up.byLayer, value: value) } else { self }
    }

    @ViewBuilder
    func pulseEffect(active: Bool, enabled: Bool) -> some View {
        if enabled {
            self.symbolEffect(.pulse, options: .repeating, isActive: active)
        } else {
            self
        }
    }

    @ViewBuilder
    func rotateEffect<V: Equatable>(_ value: V, enabled: Bool) -> some View {
        if enabled { self.symbolEffect(.rotate, value: value) } else { self }
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct FileThumbnailView: View {
    let url: URL?
    let size: CGFloat
    var cornerRadius: CGFloat = 8
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(nsImage: fallback)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .task(id: url) {
            await load()
        }
    }

    private var fallback: NSImage {
        if let url, let cached = DemoThumbnails.image(for: url) { return cached }
        if let url {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        if let cached = DemoThumbnails.image(for: url) {
            image = cached
            return
        }
        image = await ThumbnailLoader.image(for: url, side: size)
    }
}

/// Thumbnails drawn for `--demo`. Keyed by the demo URL. Nothing is written to disk.
@MainActor
enum DemoThumbnails {
    private static var images: [String: NSImage] = [:]

    static func store(_ image: NSImage, for url: URL) {
        images[url.path] = image
    }

    static func image(for url: URL) -> NSImage? {
        images[url.path]
    }
}

@MainActor
enum ThumbnailLoader {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    static func image(for url: URL, side: CGFloat) async -> NSImage? {
        if let cached = DemoThumbnails.image(for: url) { return cached }
        let key = NSURL(string: "\(url.absoluteString)#\(Int(side))") ?? (url as NSURL)
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: 2,
            representationTypes: .thumbnail)
        let bytes: Data? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage.tiffRepresentation)
            }
        }
        guard let bytes, let rendered = NSImage(data: bytes) else { return nil }
        cache.setObject(rendered, forKey: key)
        return rendered
    }
}

enum StatusGlyph {
    /// Template caliper on a fixed canvas. Progress never changes the image size.
    /// Jaw geometry matches `renderGlyph` in `scripts/make-icon.swift`: tips at
    /// 0.24 / 0.76 and waists at 0.38 / 0.62, then scaled by 0.62 about the
    /// centre so a radius-8 ring stays at least 2 pt clear of the jaws.
    static func image(side: CGFloat = 18, progress: Double? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            draw(side: side, progress: progress)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(side: CGFloat, progress: Double?) {
        let unit = side / 18
        let scale: CGFloat = 0.62
        let center = side / 2
        func map(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let px = side * x
            let py = side * y
            return NSPoint(x: center + (px - center) * scale, y: center + (py - center) * scale)
        }
        func jaw(mirror: Bool) {
            let tipX: CGFloat = mirror ? 0.76 : 0.24
            let waistX: CGFloat = mirror ? 0.62 : 0.38
            let path = NSBezierPath()
            path.move(to: map(tipX, 0.16))
            path.curve(
                to: map(tipX, 0.84),
                controlPoint1: map(waistX, 0.34),
                controlPoint2: map(waistX, 0.66))
            path.lineWidth = 1.6 * unit
            path.lineCapStyle = .round
            path.stroke()
        }
        jaw(mirror: false)
        jaw(mirror: true)
        let dot = 2.2 * unit
        let origin = (side - dot) / 2
        NSBezierPath(ovalIn: NSRect(x: origin, y: origin, width: dot, height: dot)).fill()
        guard let progress else { return }
        let path = NSBezierPath()
        path.appendArc(
            withCenter: NSPoint(x: center, y: center),
            radius: 8 * unit,
            startAngle: 90,
            endAngle: 90 - 360 * max(0.04, min(1, progress)),
            clockwise: true)
        path.lineWidth = 1.25 * unit
        path.lineCapStyle = .round
        path.stroke()
    }
}

enum ScreenLocator {
    @MainActor static func underMouse() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.screens[0]
    }

    @MainActor static func primary() -> NSScreen {
        NSScreen.screens[0]
    }
}
