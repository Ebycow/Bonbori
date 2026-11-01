// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import CoreText
import MediaAccessibility

/// Typeface of the captions.
enum CaptionTypeface: Int, CaseIterable {
    case roundedGothic, gothic, mincho

    var title: String {
        switch self {
        case .roundedGothic: return "丸ゴシック"
        case .gothic: return "角ゴシック"
        case .mincho: return "明朝"
        }
    }

    fileprivate func name(bold: Bool) -> String {
        switch self {
        // Hiragino's ProN fonts have the JIS X 0213:2004 glyphs that the DRCS table counts on.
        case .roundedGothic: return "HiraMaruProN-W4"
        case .gothic: return bold ? "HiraginoSans-W6" : "HiraginoSans-W4"
        case .mincho: return bold ? "HiraMinProN-W6" : "HiraMinProN-W3"
        }
    }
}

/// What the viewer chose in System Settings › Accessibility › Captions. Each value is set only if
/// it should win over what the broadcast asks for.
struct CaptionAppearance {
    var foreground: CGColor?
    var background: CGColor?
    var fontDescriptor: CTFontDescriptor?
    var edge: MACaptionAppearanceTextEdgeStyle?

    static var current: CaptionAppearance {
        var a = CaptionAppearance()
        var behavior = MACaptionAppearanceBehavior.useContentIfAvailable
        let foreground = MACaptionAppearanceCopyForegroundColor(.user, &behavior).takeRetainedValue()
        var opacityBehavior = MACaptionAppearanceBehavior.useContentIfAvailable
        let foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(.user, &opacityBehavior)
        if behavior == .useValue || opacityBehavior == .useValue {
            a.foreground = foreground.copy(alpha: opacityBehavior == .useValue ? foregroundOpacity : foreground.alpha)
        }
        behavior = .useContentIfAvailable
        let background = MACaptionAppearanceCopyBackgroundColor(.user, &behavior).takeRetainedValue()
        opacityBehavior = .useContentIfAvailable
        let backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(.user, &opacityBehavior)
        if behavior == .useValue || opacityBehavior == .useValue {
            a.background = background.copy(alpha: opacityBehavior == .useValue ? backgroundOpacity : background.alpha)
        }
        behavior = .useContentIfAvailable
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(.user, &behavior, .default).takeRetainedValue()
        if behavior == .useValue { a.fontDescriptor = descriptor }
        behavior = .useContentIfAvailable
        let edge = MACaptionAppearanceGetTextEdgeStyle(.user, &behavior)
        if behavior == .useValue { a.edge = edge }
        return a
    }
}

/// What goes behind the text.
enum CaptionBackdrop: Int, CaseIterable {
    case broadcast, gray, none

    var title: String {
        switch self {
        case .broadcast: return "放送のとおり"
        case .gray: return "薄いグレー"
        case .none: return "なし"
        }
    }
}

struct CaptionRenderOptions {
    var typeface = CaptionTypeface.roundedGothic
    var backdrop = CaptionBackdrop.broadcast
    /// 振り仮名 (small characters) are left out.
    var hidesRuby = false
    var appearance = CaptionAppearance()
}

/// What of a row goes into one layer: all of it, or the part that flashes in one phase.
struct RenderedRow {
    let image: CGImage
    let flash: CaptionFlash
    /// On the caption plane; y runs downwards.
    let rect: CGRect
}

/// Draws rows of captions with Core Text. Every character keeps to the cell the broadcast gave it,
/// so that a row lines up with the ones around it whatever the font does.
enum CaptionRenderer {
    /// Room around a row for outlines that stick out of its cells, on the caption plane.
    private static let margin: CGFloat = 4

    static func width(of row: CaptionRow) -> CGFloat {
        row.runs.reduce(0) { $0 + CGFloat($1.cells.count) * $1.style.section.width }
    }

    static func height(of row: CaptionRow) -> CGFloat {
        row.runs.lazy.filter { !$0.cells.isEmpty }.map(\.style.section.height).max() ?? 0
    }

    /// `scaleX` and `scaleY` are device pixels per unit of the caption plane.
    static func render(_ row: CaptionRow, options: CaptionRenderOptions, scaleX: CGFloat, scaleY: CGFloat) -> [RenderedRow] {
        let width = width(of: row), height = height(of: row)
        guard width > 0, height > 0, scaleX > 0, scaleY > 0 else { return [] }
        let bounds = CGRect(x: CGFloat(row.x), y: CGFloat(row.y + 1) - height, width: width, height: height)
            .insetBy(dx: -margin, dy: -margin)
        let flashes = Set(row.runs.filter { !$0.cells.isEmpty }.map(\.style.flash))
        return flashes.compactMap { flash in
            guard let image = draw(row, flash: flash, bounds: bounds, options: options, scaleX: scaleX, scaleY: scaleY) else { return nil }
            return RenderedRow(image: image, flash: flash, rect: bounds)
        }
    }

    private static func draw(_ row: CaptionRow, flash: CaptionFlash, bounds: CGRect, options: CaptionRenderOptions,
                             scaleX: CGFloat, scaleY: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int((bounds.width * scaleX).rounded(.up)), height: Int((bounds.height * scaleY).rounded(.up)),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // plane coordinates, y up, with the row's bottom at the baseline of the drawing
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.translateBy(x: -bounds.minX, y: bounds.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.interpolationQuality = .high
        var x = CGFloat(row.x)
        var i = 0
        while i < row.runs.count {
            // runs that look the same read as one: an enclosure goes around all of them
            var j = i + 1
            while j < row.runs.count, row.runs[j].style == row.runs[i].style { j += 1 }
            let style = row.runs[i].style
            let cells = row.runs[i..<j].flatMap(\.cells)
            let section = style.section
            let rect = CGRect(x: x, y: CGFloat(row.y + 1) - section.height, width: CGFloat(cells.count) * section.width, height: section.height)
            x = rect.maxX
            i = j
            guard style.flash == flash, !(options.hidesRuby && style.size == .small) else { continue }
            let painter = Painter(ctx: ctx, style: style, options: options)
            painter.paintBackground(rect)
            for (n, cell) in cells.enumerated() {
                painter.paint(cell, in: CGRect(x: rect.minX + CGFloat(n) * section.width, y: rect.minY, width: section.width, height: section.height))
            }
            painter.paintLines(rect)
        }
        return ctx.makeImage()
    }
}

/// Draws one run.
private struct Painter {
    let ctx: CGContext
    let style: CaptionStyle
    let options: CaptionRenderOptions

    private var glyph: CGSize { style.glyph }

    private var foreground: CGColor {
        options.appearance.foreground ?? cgColor(style.foreground)
    }

    private var background: CGColor? {
        switch options.backdrop {
        case .gray: return CGColor(gray: 0.3, alpha: 0.6)
        case .none: return nil
        case .broadcast: break
        }
        if let color = options.appearance.background { return color }
        return style.background.isTransparent ? nil : cgColor(style.background)
    }

    /// The outline of the text: its ORN color, or the color of the background, or black.
    private var edgeColor: CGColor {
        if let outline = style.outline { return cgColor(outline, opaque: true) }
        guard options.backdrop == .broadcast else { return .black }
        return (options.appearance.background ?? cgColor(style.background, opaque: true)).copy(alpha: 1) ?? .black
    }

    private var edgeWidth: CGFloat {
        if let edge = options.appearance.edge {
            switch edge {
            case .none: return 0
            case .uniform: return glyph.height / 12
            default: break
            }
        }
        return (style.outline != nil ? 2 : 1) * CGFloat(style.charHeight + Int(glyph.height)) / 72
    }

    private var hasShadow: Bool {
        options.appearance.edge == .dropShadow
    }

    private func cgColor(_ c: CaptionColor, opaque: Bool = false) -> CGColor {
        CGColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255,
                alpha: opaque ? 1 : CGFloat(c.alpha) / 255)
    }

    func paintBackground(_ rect: CGRect) {
        guard let background else { return }
        // Not smoothed, or the edges between neighboring runs would show.
        ctx.setShouldAntialias(false)
        ctx.setFillColor(background)
        ctx.fill(rect)
        ctx.setShouldAntialias(true)
    }

    func paintLines(_ rect: CGRect) {
        let e = style.enclosure
        let width: CGFloat = 2
        ctx.setFillColor(foreground)
        if e.left { ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)) }
        if e.right { ctx.fill(CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height)) }
        if e.top { ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: width)) }
        if e.bottom || style.underline { ctx.fill(CGRect(x: rect.minX, y: rect.maxY - width, width: rect.width, height: width)) }
    }

    func paint(_ cell: CaptionCell, in rect: CGRect) {
        switch cell {
        case .space:
            break
        case .block:
            ctx.setFillColor(foreground)
            ctx.fill(rect)
        case .text(let text):
            paint(text, in: rect)
        case .glyph(let glyph):
            paint(glyph, in: rect)
        }
    }

    private func font(size: CGFloat) -> CTFont {
        var matrix = CGAffineTransform(a: 1, b: 0, c: style.italic ? 0.25 : 0, d: 1, tx: 0, ty: 0)
        if let descriptor = options.appearance.fontDescriptor {
            return CTFontCreateWithFontDescriptor(descriptor, size, &matrix)
        }
        return CTFontCreateWithName(options.typeface.name(bold: style.bold) as CFString, size, &matrix)
    }

    private func paint(_ text: String, in rect: CGRect) {
        let half = glyph.width < glyph.height ? halfWidthForm(text) : nil
        let size = glyph.height
        let font = font(size: size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: half ?? text, attributes: attributes))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard advance > 0 else { return }
        // Characters are full width on the plane unless the size says otherwise. A character that
        // has a half width form only needs squeezing if it is still too wide, and so does a
        // replacement of several characters.
        let scale = half != nil ? min(1, glyph.width / advance) : min(glyph.width / size, glyph.width / advance)
        // the em box goes in the middle of the section
        let baseline = rect.midY + (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - advance * scale / 2, y: baseline)
        ctx.scaleBy(x: scale, y: 1)
        if hasShadow {
            ctx.setShadow(offset: CGSize(width: size / 18, height: size / 18), blur: size / 12, color: CGColor(gray: 0, alpha: 0.8))
        }
        let edge = edgeWidth
        if edge > 0 {
            ctx.setLineJoin(.round)
            ctx.setLineWidth(edge * 2)
            ctx.setStrokeColor(edgeColor)
            ctx.setTextDrawingMode(.stroke)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
        }
        if style.bold, options.typeface == .roundedGothic, options.appearance.fontDescriptor == nil {
            // The rounded face comes in one weight.
            ctx.setLineWidth(size / 28)
            ctx.setStrokeColor(foreground)
            ctx.setFillColor(foreground)
            ctx.setTextDrawingMode(.fillStroke)
        } else {
            ctx.setFillColor(foreground)
            ctx.setTextDrawingMode(.fill)
        }
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func paint(_ drcs: DRCSGlyph, in rect: CGRect) {
        guard let mask = mask(of: drcs) else { return }
        let size = CGSize(width: min(glyph.width, CGFloat(drcs.width)), height: min(glyph.height, CGFloat(drcs.height)))
        let box = CGRect(x: rect.midX - glyph.width / 2, y: rect.midY - glyph.height / 2, width: glyph.width, height: glyph.height)
            .insetBy(dx: (glyph.width - size.width) / 2, dy: (glyph.height - size.height) / 2)
        // CGContext draws images upright in its own y-up sense
        func fill(_ rect: CGRect, _ color: CGColor) {
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            let unit = CGRect(origin: .zero, size: rect.size)
            ctx.clip(to: unit, mask: mask)
            ctx.setFillColor(color)
            ctx.fill(unit)
            ctx.restoreGState()
        }
        let edge = edgeWidth
        if edge > 0 {
            for step in 0..<8 {
                let angle = CGFloat(step) * .pi / 4
                fill(box.offsetBy(dx: cos(angle) * edge, dy: sin(angle) * edge), edgeColor)
            }
        }
        fill(box, foreground)
    }

    private func mask(of drcs: DRCSGlyph) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(drcs.coverage.map { 255 - $0 }) as CFData) else { return nil }
        return CGImage(maskWidth: drcs.width, height: drcs.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: drcs.width,
                       provider: provider, decode: nil, shouldInterpolate: true)
    }
}

/// The half width form of a full width character, for text that the broadcast sets at half width.
private func halfWidthForm(_ text: String) -> String? {
    guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return nil }
    switch scalar.value {
    case 0xFF01...0xFF5E: return String(UnicodeScalar(scalar.value - 0xFEE0)!)
    case 0xFFE3: return "¯"
    case 0xFFE5: return "¥"
    case 0x3000: return " "
    case 0x3001: return "､"
    case 0x3002: return "｡"
    case 0x300C: return "｢"
    case 0x300D: return "｣"
    case 0x30FB: return "･"
    case 0x201D: return "\""
    case 0x2019: return "'"
    case 0x2018: return "`"
    default: return nil
    }
}
