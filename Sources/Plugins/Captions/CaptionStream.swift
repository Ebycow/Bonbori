// SPDX-License-Identifier: GPL-2.0-or-later
import CryptoKit
import Foundation
import ImageIO

/// One caption ES: follows the caption management data and turns the data groups of the chosen
/// language into items to show.
final class CaptionStream {
    struct Language: Equatable {
        let tag: Int
        let code: String  // ISO 639
        let format: Int   // SWF
        let isEightBitCode: Bool
    }

    /// Without caption management data for this long, a receiver starts over as after tuning.
    private static let managementTimeout: TimeInterval = 180

    private(set) var languages: [Language] = []
    var usesSecondLanguage = false

    /// A or B: data groups of the other one are from before a program change.
    private var group: UInt8?
    private var managementItems: [CaptionItem] = []
    private var managementDRCS: [UInt16: [DRCSGlyph]] = [:]
    private var lastManagement = Date.distantPast

    var language: Language? {
        usesSecondLanguage && languages.count > 1 ? languages[1] : languages.first
    }

    func reset() {
        languages = []
        group = nil
        managementItems = []
        managementDRCS = [:]
    }

    /// Takes one PES payload. Returns what its statement says, if anything.
    func feed(_ payload: [UInt8], now: Date = Date()) -> [CaptionItem] {
        if group != nil, now.timeIntervalSince(lastManagement) >= CaptionStream.managementTimeout { reset() }
        guard payload.count >= 3, payload[0] == 0x80 || payload[0] == 0x81, payload[1] == 0xFF else { return [] }
        let start = 3 + Int(payload[2] & 0x0F)
        guard payload.count >= start + 5 else { return [] }
        let id = payload[start] >> 2
        let size = Int(payload[start + 3]) << 8 | Int(payload[start + 4])
        guard payload.count >= start + 5 + size else { return [] }
        let data = Array(payload[(start + 5)..<(start + 5 + size)])
        let groupID = id & 0xF0, number = Int(id & 0x0F)

        if number == 0 {
            if groupID == group {
                lastManagement = now  // sent again
            } else if (try? parseManagement(data)) != nil {
                group = groupID
                lastManagement = now
            } else {
                reset()
            }
            return []
        }
        guard groupID == group, number <= 8, let language, language.tag == number - 1 else { return [] }
        return (try? parseStatement(data, language: language)) ?? []
    }

    // MARK: - Data groups

    private func parseManagement(_ data: [UInt8]) throws {
        var r = ByteReader(data)
        let tmd = try r.next() >> 6
        if tmd == 2 { r.position += 5 }  // OTM
        var list: [Language] = []
        let count = Int(try r.next())
        for _ in 0..<count {
            let b = try r.next()
            let tag = Int(b >> 5), dmf = b & 0x0F
            if (0x0C...0x0E).contains(dmf) { _ = try r.next() }  // DC
            let code = String(decoding: [try r.next(), try r.next(), try r.next()], as: UTF8.self)
            let c = try r.next()
            list.append(Language(tag: tag, code: code, format: Int(c >> 4) - 1, isEightBitCode: (c >> 2) & 3 == 0))
        }
        let units = try dataUnits(&r)
        languages = list.sorted { $0.tag < $1.tag }
        managementDRCS = [:]
        for unit in units { unit.addDRCS(to: &managementDRCS) }
        managementItems = []
        if let first = languages.first, first.isEightBitCode {
            managementItems = try decode(units, language: first, drcs: managementDRCS, items: [])
        }
    }

    private func parseStatement(_ data: [UInt8], language: Language) throws -> [CaptionItem] {
        guard language.isEightBitCode, ARIBCaptionDecoder.isSupported(format: language.format) else { return [] }
        var r = ByteReader(data)
        let tmd = try r.next() >> 6
        if tmd == 1 || tmd == 2 { r.position += 5 }  // STM
        let units = try dataUnits(&r)
        var drcs = managementDRCS
        for unit in units { unit.addDRCS(to: &drcs) }
        return try decode(units, language: language, drcs: drcs, items: managementItems)
    }

    private func decode(_ units: [DataUnit], language: Language, drcs: [UInt16: [DRCSGlyph]], items: [CaptionItem]) throws -> [CaptionItem] {
        guard ARIBCaptionDecoder.isSupported(format: language.format) else { return [] }
        let decoder = ARIBCaptionDecoder(format: language.format, drcs: drcs, items: items)
        var last: CaptionPlaneArea?
        var bitmaps: [(position: Int, item: CaptionItem)] = []
        for unit in units {
            switch unit.parameter {
            case 0x20 where !unit.data.isEmpty:
                try decoder.decode(unit.data)
                for case .row(let row) in decoder.items.reversed() {
                    last = row.area
                    break
                }
            case 0x35:
                let area = last ?? defaultArea(format: language.format)
                if let bitmap = CaptionStream.parseBitmap(unit.data, area: area, wait: decoder.items.last?.wait ?? 0) {
                    bitmaps.append((decoder.items.count, .bitmap(bitmap)))
                }
            default:
                break
            }
        }
        var result = decoder.items
        for bitmap in bitmaps.reversed() { result.insert(bitmap.item, at: bitmap.position) }
        return result
    }

    private func defaultArea(format: Int) -> CaptionPlaneArea {
        var area = CaptionPlaneArea(format: format, x: 0, y: 0, width: 0, height: 0)
        area.width = Int(area.planeSize.width)
        area.height = Int(area.planeSize.height)
        return area
    }

    private struct DataUnit {
        let parameter: UInt8
        let data: [UInt8]

        func addDRCS(to glyphs: inout [UInt16: [DRCSGlyph]]) {
            guard parameter == 0x30 || parameter == 0x31 else { return }
            CaptionStream.parseDRCS(data, twoBytes: parameter == 0x31, into: &glyphs)
        }
    }

    private func dataUnits(_ r: inout ByteReader) throws -> [DataUnit] {
        let length = Int(try r.next()) << 16 | Int(try r.next()) << 8 | Int(try r.next())
        let end = min(r.position + length, r.bytes.count)
        var units: [DataUnit] = []
        while r.position + 5 <= end {
            guard try r.next() == 0x1F else { throw InvalidCaptionData() }
            let parameter = try r.next()
            let size = Int(try r.next()) << 16 | Int(try r.next()) << 8 | Int(try r.next())
            guard r.position + size <= end else { throw InvalidCaptionData() }
            units.append(DataUnit(parameter: parameter, data: Array(r.bytes[r.position..<(r.position + size)])))
            r.position += size
        }
        return units
    }

    // MARK: - DRCS

    /// Patterns of an unsupported kind end the unit: what came before it stays usable.
    private static func parseDRCS(_ data: [UInt8], twoBytes: Bool, into glyphs: inout [UInt16: [DRCSGlyph]]) {
        var r = ByteReader(data)
        do {
            for _ in 0..<Int(try r.next()) {
                let first = try r.next(), second = try r.next()
                let code = twoBytes ? UInt16(first) << 8 | UInt16(second) : UInt16(first &- 0x40) << 8 | UInt16(second)
                for _ in 0..<Int(try r.next()) {
                    let mode = try r.next() & 0x0F, depth = try r.next()
                    let width = Int(try r.next()), height = Int(try r.next())
                    guard (mode == 0 && depth == 0) || (mode == 1 && depth == 2), width <= 36, height <= 36 else { return }
                    let bits = depth == 0 ? 1 : 2
                    let size = (width * height * bits + 7) / 8
                    guard r.position + size <= r.bytes.count else { return }
                    let packed = Array(r.bytes[r.position..<(r.position + size)])
                    r.position += size
                    glyphs[code, default: []].append(glyph(packed, width: width, height: height, bits: bits))
                }
            }
        } catch {}
    }

    private static func glyph(_ packed: [UInt8], width: Int, height: Int, bits: Int) -> DRCSGlyph {
        func pixel(_ i: Int) -> UInt8 {
            bits == 1 ? (packed[i / 8] >> (7 - i % 8)) & 1 : (packed[i / 4] >> ((3 - i % 4) * 2)) & 3
        }
        let top: UInt8 = bits == 1 ? 1 : 3
        var coverage = [UInt8](repeating: 0, count: width * height)
        for i in coverage.indices { coverage[i] = UInt8(Int(pixel(i)) * 255 / Int(top)) }
        return DRCSGlyph(width: width, height: height, coverage: coverage,
                         replacement: replacement(packed, pixel: pixel, width: width, height: height, bits: bits))
    }

    /// The table was made from the patterns as they were sent, and from the same 4-level patterns
    /// shifted two pixels to either side (the broadcasters' fonts are not all centered alike).
    private static func replacement(_ packed: [UInt8], pixel: (Int) -> UInt8, width: Int, height: Int, bits: Int) -> String? {
        if let text = ARIBTables.drcsReplacements[md5(packed)] { return text }
        guard bits == 2, width >= 2 else { return nil }
        for shift in [2, -2] {
            guard let shifted = shiftedPattern(pixel, width: width, height: height, by: shift) else { continue }
            if let text = ARIBTables.drcsReplacements[md5(shifted)] { return text }
        }
        return nil
    }

    private static func shiftedPattern(_ pixel: (Int) -> UInt8, width: Int, height: Int, by shift: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: (width * height + 3) / 4)
        for y in 0..<height {
            for x in 0..<width {
                let p = pixel(y * width + x)
                let to = x + shift
                guard to >= 0, to < width else {
                    if p != 0 { return nil }  // would fall off the edge
                    continue
                }
                let i = y * width + to
                out[i / 4] |= p << ((3 - i % 4) * 2)
            }
        }
        return out
    }

    private static func md5(_ bytes: [UInt8]) -> String {
        Insecure.MD5.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Pictures

    private static let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52]

    /// A picture comes as a PNG without a palette: the palette is the caption color map.
    private static func parseBitmap(_ data: [UInt8], area: CaptionPlaneArea, wait: Int) -> CaptionBitmap? {
        guard data.count >= 5 else { return nil }
        let x = Int(Int16(truncatingIfNeeded: Int(data[0]) << 8 | Int(data[1])))
        let y = Int(Int16(truncatingIfNeeded: Int(data[2]) << 8 | Int(data[3])))
        let flashCount = Int(data[4])
        let start = 5 + flashCount
        guard data.count >= start + 33 else { return nil }
        let png = Array(data[start...])
        guard Array(png[..<16]) == pngHeader, png[25] == 3, [1, 2, 4, 8].contains(png[24]) else { return nil }

        let alpha = ARIBTables.palette.map(\.3)
        var flashingAlpha = alpha
        for index in data[5..<start] where Int(index) < flashingAlpha.count { flashingAlpha[Int(index)] = 0 }
        guard let image = decodePNG(png, alpha: alpha) else { return nil }
        let flashing = flashCount > 0 ? decodePNG(png, alpha: flashingAlpha) : nil
        return CaptionBitmap(wait: wait, area: area, x: x, y: y, image: image, flashing: flashing)
    }

    private static func decodePNG(_ png: [UInt8], alpha: [UInt8]) -> CGImage? {
        var out = Array(png[..<33])
        out += chunk("PLTE", ARIBTables.palette.flatMap { [$0.0, $0.1, $0.2] })
        out += chunk("tRNS", alpha)
        out += png[33...]
        guard let source = CGImageSourceCreateWithData(Data(out) as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let named = Array(type.utf8) + body
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in named {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 }
        }
        crc = ~crc
        func bigEndian(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }
        return bigEndian(UInt32(body.count)) + named + bigEndian(crc)
    }
}
