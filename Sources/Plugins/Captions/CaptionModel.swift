// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics

/// Color in the ARIB color map.
struct CaptionColor: Equatable {
    var red, green, blue, alpha: UInt8

    init(index: Int) {
        let c = ARIBTables.palette[index & 0x7F]
        (red, green, blue, alpha) = c
    }

    var isTransparent: Bool { alpha == 0 }
}

/// Character sizes of ARIB STD-B24 (SSZ, MSZ, NSZ and SZX).
enum CaptionCharSize {
    case small, medium, normal, tall, wide, double
}

enum CaptionFlash {
    case none, normal, inverse
}

/// How a run of text looks.
struct CaptionStyle: Equatable {
    var size = CaptionCharSize.normal
    var foreground = CaptionColor(index: 7)
    var background = CaptionColor(index: 8)
    var outline: CaptionColor?  // ORN
    var underline = false
    var bold = false
    var italic = false
    var flash = CaptionFlash.none
    var enclosure = CaptionEnclosure()
    /// Size of a character, and the intervals between them, on the caption plane.
    var charWidth = 36, charHeight = 36
    var horizontalInterval = 4, verticalInterval = 24
}

/// Lines drawn around a run (HLC).
struct CaptionEnclosure: Equatable {
    var left = false, top = false, right = false, bottom = false

    init() {}

    init(hlc: UInt8) {
        left = hlc & 8 != 0
        top = hlc & 4 != 0
        right = hlc & 2 != 0
        bottom = hlc & 1 != 0
    }
}

extension CaptionStyle {
    /// Size of the display section of one character. It must agree with how the decoder advances.
    var section: CGSize {
        var w = charWidth + horizontalInterval, h = charHeight + verticalInterval
        switch size {
        case .small:
            w = charWidth / 2 + horizontalInterval / 4 * 2
            h = charHeight / 2 + verticalInterval / 4 * 2
        case .medium:
            w = charWidth / 2 + horizontalInterval / 4 * 2
        case .tall: h *= 2
        case .wide: w *= 2
        case .double: w *= 2; h *= 2
        case .normal: break
        }
        return CGSize(width: max(w, 1), height: max(h, 1))
    }

    /// Size of one character.
    var glyph: CGSize {
        var w = charWidth, h = charHeight
        switch size {
        case .small: w /= 2; h /= 2
        case .medium: w /= 2
        case .tall: h *= 2
        case .wide: w *= 2
        case .double: w *= 2; h *= 2
        case .normal: break
        }
        return CGSize(width: w, height: h)
    }
}

/// A character defined by the broadcast itself (DRCS).
final class DRCSGlyph {
    let width, height: Int
    /// One byte per pixel from the top left: 0 (background) to 255 (foreground).
    let coverage: [UInt8]
    /// What the pattern depicts, when an ordinary font can show it better.
    let replacement: String?

    init(width: Int, height: Int, coverage: [UInt8], replacement: String?) {
        self.width = width
        self.height = height
        self.coverage = coverage
        self.replacement = replacement
    }
}

/// What occupies one display section.
enum CaptionCell {
    case text(String)
    case glyph(DRCSGlyph)
    /// SP: only the background.
    case space
    /// DEL: all foreground.
    case block
}

struct CaptionRun {
    var cells: [CaptionCell]
    var style: CaptionStyle
    /// Built-in sound to play when the run appears (PRA).
    var sound: Int?
}

/// The part of the caption plane that captions are placed in.
struct CaptionPlaneArea: Equatable {
    var format: Int  // SWF
    var x, y, width, height: Int

    /// Size of the whole plane.
    var planeSize: CGSize {
        format == 9 || format == 10 ? CGSize(width: 720, height: 480) : CGSize(width: 960, height: 540)
    }
}

/// Runs that share a line, one after another.
struct CaptionRow {
    /// Milliseconds after the time of the caption.
    var wait: Int
    var area: CaptionPlaneArea
    /// Left end of the first section, and the last raster of the line, on the plane.
    var x, y: Int
    var runs: [CaptionRun] = []
}

/// A picture (PNG) in the caption.
struct CaptionBitmap {
    var wait: Int
    var area: CaptionPlaneArea
    /// Relative to `area`.
    var x, y: Int
    var image: CGImage
    /// Set when some colors flash: the picture without them, which alternates with `image`.
    var flashing: CGImage?
}

enum CaptionItem {
    case clear(wait: Int)
    case row(CaptionRow)
    case bitmap(CaptionBitmap)

    var wait: Int {
        switch self {
        case .clear(let wait): return wait
        case .row(let row): return row.wait
        case .bitmap(let bitmap): return bitmap.wait
        }
    }
}
