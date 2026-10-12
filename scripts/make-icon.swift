#!/usr/bin/env swift
// Renders Dbee's app icon and packs it into an .icns file.
//
//   swift scripts/make-icon.swift <outdir> [--keep-iconset]
//
// Writes <outdir>/AppIcon.icns. With --keep-iconset the intermediate AppIcon.iconset (all PNG sizes)
// is kept next to it. The artwork follows the macOS 11+ icon grid: an 824 pt continuous-corner body
// centred on a 1024 pt canvas, with a soft drop shadow. Each size is drawn from vectors, not downscaled.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Geometry helpers (design space: 1024 x 1024, y pointing down)

let canvas: CGFloat = 1024
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyCornerRadius: CGFloat = 185.4

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0)
    )!
}

/// Adds an elliptical arc. Angles are in radians in the ellipse's own space; with y pointing down,
/// angle .pi / 2 is the front (lowest) point of the ellipse.
func addEllipseArc(_ path: CGMutablePath, center: CGPoint, rx: CGFloat, ry: CGFloat,
                   from start: CGFloat, to end: CGFloat, clockwise: Bool) {
    let transform = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: rx, y: ry)
    path.addArc(center: .zero, radius: 1, startAngle: start, endAngle: end, clockwise: clockwise, transform: transform)
}

/// Apple's continuous-corner ("squircle") rounded rectangle, taken from SwiftUI so it matches system shapes.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

// MARK: - Artwork

/// The database glyph: a cylinder of three stacked tiers separated by cut-through grooves.
struct Cylinder {
    var centerX: CGFloat = 472
    var top: CGFloat = 308
    var bottom: CGFloat = 686
    var rx: CGFloat = 222
    var ry: CGFloat = 64
    var tiers = 3
    var groove: CGFloat = 18

    /// Outline of the whole cylinder: side walls, front-bottom arc, and the back half of the lid.
    var silhouette: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: centerX - rx, y: top))
        p.addLine(to: CGPoint(x: centerX - rx, y: bottom))
        addEllipseArc(p, center: CGPoint(x: centerX, y: bottom), rx: rx, ry: ry, from: .pi, to: 0, clockwise: true)
        p.addLine(to: CGPoint(x: centerX + rx, y: top))
        addEllipseArc(p, center: CGPoint(x: centerX, y: top), rx: rx, ry: ry, from: 0, to: -.pi, clockwise: true)
        p.closeSubpath()
        return p
    }

    var lid: CGPath {
        CGPath(ellipseIn: CGRect(x: centerX - rx, y: top - ry, width: rx * 2, height: ry * 2), transform: nil)
    }

    /// y positions (at the ellipse centre) where each groove starts.
    var grooveLines: [CGFloat] {
        let tierHeight = (bottom - top + groove) / CGFloat(tiers)
        return (1..<tiers).map { top + CGFloat($0) * tierHeight - groove }
    }

    /// A band of constant height that follows the front arc of the cylinder at `y`.
    func grooveBand(at y: CGFloat, height: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let overshoot: CGFloat = 4
        p.move(to: CGPoint(x: centerX - rx - overshoot, y: y))
        addEllipseArc(p, center: CGPoint(x: centerX, y: y), rx: rx + overshoot, ry: ry, from: .pi, to: 0, clockwise: true)
        p.addLine(to: CGPoint(x: centerX + rx + overshoot, y: y + height))
        addEllipseArc(p, center: CGPoint(x: centerX, y: y + height), rx: rx + overshoot, ry: ry, from: 0, to: .pi, clockwise: false)
        p.closeSubpath()
        return p
    }

    /// The thin rim highlight just under each groove, where light catches the top edge of a tier.
    func rim(at y: CGFloat, width: CGFloat) -> CGPath {
        let p = CGMutablePath()
        addEllipseArc(p, center: CGPoint(x: centerX, y: y), rx: rx, ry: ry, from: .pi, to: 0, clockwise: true)
        return p.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 10)
    }
}

/// A shield with a keyhole, the privacy cue. Anchored by its centre.
struct Shield {
    var center = CGPoint(x: 688, y: 674)
    var width: CGFloat = 214
    var height: CGFloat = 248

    func outline(inset: CGFloat = 0) -> CGPath {
        let w = width + inset * 2, h = height + inset * 2
        let left = center.x - w / 2, right = center.x + w / 2
        let top = center.y - h / 2, bottom = center.y + h / 2
        let shoulder = top + h * 0.13
        let p = CGMutablePath()
        p.move(to: CGPoint(x: center.x, y: top))
        p.addCurve(to: CGPoint(x: right, y: shoulder),
                   control1: CGPoint(x: center.x + w * 0.20, y: top + h * 0.075),
                   control2: CGPoint(x: right - w * 0.12, y: shoulder))
        p.addLine(to: CGPoint(x: right, y: top + h * 0.46))
        p.addCurve(to: CGPoint(x: center.x, y: bottom),
                   control1: CGPoint(x: right, y: top + h * 0.76),
                   control2: CGPoint(x: center.x + w * 0.22, y: bottom - h * 0.06))
        p.addCurve(to: CGPoint(x: left, y: top + h * 0.46),
                   control1: CGPoint(x: center.x - w * 0.22, y: bottom - h * 0.06),
                   control2: CGPoint(x: left, y: top + h * 0.76))
        p.addLine(to: CGPoint(x: left, y: shoulder))
        p.addCurve(to: CGPoint(x: center.x, y: top),
                   control1: CGPoint(x: left + w * 0.12, y: shoulder),
                   control2: CGPoint(x: center.x - w * 0.20, y: top + h * 0.075))
        p.closeSubpath()
        return p
    }

    var keyhole: CGPath {
        let r = width * 0.105
        let c = CGPoint(x: center.x, y: center.y - height * 0.055)
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        let stemTop = c.y + r * 0.4
        let stemBottom = c.y + r * 2.9
        let topHalf = r * 0.42, bottomHalf = r * 0.62
        let stem = CGMutablePath()
        stem.move(to: CGPoint(x: c.x - topHalf, y: stemTop))
        stem.addLine(to: CGPoint(x: c.x + topHalf, y: stemTop))
        stem.addLine(to: CGPoint(x: c.x + bottomHalf, y: stemBottom - r * 0.25))
        stem.addQuadCurve(to: CGPoint(x: c.x + bottomHalf - r * 0.25, y: stemBottom),
                          control: CGPoint(x: c.x + bottomHalf, y: stemBottom))
        stem.addLine(to: CGPoint(x: c.x - bottomHalf + r * 0.25, y: stemBottom))
        stem.addQuadCurve(to: CGPoint(x: c.x - bottomHalf, y: stemBottom - r * 0.25),
                          control: CGPoint(x: c.x - bottomHalf, y: stemBottom))
        stem.closeSubpath()
        p.addPath(stem)
        return p
    }
}

/// Draws the icon into `ctx`, which must already map the 1024 design space (y down) onto the bitmap.
/// `pixelScale` converts design units to device pixels, for shadows (which ignore the CTM).
func drawIcon(in ctx: CGContext, pixelScale: CGFloat, simplified: Bool) {
    let body = squircle(bodyRect, radius: bodyCornerRadius)

    // Drop shadow under the body (offsets are in device space, where y points up).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * pixelScale), blur: 22 * pixelScale, color: rgb(0, 0, 0, 0.32))
    ctx.addPath(body)
    ctx.setFillColor(rgb(36, 64, 168))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: deep blue gradient with a soft light from the top.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(86, 146, 255)), (0.55, rgb(46, 98, 226)), (1, rgb(28, 58, 168))]),
        start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: []
    )
    ctx.drawRadialGradient(
        gradient([(0, rgb(255, 255, 255, 0.20)), (1, rgb(255, 255, 255, 0))]),
        startCenter: CGPoint(x: 512, y: 150), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 150), endRadius: 620, options: []
    )
    ctx.restoreGState()

    let cylinder = Cylinder()
    let shield = Shield()

    // Glyph shadow, drawn from the combined glyph silhouette so cut-outs don't double it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * pixelScale), blur: 30 * pixelScale, color: rgb(10, 24, 80, 0.38))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawCylinder(cylinder, in: ctx, simplified: simplified, cutout: simplified ? nil : shield)
    if !simplified { drawShield(shield, in: ctx) }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Hairline inner edge: brighter at the top, so the body reads on dark backgrounds too.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.addPath(body.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(255, 255, 255, 0.35)), (0.5, rgb(255, 255, 255, 0.06)), (1, rgb(255, 255, 255, 0.12))]),
        start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: []
    )
    ctx.restoreGState()
}

func drawCylinder(_ c: Cylinder, in ctx: CGContext, simplified: Bool, cutout: Shield?) {
    let grooveHeight = simplified ? c.groove * 1.8 : c.groove
    var cyl = c
    cyl.groove = grooveHeight

    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Side wall: cylindrical shading left to right.
    ctx.saveGState()
    ctx.addPath(cyl.silhouette)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([
            (0.00, rgb(196, 210, 236)),
            (0.22, rgb(250, 252, 255)),
            (0.45, rgb(240, 245, 253)),
            (0.80, rgb(212, 223, 243)),
            (1.00, rgb(178, 194, 228)),
        ]),
        start: CGPoint(x: cyl.centerX - cyl.rx, y: 0), end: CGPoint(x: cyl.centerX + cyl.rx, y: 0), options: []
    )
    // Slight darkening toward the base.
    ctx.drawLinearGradient(
        gradient([(0, rgb(30, 50, 120, 0)), (1, rgb(30, 50, 120, 0.12))]),
        start: CGPoint(x: 0, y: cyl.top), end: CGPoint(x: 0, y: cyl.bottom + cyl.ry), options: []
    )
    ctx.restoreGState()

    // Lid.
    ctx.saveGState()
    ctx.addPath(cyl.lid)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(255, 255, 255)), (1, rgb(226, 234, 248))]),
        start: CGPoint(x: 0, y: cyl.top - cyl.ry), end: CGPoint(x: 0, y: cyl.top + cyl.ry), options: []
    )
    ctx.restoreGState()
    if !simplified {
        // A faint edge around the lid so it separates from the wall.
        ctx.saveGState()
        ctx.addPath(cyl.lid.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 10))
        ctx.setFillColor(rgb(150, 170, 215, 0.55))
        ctx.fillPath()
        ctx.restoreGState()
    }

    if !simplified {
        // Soft shade along the bottom edge of each upper tier, so the tiers read as separate slabs.
        ctx.saveGState()
        ctx.addPath(cyl.silhouette)
        ctx.clip()
        let depth: CGFloat = 26
        for y in cyl.grooveLines {
            for step in stride(from: CGFloat(0), to: depth, by: 2) {
                ctx.addPath(cyl.rim(at: y - step, width: 2.5))
                ctx.setFillColor(rgb(40, 60, 130, 0.07 * (1 - step / depth)))
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }

    // Grooves are punched through, so the background shows between the tiers.
    ctx.saveGState()
    ctx.setBlendMode(.destinationOut)
    ctx.setFillColor(rgb(0, 0, 0))
    for y in cyl.grooveLines {
        ctx.addPath(cyl.grooveBand(at: y, height: grooveHeight))
    }
    ctx.fillPath()
    ctx.restoreGState()

    if !simplified {
        // Light catching the top edge of the lower tiers.
        ctx.saveGState()
        ctx.addPath(cyl.silhouette)
        ctx.clip()
        for y in cyl.grooveLines {
            ctx.addPath(cyl.rim(at: y + grooveHeight + 2, width: 4))
        }
        ctx.setFillColor(rgb(255, 255, 255, 0.9))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Clear a gap around the badge so it sits in front of the cylinder.
    if let cutout {
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        ctx.addPath(cutout.outline(inset: 18))
        ctx.setFillColor(rgb(0, 0, 0))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.endTransparencyLayer()
}

func drawShield(_ s: Shield, in ctx: CGContext) {
    let outline = s.outline()
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(255, 214, 92)), (1, rgb(245, 160, 28))]),
        start: CGPoint(x: s.center.x, y: s.center.y - s.height / 2),
        end: CGPoint(x: s.center.x, y: s.center.y + s.height / 2), options: []
    )
    // Inner bevel highlight along the top edge.
    ctx.addPath(outline.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(255, 246, 210, 0.9)), (0.5, rgb(255, 236, 170, 0)), (1, rgb(200, 110, 0, 0.35))]),
        start: CGPoint(x: s.center.x, y: s.center.y - s.height / 2),
        end: CGPoint(x: s.center.x, y: s.center.y + s.height / 2), options: []
    )
    ctx.restoreGState()

    // Engraved inner border.
    ctx.saveGState()
    ctx.addPath(s.outline(inset: -16).copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.setFillColor(rgb(255, 250, 230, 0.55))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(s.keyhole)
    ctx.setFillColor(rgb(120, 66, 0, 0.92))
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - Rendering

func renderPNG(pixels: Int, to url: URL, dpiScale: Int) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw IconError("could not create a \(pixels)px bitmap") }
    let scale = CGFloat(pixels) / canvas
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawIcon(in: ctx, pixelScale: scale, simplified: pixels <= 32)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError("could not encode \(url.lastPathComponent)") }
    let dpi = 72 * dpiScale
    CGImageDestinationAddImage(dest, image, [
        kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw IconError("could not write \(url.path)") }
}

struct IconError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let outArg = args.first(where: { !$0.hasPrefix("--") }) else {
        FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <outdir> [--keep-iconset]\n".utf8))
        exit(64)
    }
    let keepIconset = args.contains("--keep-iconset")
    let fm = FileManager.default
    let outDir = URL(fileURLWithPath: outArg, isDirectory: true)
    try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

    let iconset = keepIconset
        ? outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        : fm.temporaryDirectory.appendingPathComponent("dbee-\(UUID().uuidString).iconset", isDirectory: true)
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { if !keepIconset { try? fm.removeItem(at: iconset) } }

    for points in [16, 32, 128, 256, 512] {
        try renderPNG(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"), dpiScale: 1)
        try renderPNG(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"), dpiScale: 2)
    }

    let icns = outDir.appendingPathComponent("AppIcon.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw IconError("iconutil failed (\(iconutil.terminationStatus))") }
    print(icns.path)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
