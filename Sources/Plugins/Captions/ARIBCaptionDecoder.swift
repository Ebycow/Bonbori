// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Input that ends in the middle of a code, or that uses something the broadcasts do not.
struct InvalidCaptionData: Error {}

struct ByteReader {
    let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { position >= bytes.count }

    mutating func next() throws -> UInt8 {
        guard position < bytes.count else { throw InvalidCaptionData() }
        position += 1
        return bytes[position - 1]
    }

    func peek() throws -> UInt8 {
        guard position < bytes.count else { throw InvalidCaptionData() }
        return bytes[position]
    }
}

/// Turns the statement body of a caption (ARIB STD-B24 8-unit code, as used by ARIB TR-B14) into rows
/// of text placed on the caption plane. Each statement starts from the initial state.
final class ARIBCaptionDecoder {
    private enum CodeSet: Equatable {
        case kanji, alphanumeric, hiragana, katakana, jisKatakana, macro, drcs(Int), unsupported
    }

    private struct Designation {
        var set: CodeSet
        var bytes: Int
    }

    private let initialFormat: Int
    private let drcs: [UInt16: [DRCSGlyph]]
    private(set) var items: [CaptionItem]

    private var format = 0
    private var g: [Designation] = []
    private var gl = 0, gr = 2
    private var style = CaptionStyle()
    private var paletteBank = 0
    private var outlineMode = 0
    private var outlineColor = 8
    private var hlc: UInt8 = 0
    private var area = CaptionPlaneArea(format: 7, x: 0, y: 0, width: 960, height: 540)
    private var posX = 0, posY = 0, runStartX = 0
    private var positioned = false
    private var wait = 0
    private var cells: [CaptionCell] = []
    /// Non-spacing marks that go with the next character.
    private var marks = ""
    /// RPC: the next character repeats this many times; 0 means up to the end of the line.
    private var repetition: Int?

    init(format: Int, drcs: [UInt16: [DRCSGlyph]], items: [CaptionItem]) {
        initialFormat = format
        self.drcs = drcs
        self.items = items
    }

    static func isSupported(format: Int) -> Bool {
        [7, 8, 9, 10].contains(format)
    }

    func decode(_ statement: [UInt8]) throws {
        format = initialFormat
        reset()
        var reader = ByteReader(statement)
        try run(&reader)
        flush()
    }

    private func reset() {
        g = [Designation(set: .kanji, bytes: 2), Designation(set: .alphanumeric, bytes: 1),
             Designation(set: .hiragana, bytes: 1), Designation(set: .macro, bytes: 1)]
        gl = 0
        gr = 2
        cells = []
        marks = ""
        repetition = nil
        style = CaptionStyle()
        paletteBank = 0
        outlineMode = 0
        outlineColor = 8
        hlc = 0
        switch format {
        case 8: (style.horizontalInterval, style.verticalInterval) = (12, 24)
        case 9: (style.horizontalInterval, style.verticalInterval) = (4, 16)
        case 10: (style.horizontalInterval, style.verticalInterval) = (8, 24)
        default: (style.horizontalInterval, style.verticalInterval) = (4, 24)
        }
        area = CaptionPlaneArea(format: format, x: 0, y: 0, width: 0, height: 0)
        area.width = Int(area.planeSize.width)
        area.height = Int(area.planeSize.height)
        posX = area.x
        runStartX = area.x
        posY = area.y + lineStep - 1
        positioned = false
        wait = 0
    }

    private var charStep: Int { Int(style.section.width) }
    private var lineStep: Int { Int(style.section.height) }

    private func run(_ r: inout ByteReader) throws {
        while !r.isAtEnd {
            let b = try r.next()
            switch b {
            case 0x20:
                put(.space)
            case 0x00...0x1F:
                try c0(b, &r)
            case 0x21...0x7E:
                try graphic(b, g[gl], &r)
            case 0x7F:
                put(.block)
            case 0x80...0xA0:
                try c1(b, &r)
            case 0xA1...0xFE:
                try graphic(b, g[gr], &r)
            default:
                break
            }
        }
    }

    // MARK: - Characters

    private func graphic(_ first: UInt8, _ d: Designation, _ r: inout ByteReader) throws {
        let b = first & 0x7F
        guard b >= 0x21, b < 0x7F else { return }
        switch d.set {
        case .kanji:
            let second = try r.next() & 0x7F
            kanji(Int(b), Int(second))
        case .alphanumeric:
            put(text: ARIBCaptionDecoder.alphanumeric[b] ?? String(UnicodeScalar(UInt32(b) + 0xFEE0)!))
        case .hiragana:
            put(text: ARIBCaptionDecoder.hiragana[Int(b) - 0x21])
        case .katakana:
            put(text: ARIBCaptionDecoder.katakana[Int(b) - 0x21])
        case .jisKatakana:
            put(text: Int(b) - 0x21 < ARIBCaptionDecoder.jisKatakana.count ? ARIBCaptionDecoder.jisKatakana[Int(b) - 0x21] : "・")
        case .macro:
            if b >= 0x60, b <= 0x6F {
                var macro = ByteReader(ARIBCaptionDecoder.defaultMacros[Int(b & 0x0F)])
                try run(&macro)
            }
        case .drcs(let set):
            var code = UInt16(set) << 8 | UInt16(b)
            if set == 0 { code = UInt16(b) << 8 | UInt16(try r.next() & 0x7F) }
            drcs(code)
        case .unsupported:
            for _ in 1..<max(d.bytes, 1) { _ = try r.next() }
        }
    }

    private func kanji(_ first: Int, _ second: Int) {
        guard (0x21...0x7E).contains(second) else { return put(text: "・") }
        if first >= 0x75 { return put(text: ARIBCaptionDecoder.additional(row: first, column: second)) }
        // non-spacing marks (´｀¨＾￣＿◯)
        if let mark = ARIBCaptionDecoder.nonSpacing[first << 8 | second] {
            marks.unicodeScalars.append(mark)
            return
        }
        put(text: ARIBCaptionDecoder.jisCharacter(first, second))
    }

    /// The additional symbols and kanji are in rows 0x7A...0x7E and 0x75, 0x76.
    private static func additional(row: Int, column: Int) -> String {
        let bank: Int
        switch row {
        case 0x7A...0x7E: bank = row - 0x7A
        case 0x75, 0x76: bank = row - 0x75 + 5
        default: return "・"
        }
        let code = ARIBTables.additional[bank * 94 + column - 0x21]
        // No Unicode character for it: nothing on this machine can draw it.
        guard !(0xE000...0xF8FF).contains(code), let scalar = UnicodeScalar(code) else { return "〓" }
        return String(scalar)
    }

    /// JIS X 0208. Shift JIS is the encoding that also knows the characters in row 13.
    static func jisCharacter(_ first: Int, _ second: Int) -> String {
        let row = first - 0x21, column = second - 0x21
        let lead = row / 2 + (row / 2 < 31 ? 0x81 : 0xC1)
        var trail = row % 2 == 0 ? column + 0x40 : column + 0x9F
        if row % 2 == 0, trail >= 0x7F { trail += 1 }
        let text = String(bytes: [UInt8(lead), UInt8(trail)], encoding: .shiftJIS)
        return text.flatMap { $0.isEmpty ? nil : $0 } ?? "・"
    }

    private func drcs(_ code: UInt16) {
        guard let glyphs = drcs[code], let last = glyphs.last else { return put(.space) }
        let size = style.glyph
        let glyph = glyphs.last { $0.width == Int(size.width) && $0.height == Int(size.height) } ?? last
        put(glyph.replacement.map(CaptionCell.text) ?? .glyph(glyph))
    }

    private func put(text: String) {
        put(.text(text + marks))
    }

    private func put(_ cell: CaptionCell) {
        var count = repetition ?? 1
        let toLineEnd = repetition == 0
        repetition = nil
        marks = ""
        let line = posY
        var limit = 256
        while limit > 0, toLineEnd ? posY == line : count > 0 {
            cells.append(cell)
            forward(1)
            count -= 1
            limit -= 1
        }
    }

    // MARK: - Position

    private func forward(_ count: Int) {
        positioned = true
        var x = posX, y = posY
        for _ in 0..<max(count, 0) {
            x += charStep
            if x >= area.x + area.width {
                x = area.x
                y += lineStep
                if y >= area.y + area.height { y = area.y + lineStep - 1 }
            }
        }
        if y != posY {
            flush()
            runStartX = x
        }
        posX = x
        posY = y
    }

    private func lineForward() {
        flush()
        positioned = true
        posY += lineStep
        if posY >= area.y + area.height { posY = area.y + lineStep - 1 }
    }

    private func lineBackward() {
        positioned = true
        if posY < area.y + lineStep * 2 - 1 { posY = area.y + (area.height / lineStep + 1) * lineStep - 1 }
        posY -= lineStep
    }

    // MARK: - Rows

    /// Moves the characters so far into the current row. To be called before anything that
    /// changes how they would look or where they would go.
    private func flush(sound: Int? = nil) {
        guard sound != nil || !cells.isEmpty else { return }
        let run = CaptionRun(cells: cells, style: currentStyle, sound: sound)
        cells = []
        if case .row(var row)? = items.last, row.wait == wait, row.area == area, row.x == runStartX, row.y == posY {
            row.runs.append(run)
            items[items.count - 1] = .row(row)
        } else {
            var row = CaptionRow(wait: wait, area: area, x: runStartX, y: posY)
            row.runs.append(run)
            items.append(.row(row))
        }
    }

    private var currentStyle: CaptionStyle {
        var s = style
        s.outline = outlineMode == 1 ? CaptionColor(index: outlineColor) : nil
        s.enclosure = CaptionEnclosure(hlc: hlc)
        return s
    }

    private func color(_ low: UInt8) -> CaptionColor {
        CaptionColor(index: paletteBank << 4 | Int(low & 0x0F))
    }

    // MARK: - Control codes

    private func c0(_ b: UInt8, _ r: inout ByteReader) throws {
        switch b {
        case 0x08:  // APB
            flush()
            positioned = true
            if posX < area.x + charStep {
                posX = area.x + area.width / charStep * charStep
                lineBackward()
            }
            posX -= charStep
            runStartX = posX
        case 0x09:  // APF
            flush()
            forward(1)
            runStartX = posX
        case 0x0A:  // APD
            lineForward()
            runStartX = posX
        case 0x0B:  // APU
            flush()
            lineBackward()
            runStartX = posX
        case 0x0C:  // CS
            flush()
            items.append(.clear(wait: wait))
            format = initialFormat
            reset()
        case 0x0D:  // APR
            flush()
            posX = area.x
            lineForward()
            runStartX = posX
        case 0x0E:  // LS1
            gl = 1
        case 0x0F:  // LS0
            gl = 0
        case 0x16:  // PAPF
            let n = Int(try r.next()) - 0x40
            flush()
            forward(n)
            runStartX = posX
        case 0x19:  // SS2
            let c = try r.next()
            try graphic(c, g[2], &r)
        case 0x1B:
            try escape(&r)
        case 0x1C:  // APS
            let line = Int(try r.next()) - 0x40, column = Int(try r.next()) - 0x40
            flush()
            positioned = true
            // the reference point of a section is its lower left corner
            let y = area.y + lineStep * (line + 1) - 1, x = area.x + charStep * column
            if x != posX || y != posY {
                posX = x
                posY = y
                runStartX = x
            }
        case 0x1D:  // SS3
            let c = try r.next()
            try graphic(c, g[3], &r)
        default:
            break
        }
    }

    private func escape(_ r: inout ByteReader) throws {
        let b = try r.next()
        switch b {
        case 0x24:
            let second = try r.next()
            if (0x28...0x2B).contains(second) {
                let third = try r.next()
                if third == 0x20 {
                    designate(Int(second) - 0x28, drcsFinal: try r.next(), bytes: 2)
                } else {
                    designate(Int(second) - 0x28, final: third, bytes: 2)
                }
            } else {
                designate(0, final: second, bytes: 2)
            }
        case 0x28...0x2B:
            let second = try r.next()
            if second == 0x20 {
                designate(Int(b) - 0x28, drcsFinal: try r.next(), bytes: 1)
            } else {
                designate(Int(b) - 0x28, final: second, bytes: 1)
            }
        case 0x6E: gl = 2
        case 0x6F: gl = 3
        case 0x7C: gr = 3
        case 0x7D: gr = 2
        case 0x7E: gr = 1
        default: throw InvalidCaptionData()
        }
    }

    private func designate(_ n: Int, final: UInt8, bytes: Int) {
        let set: CodeSet
        switch final {
        case 0x42, 0x39, 0x3A, 0x3B: set = .kanji
        case 0x4A, 0x36: set = .alphanumeric
        case 0x30, 0x37: set = .hiragana
        case 0x31, 0x38: set = .katakana
        case 0x49: set = .jisKatakana
        default: set = .unsupported
        }
        g[n] = Designation(set: set, bytes: bytes)
    }

    private func designate(_ n: Int, drcsFinal final: UInt8, bytes: Int) {
        let set: CodeSet
        switch final {
        case 0x40...0x4F: set = .drcs(Int(final) - 0x40)
        case 0x70: set = .macro
        default: set = .unsupported
        }
        g[n] = Designation(set: set, bytes: bytes)
    }

    private func c1(_ b: UInt8, _ r: inout ByteReader) throws {
        flush()
        switch b {
        case 0x80...0x87:  // BKF...WHF
            style.foreground = color(b & 7)
        case 0x88: style.size = .small   // SSZ
        case 0x89: style.size = .medium  // MSZ
        case 0x8A: style.size = .normal  // NSZ
        case 0x8B:  // SZX
            switch try r.next() {
            case 0x41: style.size = .tall
            case 0x44: style.size = .wide
            case 0x45: style.size = .double
            case 0x60, 0x64, 0x6B: style.size = .normal
            default: break
            }
        case 0x90:  // COL
            let p = try r.next()
            if p == 0x20 {
                paletteBank = Int(try r.next() & 0x07)
            } else if p & 0xF0 == 0x40 {
                style.foreground = color(p)
            } else if p & 0xF0 == 0x50 {
                style.background = color(p)
            }
        case 0x91:  // FLC
            switch try r.next() {
            case 0x40: style.flash = .normal
            case 0x47: style.flash = .inverse
            case 0x4F: style.flash = .none
            default: break
            }
        case 0x92:  // CDC
            if try r.next() == 0x20 { _ = try r.next() }
        case 0x93, 0x94:  // POL, WMM
            _ = try r.next()
        case 0x95:  // MACRO: the definitions are not used in practice, skip up to its end
            _ = try r.next()
            var previous = try r.next()
            while true {
                let c = try r.next()
                if previous == 0x95, c == 0x4F { break }
                previous = c
            }
        case 0x97:  // HLC
            hlc = try r.next() & 0x0F
        case 0x98:  // RPC
            let p = Int(try r.next()) - 0x40
            repetition = p >= 0 && p < 0x40 ? p : 0
        case 0x99: style.underline = false  // SPL
        case 0x9A: style.underline = true   // STL
        case 0x9B:
            try controlSequence(&r)
        case 0x9D:  // TIME
            let p = try r.next()
            if p == 0x20 {
                wait += (Int(try r.next()) - 0x40) * 100
            } else {
                var c = p
                while !(0x40...0x43).contains(c) { c = try r.next() }
            }
        default:
            break
        }
    }

    private func controlSequence(_ r: inout ByteReader) throws {
        var p1 = 0, p2 = 0, count = 0
        while true {
            let b = try r.next()
            if b == 0x20 {
                if count == 0 { p1 = p2 }
                count += 1
                break
            } else if b == 0x3B {
                if count == 0 {
                    p1 = p2
                    p2 = 0
                }
                count += 1
            } else if (0x30...0x39).contains(b), count <= 1, p2 < 10000 {
                p2 = p2 * 10 + Int(b & 0x0F)
            }
        }
        switch try r.next() {
        case 0x53:  // SWF
            if count == 1 { format = p1 }
            guard ARIBCaptionDecoder.isSupported(format: format) else { throw InvalidCaptionData() }
            reset()
        case 0x56:  // SDF
            area.width = p1
            if count >= 2 { area.height = p2 }
        case 0x57:  // SSM
            style.charWidth = p1
            if count >= 2 { style.charHeight = p2 }
            if !positioned { posY = area.y + lineStep - 1 }
        case 0x58:  // SHS
            style.horizontalInterval = p1
        case 0x59:  // SVS
            style.verticalInterval = p1
        case 0x5F:  // SDP
            area.x = p1
            if count >= 2 { area.y = p2 }
            if !positioned {
                posX = area.x
                runStartX = posX
                posY = area.y + lineStep - 1
            }
        case 0x61:  // ACPS
            posX = p1
            runStartX = p1
            if count >= 2 { posY = p2 }
        case 0x63:  // ORN
            if p1 <= 3 {
                outlineMode = p1
                outlineColor = count >= 2 && (p1 == 1 || p1 == 2) ? (p2 / 100) << 4 | (p2 % 100) : 8
            }
        case 0x64:  // MDF
            if p1 <= 3 {
                style.bold = p1 & 1 != 0
                style.italic = p1 & 2 != 0
            }
        case 0x68:  // PRA
            flush(sound: p1)
        default:
            break
        }
    }

    // MARK: - Tables

    /// The alphanumeric set is shown full width, as in JIS X 0208.
    private static let alphanumeric: [UInt8: String] = [0x22: "”", 0x27: "’", 0x5C: "￥", 0x60: "‘", 0x7E: "￣"]

    private static let nonSpacing: [Int: UnicodeScalar] = [
        0x212D: "\u{0301}", 0x212E: "\u{0300}", 0x212F: "\u{0308}", 0x2130: "\u{0302}",
        0x2131: "\u{0305}", 0x2132: "\u{0332}", 0x227E: "\u{20DD}",
    ]

    private static let hiragana = (Array("ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわゐゑをん　　　ゝゞー。「」、・")).map(String.init)
    private static let katakana = (Array("ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポマミムメモャヤュユョヨラリルレロヮワヰヱヲンヴヵヶヽヾー。「」、・")).map(String.init)
    private static let jisKatakana = (Array("。「」、・ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン゛゜")).map(String.init)

    /// The default macros of ARIB STD-B24: each designates a combination of code sets.
    private static let defaultMacros: [[UInt8]] = [
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x4A, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x31, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x41, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x32, 0x1B, 0x29, 0x34, 0x1B, 0x2A, 0x35, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x32, 0x1B, 0x29, 0x33, 0x1B, 0x2A, 0x35, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x32, 0x1B, 0x29, 0x20, 0x41, 0x1B, 0x2A, 0x35, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x20, 0x41, 0x1B, 0x29, 0x20, 0x42, 0x1B, 0x2A, 0x20, 0x43, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x20, 0x44, 0x1B, 0x29, 0x20, 0x45, 0x1B, 0x2A, 0x20, 0x46, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x20, 0x47, 0x1B, 0x29, 0x20, 0x48, 0x1B, 0x2A, 0x20, 0x49, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x20, 0x4A, 0x1B, 0x29, 0x20, 0x4B, 0x1B, 0x2A, 0x20, 0x4C, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x20, 0x4D, 0x1B, 0x29, 0x20, 0x4E, 0x1B, 0x2A, 0x20, 0x4F, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x42, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x43, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x24, 0x42, 0x1B, 0x29, 0x20, 0x44, 0x1B, 0x2A, 0x30, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x31, 0x1B, 0x29, 0x30, 0x1B, 0x2A, 0x4A, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
        [0x1B, 0x28, 0x4A, 0x1B, 0x29, 0x32, 0x1B, 0x2A, 0x20, 0x41, 0x1B, 0x2B, 0x20, 0x70, 0x0F, 0x1B, 0x7D],
    ]
}
