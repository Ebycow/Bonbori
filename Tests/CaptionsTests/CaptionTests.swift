// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation
import Testing
@testable import Captions

// MARK: - Building data groups

private func dataGroup(id: UInt8, _ body: [UInt8]) -> [UInt8] {
    var pes: [UInt8] = [0x80, 0xFF, 0xF0]
    pes += [id << 2, 0, 0, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
    pes += body
    return pes + [0, 0]  // CRC
}

private func unit(_ parameter: UInt8, _ data: [UInt8]) -> [UInt8] {
    [0x1F, parameter, UInt8(data.count >> 16), UInt8((data.count >> 8) & 0xFF), UInt8(data.count & 0xFF)] + data
}

private func units(_ list: [[UInt8]]) -> [UInt8] {
    let all = list.flatMap { $0 }
    return [UInt8(all.count >> 16), UInt8((all.count >> 8) & 0xFF), UInt8(all.count & 0xFF)] + all
}

/// Language entries: (tag, code, format).
private func management(group: UInt8 = 0, languages: [(UInt8, String, UInt8)] = [(0, "jpn", 8)], units list: [[UInt8]] = []) -> [UInt8] {
    var body: [UInt8] = [0x3F, UInt8(languages.count)]
    for (tag, code, format) in languages {
        body += [tag << 5 | 0x10] + Array(code.utf8) + [format << 4 | 0x03]
    }
    return dataGroup(id: group, body + units(list))
}

private func statement(group: UInt8 = 0, language: UInt8 = 1, _ list: [[UInt8]]) -> [UInt8] {
    dataGroup(id: group | language, [0x3F] + units(list))
}

/// One statement in the default language, decoded.
private func decoded(_ text: [UInt8]) -> [CaptionItem] {
    let stream = CaptionStream()
    _ = stream.feed(management())
    return stream.feed(statement([unit(0x20, text)]))
}

private func rows(_ items: [CaptionItem]) -> [CaptionRow] {
    items.compactMap { if case .row(let row) = $0 { return row } else { return nil } }
}

private func text(_ row: CaptionRow) -> String {
    row.runs.flatMap(\.cells).map {
        switch $0 {
        case .text(let s): return s
        case .space: return " "
        case .block: return "■"
        case .glyph: return "□"
        }
    }.joined()
}

/// JIS X 0208 row and column, as the two bytes of the default G0.
private func jis(_ row: Int, _ column: Int) -> [UInt8] { [UInt8(0x20 + row), UInt8(0x20 + column)] }

// MARK: - Characters

@Test func kanjiHiraganaAndAlphanumeric() {
    // 漢 (20-33), then あ from G2 through GR, then Ａ from G1 through LS1
    let bytes = jis(20, 33) + [0xA2] + [0x0E, 0x41, 0x0F] + jis(20, 33)
    let row = rows(decoded(bytes))[0]
    #expect(text(row) == "漢あＡ漢")
}

@Test func jisCharactersThatDifferBetweenEncodings() {
    #expect(ARIBCaptionDecoder.jisCharacter(0x2D, 0x21) == "①")  // row 13
    #expect(ARIBCaptionDecoder.jisCharacter(0x21, 0x41) == "～")
    #expect(ARIBCaptionDecoder.jisCharacter(0x30, 0x21) == "亜")
    #expect(ARIBCaptionDecoder.jisCharacter(0x4F, 0x53) == "腕")  // the last of level 1
    #expect(ARIBCaptionDecoder.jisCharacter(0x4F, 0x54) == "・")  // not assigned
    #expect(ARIBCaptionDecoder.jisCharacter(0x74, 0x26) == "熙")  // row 84, the last one
}

@Test func additionalSymbols() {
    // row 90 column 48 is [HV]; row 92 column 7 is 年; row 85 column 1 is 㐂
    let bytes = jis(90, 48) + jis(92, 7) + jis(85, 1)
    #expect(text(rows(decoded(bytes))[0]) == "\u{1F14A}年\u{3402}")
}

@Test func symbolsWithoutUnicodeBecomeGeta() {
    #expect(text(rows(decoded(jis(90, 7)))[0]) == "〓")
}

@Test func nonSpacingMarkGoesOnTheNextCharacter() {
    // ゛-like marks: ´ (1-13) then あ takes one cell
    let row = rows(decoded(jis(1, 13) + [0xA2, 0xA4]))[0]
    #expect(row.runs[0].cells.count == 2)
    #expect(text(row) == "あ\u{0301}い")
}

@Test func macroDesignatesCodeSets() {
    // default macro 0x60 through G3: G1 alnum, G2 hira. Macro 0x6F: G0 alnum, G1 mosaic A
    let bytes: [UInt8] = [0x1D, 0x6F, 0x41]
    #expect(text(rows(decoded(bytes))[0]) == "Ａ")
}

@Test func repeatedCharacter() {
    let bytes: [UInt8] = [0x98, 0x43, 0xA2]  // RPC 3 + あ
    #expect(text(rows(decoded(bytes))[0]) == "あああ")
}

@Test func repeatToTheEndOfTheLine() {
    let bytes: [UInt8] = [0x98, 0x40, 0xA2]
    #expect(rows(decoded(bytes))[0].runs[0].cells.count == 24)  // 960 / (36 + 4)
}

// MARK: - Position

@Test func positionOfTheFirstCharacter() {
    let row = rows(decoded([0xA2]))[0]
    #expect(row.x == 0)
    #expect(row.y == 59)  // bottom raster of the first line: 36 + 24 - 1
    #expect(row.area.width == 960)
}

@Test func typicalCaption() {
    // SWF 7, SDF 620x480, SDP 170,30, SSM 36x36, SHS 4, SVS 24, then APS line 8 column 5
    var bytes: [UInt8] = [0x0C, 0x9B, 0x37, 0x20, 0x53]
    bytes += [0x9B] + Array("620;480".utf8) + [0x20, 0x56]
    bytes += [0x9B] + Array("170;30".utf8) + [0x20, 0x5F]
    bytes += [0x9B] + Array("36;36".utf8) + [0x20, 0x57]
    bytes += [0x9B] + Array("4".utf8) + [0x20, 0x58]
    bytes += [0x9B] + Array("24".utf8) + [0x20, 0x59]
    bytes += [0x1C, 0x48, 0x45, 0xA2]
    let items = decoded(bytes)
    guard case .clear? = items.first else {
        Issue.record("no clear")
        return
    }
    let row = rows(items)[0]
    #expect(row.area == CaptionPlaneArea(format: 7, x: 170, y: 30, width: 620, height: 480))
    #expect(row.x == 170 + 40 * 5)
    #expect(row.y == 30 + 60 * 9 - 1)
}

@Test func halfWidthAdvancesByHalf() {
    let bytes: [UInt8] = [0x89, 0xA2, 0xA2, 0x8A, 0xA4]  // MSZ あ あ NSZ い
    let row = rows(decoded(bytes))[0]
    #expect(row.runs.count == 2)
    #expect(row.runs[0].style.section.width == 20)  // 36 / 2 + 4 / 4 * 2
    #expect(row.runs[1].style.section.width == 40)
    #expect(CaptionRenderer.width(of: row) == 80)
}

@Test func wrapsAtTheEdgeOfTheArea() {
    var bytes: [UInt8] = [0x9B] + Array("80;480".utf8) + [0x20, 0x56]  // two characters wide
    bytes += [0xA2, 0xA4, 0xA6]
    let list = rows(decoded(bytes))
    #expect(list.count == 2)
    #expect(text(list[0]) == "あい")
    #expect(text(list[1]) == "う")
    #expect(list[1].x == 0)
    #expect(list[1].y == list[0].y + 60)
}

@Test func colorsAndStyles() {
    let bytes: [UInt8] = [0x83, 0xA2, 0x90, 0x51, 0xA4, 0x90, 0x20, 0x41, 0x90, 0x42, 0xA6, 0x91, 0x40, 0xA8, 0x9A, 0xAA]
    let runs = rows(decoded(bytes))[0].runs
    #expect(runs[0].style.foreground == CaptionColor(index: 3))
    #expect(runs[1].style.background == CaptionColor(index: 1))
    #expect(runs[2].style.foreground == CaptionColor(index: 16 + 2))
    #expect(runs[3].style.flash == .normal)
    #expect(runs[4].style.underline)
}

// MARK: - Time

@Test func waitAddsUp() {
    let bytes: [UInt8] = [0xA2, 0x9D, 0x20, 0x4A, 0xA4, 0x9D, 0x20, 0x45, 0x0C]
    let items = decoded(bytes)
    #expect(items.map(\.wait) == [0, 1000, 1500])
}

// MARK: - Stream

@Test func statementsWaitForManagement() {
    let stream = CaptionStream()
    #expect(stream.feed(statement([unit(0x20, [0xA2])])).isEmpty)
    _ = stream.feed(management())
    #expect(!stream.feed(statement([unit(0x20, [0xA2])])).isEmpty)
}

@Test func otherGroupIsIgnored() {
    let stream = CaptionStream()
    _ = stream.feed(management(group: 0x20))
    #expect(stream.feed(statement(group: 0, [unit(0x20, [0xA2])])).isEmpty)
    #expect(!stream.feed(statement(group: 0x20, [unit(0x20, [0xA2])])).isEmpty)
}

@Test func secondLanguage() {
    let stream = CaptionStream()
    stream.usesSecondLanguage = true
    _ = stream.feed(management(languages: [(0, "jpn", 8), (1, "eng", 8)]))
    #expect(stream.language?.code == "eng")
    #expect(stream.feed(statement(language: 1, [unit(0x20, [0xA2])])).isEmpty)
    #expect(!stream.feed(statement(language: 2, [unit(0x20, [0xA2])])).isEmpty)
}

@Test func onlyOneLanguageFallsBackToIt() {
    let stream = CaptionStream()
    stream.usesSecondLanguage = true
    _ = stream.feed(management())
    #expect(stream.language?.code == "jpn")
}

@Test func managementTimesOut() {
    let stream = CaptionStream()
    let start = Date()
    _ = stream.feed(management(), now: start)
    #expect(!stream.languages.isEmpty)
    _ = stream.feed(statement([unit(0x20, [0xA2])]), now: start.addingTimeInterval(181))
    #expect(stream.languages.isEmpty)
}

@Test func brokenDataIsHarmless() {
    let stream = CaptionStream()
    _ = stream.feed(management())
    let good = statement([unit(0x20, [0x9B, 0x37, 0x20, 0x53, 0x1B, 0x24, 0x42, 0xA2])])
    for n in 0..<good.count { _ = stream.feed(Array(good[..<n])) }
    // a statement that ends in the middle of a code gives nothing
    #expect(stream.feed(statement([unit(0x20, [0xA2, 0x1C, 0x41])])).isEmpty)
}

// MARK: - DRCS

private func drcsUnit(code: (UInt8, UInt8), width: UInt8, height: UInt8, pattern: [UInt8]) -> [UInt8] {
    unit(0x30, [1, code.0, code.1, 1, 0x00, 0, width, height] + pattern)
}

@Test func drcsCharacter() {
    // DRCS-1 into G0, 1-byte: code 0x21
    let stream = CaptionStream()
    _ = stream.feed(management())
    let pattern: [UInt8] = [0b1000_0000, 0b0100_0000]
    let items = stream.feed(statement([drcsUnit(code: (0x41, 0x21), width: 8, height: 2, pattern: pattern),
                                       unit(0x20, [0x1B, 0x28, 0x20, 0x41, 0x21])]))
    guard case .glyph(let glyph)? = rows(items).first?.runs[0].cells[0] else {
        Issue.record("no glyph")
        return
    }
    #expect(glyph.width == 8)
    #expect(glyph.coverage[0] == 255)
    #expect(glyph.coverage[1] == 0)
    #expect(glyph.coverage[9] == 255)
}

@Test func replacementTableHasNoDuplicatesAndMatchesTheFile() {
    #expect(ARIBTables.drcsReplacements.count == 246)
    #expect(ARIBTables.drcsReplacements["012665F146F9C4DFBFE65C41C8B30C19"] == "芦")
}

// MARK: - Pictures

/// A palette PNG without its PLTE chunk, as broadcast: 2x1, indices 7 and 1.
private func broadcastPNG() -> [UInt8] {
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let named = Array(type.utf8) + body
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in named {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 }
        }
        crc = ~crc
        func be(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }
        return be(UInt32(body.count)) + named + be(crc)
    }
    let header: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    let ihdr = chunk("IHDR", [0, 0, 0, 2, 0, 0, 0, 1, 8, 3, 0, 0, 0])
    let raw: [UInt8] = [0, 7, 1]
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in raw {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }
    let adler = b << 16 | a
    let zlib: [UInt8] = [0x78, 0x01, 0x01, 3, 0, 0xFC, 0xFF] + raw + (0..<4).map { UInt8(truncatingIfNeeded: adler >> (24 - 8 * $0)) }
    return header + ihdr + chunk("IDAT", zlib) + chunk("IEND", [])
}

@Test func pictureIsDecodedWithTheCaptionPalette() {
    let stream = CaptionStream()
    _ = stream.feed(management())
    let data: [UInt8] = [0, 10, 0xFF, 0xFE, 1, 7] + broadcastPNG()  // x 10, y -2, color 7 flashes
    let items = stream.feed(statement([unit(0x35, data)]))
    guard case .bitmap(let bitmap)? = items.first else {
        Issue.record("no bitmap")
        return
    }
    #expect(bitmap.x == 10)
    #expect(bitmap.y == -2)
    #expect(bitmap.image.width == 2)
    #expect(bitmap.flashing != nil)
    #expect(pixel(bitmap.image, 0) == [255, 255, 255, 255])
    #expect(pixel(bitmap.image, 1) == [255, 0, 0, 255])
    #expect(bitmap.flashing.map { pixel($0, 0)[3] } == 0)
}

private func pixel(_ image: CGImage, _ x: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 8)
    let ctx = CGContext(data: &out, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
    return Array(out[(x * 4)..<(x * 4 + 4)])
}

// MARK: - Drawing

@Test func rowsDrawIntoTheirRect() {
    let row = rows(decoded([0x90, 0x50, 0xA2, 0xA4]))[0]
    let parts = CaptionRenderer.render(row, options: CaptionRenderOptions(), scaleX: 2, scaleY: 2)
    #expect(parts.count == 1)
    #expect(parts[0].rect.minY < 0)  // the margin above the first line
    #expect(parts[0].image.width == Int((parts[0].rect.width * 2).rounded(.up)))
}

@Test func flashingRunsGetTheirOwnLayer() {
    let row = rows(decoded([0xA2, 0x91, 0x40, 0xA4, 0x91, 0x47, 0xA6]))[0]
    let parts = CaptionRenderer.render(row, options: CaptionRenderOptions(), scaleX: 2, scaleY: 2)
    #expect(Set(parts.map(\.flash)) == [.none, .normal, .inverse])
}
