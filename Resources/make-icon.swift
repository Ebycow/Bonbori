// SPDX-License-Identifier: GPL-2.0-or-later
// Draws the Bonbori app icon and writes AppIcon.icns.
// Usage: swift Resources/make-icon.swift [output.icns] [preview.png]
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Drawn on a 1024pt canvas with y pointing down; `scale` maps it to pixels.
func draw(_ ctx: CGContext, scale: CGFloat) {
    let px = 1024 * scale
    ctx.translateBy(x: 0, y: px)
    ctx.scaleBy(x: scale, y: -scale)

    // Background plate (macOS icon grid: 824pt body inside 1024pt canvas).
    let plate = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: rgb(0x000000, 0.30))
    ctx.addPath(plate)
    ctx.setFillColor(rgb(0xF2F2F4))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF)), (1, rgb(0xDCDCE0))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // Feet.
    ctx.setFillColor(rgb(0x18181B))
    ctx.addPath(rounded(CGRect(x: 290, y: 690, width: 76, height: 86), 20))
    ctx.addPath(rounded(CGRect(x: 658, y: 690, width: 76, height: 86), 20))
    ctx.fillPath()

    // Cabinet.
    let body = CGRect(x: 170, y: 248, width: 684, height: 476)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 30 * scale, color: rgb(0x000000, 0.35))
    ctx.addPath(rounded(body, 100))
    ctx.setFillColor(rgb(0x1E1E21))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(rounded(body, 100))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x3C3C41)), (0.5, rgb(0x232326)), (1, rgb(0x111113))]),
                           start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])
    ctx.restoreGState()
    ctx.addPath(rounded(body.insetBy(dx: 3, dy: 3), 97))
    ctx.setLineWidth(6)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
    ctx.strokePath()

    // Screen.
    let screen = body.insetBy(dx: 48, dy: 48)
    let screenPath = rounded(screen, 58)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFAFAFA)), (1, rgb(0xE4E4E7))]),
                           start: CGPoint(x: 512, y: screen.minY), end: CGPoint(x: 512, y: screen.maxY), options: [])

    // Glass reflection.
    ctx.move(to: CGPoint(x: screen.minX, y: screen.minY))
    ctx.addLine(to: CGPoint(x: screen.minX + 330, y: screen.minY))
    ctx.addLine(to: CGPoint(x: screen.minX + 130, y: screen.maxY))
    ctx.addLine(to: CGPoint(x: screen.minX, y: screen.maxY))
    ctx.closePath()
    ctx.setFillColor(rgb(0xFFFFFF, 0.55))
    ctx.fillPath()

    // "Bon" centred on the screen by its glyph outlines.
    let font = NSFont.systemFont(ofSize: 236, weight: .heavy)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Bon", attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: rgb(0x111113))!, .kern: -6,
    ]))
    let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.saveGState()
    ctx.translateBy(x: screen.midX - glyphs.midX, y: screen.midY + glyphs.midY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    ctx.restoreGState()
    // Inner bezel shadow.
    ctx.addPath(screenPath)
    ctx.setLineWidth(8)
    ctx.setStrokeColor(rgb(0x000000, 0.45))
    ctx.strokePath()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx, scale: CGFloat(px) / 1024)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
let here = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
let icns = args.count > 1 ? URL(fileURLWithPath: args[1]) : here.appendingPathComponent("AppIcon.icns")
let preview = args.count > 2 ? URL(fileURLWithPath: args[2]) : here.appendingPathComponent("AppIcon.png")

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Bonbori-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    writePNG(render(pt), iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    writePNG(render(pt * 2), iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
writePNG(render(1024), preview)

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard p.terminationStatus == 0 else { exit(1) }
print("wrote \(icns.path)")
