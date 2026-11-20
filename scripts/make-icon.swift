#!/usr/bin/env swift
// Draws Logn's icon with Core Graphics and builds Support/AppIcon.icns.
// Run from the repository root: swift scripts/make-icon.swift [png-output-dir]
//
// The menu-bar glyph geometry matches StatusGlyph in Sources/OLogNApp/Views/Tokens.swift.
// Tips sit at 0.24 / 0.76 and waists at 0.38 / 0.62, then the jaws scale by 0.62
// about the centre so a radius-8 ring keeps at least 2 pt of air. The canvas
// size does not change when progress is drawn.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let icnsURL = cwd.appendingPathComponent("Support/AppIcon.icns")
let pngDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : nil

let iconsetNames: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "LognIcon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "LognIcon", code: 2)
    }
}

func context(width: Int, height: Int, flipped: Bool) -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("no context")
    }
    if flipped {
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
    }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func squircle(in rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func point(_ side: CGFloat, _ x: CGFloat, _ y: CGFloat, snap: Bool) -> CGPoint {
    var px = side * x
    var py = side * y
    if snap {
        px = px.rounded()
        py = py.rounded()
    }
    return CGPoint(x: px, y: py)
}

/// One solid inward jaw. Fractions are of the full canvas. y grows downward.
/// Built as a closed ribbon so the fill is one solid shape. `copy(strokingWithWidth:)`
/// winds a hole through the middle and reads as a hollow track.
func jawPath(side: CGFloat, mirror: Bool, thickness: CGFloat, snap: Bool) -> CGPath {
    let tipX: CGFloat = mirror ? 0.70 : 0.30
    let waistX: CGFloat = mirror ? 0.56 : 0.44
    let p0 = CGPoint(x: tipX, y: 0.28)
    let p1 = CGPoint(x: waistX, y: 0.40)
    let p2 = CGPoint(x: waistX, y: 0.60)
    let p3 = CGPoint(x: tipX, y: 0.72)
    let radius = thickness / 2
    let steps = snap ? 16 : 40
    var centres: [CGPoint] = []
    var normals: [CGPoint] = []
    var tangents: [CGPoint] = []
    centres.reserveCapacity(steps + 1)
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let point = bezierPoint(t, p0, p1, p2, p3)
        let velocity = bezierVelocity(t, p0, p1, p2, p3)
        let length = max(0.0001, hypot(velocity.x, velocity.y))
        centres.append(point)
        tangents.append(CGPoint(x: velocity.x / length, y: velocity.y / length))
        normals.append(CGPoint(x: -velocity.y / length, y: velocity.x / length))
    }
    func place(_ point: CGPoint, _ offset: CGPoint) -> CGPoint {
        var x = side * (point.x + offset.x)
        var y = side * (point.y + offset.y)
        if snap {
            x = x.rounded()
            y = y.rounded()
        }
        return CGPoint(x: x, y: y)
    }
    let path = CGMutablePath()
    func cap(from: Int, tangentSign: CGFloat, reverse: Bool) {
        let centre = centres[from]
        let normal = normals[from]
        let tangent = tangents[from]
        let capSteps = snap ? 5 : 8
        let indices: [Int] = reverse
            ? Array(stride(from: capSteps - 1, through: 0, by: -1))
            : Array(1...capSteps)
        for step in indices {
            let theta = CGFloat.pi * CGFloat(step) / CGFloat(capSteps)
            let offset = CGPoint(
                x: (normal.x * cos(theta) + tangent.x * tangentSign * sin(theta)) * radius,
                y: (normal.y * cos(theta) + tangent.y * tangentSign * sin(theta)) * radius)
            path.addLine(to: place(centre, offset))
        }
    }
    path.move(to: place(centres[0], CGPoint(x: normals[0].x * radius, y: normals[0].y * radius)))
    for index in 1...steps {
        path.addLine(to: place(centres[index], CGPoint(x: normals[index].x * radius, y: normals[index].y * radius)))
    }
    cap(from: steps, tangentSign: 1, reverse: false)
    for index in stride(from: steps - 1, through: 0, by: -1) {
        path.addLine(to: place(centres[index], CGPoint(x: -normals[index].x * radius, y: -normals[index].y * radius)))
    }
    cap(from: 0, tangentSign: -1, reverse: true)
    path.closeSubpath()
    return path
}

func bezierPoint(_ t: CGFloat, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint {
    let u = 1 - t
    return CGPoint(
        x: u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
        y: u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y)
}

func bezierVelocity(_ t: CGFloat, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint {
    let u = 1 - t
    return CGPoint(
        x: 3 * u * u * (b.x - a.x) + 6 * u * t * (c.x - b.x) + 3 * t * t * (d.x - c.x),
        y: 3 * u * u * (b.y - a.y) + 6 * u * t * (c.y - b.y) + 3 * t * t * (d.y - c.y))
}

/// Short mark along the inner top edge of one jaw. Fractions are of the canvas.
func innerTopHighlight(side: CGFloat, mirror: Bool, thickness: CGFloat) -> CGPath {
    let tipX: CGFloat = mirror ? 0.70 : 0.30
    let waistX: CGFloat = mirror ? 0.56 : 0.44
    let p0 = CGPoint(x: tipX, y: 0.28)
    let p1 = CGPoint(x: waistX, y: 0.40)
    let p2 = CGPoint(x: waistX, y: 0.60)
    let p3 = CGPoint(x: tipX, y: 0.72)
    let centre = CGPoint(x: 0.50, y: 0.50)
    let inset = thickness * 0.36
    let path = CGMutablePath()
    let steps = 12
    for step in 0...steps {
        let t = 0.04 + 0.34 * CGFloat(step) / CGFloat(steps)
        let point = bezierPoint(t, p0, p1, p2, p3)
        let velocity = bezierVelocity(t, p0, p1, p2, p3)
        let length = max(0.0001, hypot(velocity.x, velocity.y))
        var normal = CGPoint(x: -velocity.y / length, y: velocity.x / length)
        let toward = CGPoint(x: centre.x - point.x, y: centre.y - point.y)
        if normal.x * toward.x + normal.y * toward.y < 0 {
            normal.x = -normal.x
            normal.y = -normal.y
        }
        let placed = CGPoint(x: side * (point.x + normal.x * inset), y: side * (point.y + normal.y * inset))
        if step == 0 {
            path.move(to: placed)
        } else {
            path.addLine(to: placed)
        }
    }
    return path
}

func fillJaw(_ ctx: CGContext, path: CGPath, side: CGFloat, mirror: Bool, thickness: CGFloat, highlight: Bool) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [rgba(1, 1, 1, 0.92), rgba(0.82, 0.84, 0.86, 0.92)] as CFArray
    let stops: [CGFloat] = [0, 1]
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: stops) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: side * 0.5, y: side * 0.18),
            end: CGPoint(x: side * 0.5, y: side * 0.82),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    if highlight {
        ctx.setStrokeColor(rgba(1, 1, 1, 0.60))
        ctx.setLineWidth(1.5 * side / 1024)
        ctx.setLineCap(.round)
        ctx.addPath(innerTopHighlight(side: side, mirror: mirror, thickness: thickness))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func diamondPath(side: CGFloat) -> CGPath {
    let cx = side * 0.50
    let cy = side * 0.50
    let rx = side * 0.07
    let ry = side * 0.09
    let gem = CGMutablePath()
    gem.move(to: CGPoint(x: cx, y: cy - ry))
    gem.addLine(to: CGPoint(x: cx + rx, y: cy))
    gem.addLine(to: CGPoint(x: cx, y: cy + ry))
    gem.addLine(to: CGPoint(x: cx - rx, y: cy))
    gem.closeSubpath()
    return gem
}

func renderIcon(pixels: Int) -> CGImage {
    let ctx = context(width: pixels, height: pixels, flipped: true)
    let side = CGFloat(pixels)
    let small = pixels <= 32
    let scale = side / 1024
    let inset = 100 * scale
    let body = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = 185 * scale
    let shape = squircle(in: body, radius: radius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12 * scale), blur: 28 * scale, color: rgba(0, 0, 0, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(rgba(0.12, 0.23, 0.54, 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = [rgba(0x3B / 255, 0x82 / 255, 0xF6 / 255), rgba(0x1E / 255, 0x3A / 255, 0x8A / 255)] as CFArray
    let stops: [CGFloat] = [0, 1]
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: background, locations: stops) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.midX, y: body.minY),
            end: CGPoint(x: body.midX, y: body.maxY),
            options: [])
    }
    if !small {
        let colors = [rgba(1, 1, 1, 0.18), rgba(1, 1, 1, 0)] as CFArray
        let radialStops: [CGFloat] = [0, 1]
        if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: radialStops) {
            ctx.drawRadialGradient(
                glow,
                startCenter: CGPoint(x: body.midX, y: body.minY + body.height * 0.08),
                startRadius: 0,
                endCenter: CGPoint(x: body.midX, y: body.minY + body.height * 0.08),
                endRadius: body.width * 0.60,
                options: [])
        }
    }
    ctx.restoreGState()

    let thickness: CGFloat = small ? 0.10 : 0.075
    fillJaw(ctx, path: jawPath(side: side, mirror: false, thickness: thickness, snap: small), side: side, mirror: false, thickness: thickness, highlight: !small)
    fillJaw(ctx, path: jawPath(side: side, mirror: true, thickness: thickness, snap: small), side: side, mirror: true, thickness: thickness, highlight: !small)

    let gem = diamondPath(side: side)
    ctx.saveGState()
    if !small {
        ctx.setShadow(offset: .zero, blur: 18 * scale, color: rgba(0x10 / 255, 0xB9 / 255, 0x81 / 255, 0.35))
    }
    ctx.addPath(gem)
    ctx.clip()
    let gemColors = [rgba(0x34 / 255, 0xD3 / 255, 0x99 / 255), rgba(0x10 / 255, 0xB9 / 255, 0x81 / 255)] as CFArray
    if let gemGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: gemColors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gemGradient,
            start: CGPoint(x: side * 0.5, y: side * 0.42),
            end: CGPoint(x: side * 0.5, y: side * 0.58),
            options: [])
    }
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("no image") }
    return image
}

/// y-up, matching `StatusGlyph.draw`. Canvas size is `pixels` in both states.
func renderGlyph(pixels: Int, progress: CGFloat?) -> CGImage {
    let ctx = context(width: pixels, height: pixels, flipped: false)
    let side = CGFloat(pixels)
    let unit = side / 18
    let scale: CGFloat = 0.62
    let center = side / 2
    func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let px = side * x
        let py = side * y
        return CGPoint(x: center + (px - center) * scale, y: center + (py - center) * scale)
    }
    ctx.setStrokeColor(rgba(0, 0, 0, 1))
    ctx.setFillColor(rgba(0, 0, 0, 1))
    ctx.setLineCap(.round)
    func jaw(mirror: Bool) {
        let tipX: CGFloat = mirror ? 0.76 : 0.24
        let waistX: CGFloat = mirror ? 0.62 : 0.38
        let path = CGMutablePath()
        path.move(to: map(tipX, 0.16))
        path.addCurve(
            to: map(tipX, 0.84),
            control1: map(waistX, 0.34),
            control2: map(waistX, 0.66))
        ctx.setLineWidth(1.6 * unit)
        ctx.addPath(path)
        ctx.strokePath()
    }
    jaw(mirror: false)
    jaw(mirror: true)
    let dot = 2.2 * unit
    ctx.fillEllipse(in: CGRect(x: (side - dot) / 2, y: (side - dot) / 2, width: dot, height: dot))
    if let progress {
        ctx.setLineWidth(1.25 * unit)
        ctx.addArc(
            center: CGPoint(x: center, y: center),
            radius: 8 * unit,
            startAngle: .pi / 2,
            endAngle: .pi / 2 - .pi * 2 * max(0.04, progress),
            clockwise: true)
        ctx.strokePath()
    }
    guard let image = ctx.makeImage() else { fatalError("no glyph") }
    return image
}

func renderGrid(icon: CGImage) -> CGImage {
    let cell = 256
    let gap = 40
    let width = gap + (cell + gap) * 3
    let height = cell + gap * 2
    let ctx = context(width: width, height: height, flipped: false)
    ctx.setFillColor(rgba(0.91, 0.91, 0.93, 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let finder = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    let safari = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
    finder.size = NSSize(width: cell, height: cell)
    safari.size = NSSize(width: cell, height: cell)
    let logn = NSImage(cgImage: icon, size: NSSize(width: cell, height: cell))
    let images = [finder, logn, safari]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (index, image) in images.enumerated() {
        let x = CGFloat(gap + index * (cell + gap))
        image.draw(in: NSRect(x: x, y: CGFloat(gap), width: CGFloat(cell), height: CGFloat(cell)))
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let image = ctx.makeImage() else { fatalError("no grid") }
    return image
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Logn.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var rendered1024: CGImage?
for (name, pixels) in iconsetNames {
    let image = renderIcon(pixels: pixels)
    if pixels == 1024 { rendered1024 = image }
    try writePNG(image, to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", icnsURL.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}

if let pngDir, let rendered1024 {
    try FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)
    try writePNG(rendered1024, to: pngDir.appendingPathComponent("icon-1024.png"))
    try writePNG(renderGrid(icon: rendered1024), to: pngDir.appendingPathComponent("icon-grid.png"))
    try writePNG(renderGlyph(pixels: 36, progress: nil), to: pngDir.appendingPathComponent("menu-glyph.png"))
    try writePNG(renderGlyph(pixels: 36, progress: 0.40), to: pngDir.appendingPathComponent("menu-glyph-progress.png"))
}

fputs("wrote \(icnsURL.path)\n", stderr)
