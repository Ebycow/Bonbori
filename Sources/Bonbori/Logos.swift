// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TVCore

extension Notification.Name {
    /// New logos, or new logo ids for services, have been received (posted on the main thread).
    static let logosChanged = Notification.Name("BonboriLogosChanged")
}

/// Station logos, collected from the broadcast while watching. Terrestrial: the SDT gives each
/// service a logo id, and the CDT carries the PNG of each id, every few minutes. BS/CS: the
/// engineering service's 全受信機共通データ carries the PNGs with their services, at certain times.
/// Kept in Application Support/Bonbori/logos as `<onid>_<logo id>_<logo type>.png`, with the
/// service → logo id map in logos.json.
final class LogoStore {
    static let shared = LogoStore()

    private struct Index: Codable {
        var services: [String: Int] = [:]  // "onid/sid" -> logo id
        var versions: [String: Int] = [:]  // file name -> logo version
    }

    private struct LogoEvent: Decodable {
        let onid: Int
        let id: Int
        let type: Int
        let ver: Int
        let png: String
    }

    private struct ServiceLogosEvent: Decodable {
        /// `onid` is given when it differs from the event's (logos of 全受信機共通データ).
        struct Service: Decodable { let onid: Int?; let sid: Int; let logo: Int }
        let onid: Int
        let tsid: Int
        let services: [Service]
    }

    /// Logo types by preference, as TVTest's large logo: HD large (64x36), SD 4:3 large (72x36),
    /// SD 16:9 large (54x36), HD small (48x27), SD 4:3 small (48x24), SD 16:9 small (36x24).
    private static let typePreference = [5, 3, 4, 2, 0, 1]

    private let dir: URL
    private let queue = DispatchQueue(label: "bonbori.logos")
    private var index = Index()  // on `queue`
    private var dirty = false
    private var notifyPending = false

    // Main thread.
    private var mainIndex = Index()
    private var images: [String: NSImage?] = [:]

    private init() {
        dir = appSupportDir().appendingPathComponent("logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let i = try? JSONDecoder().decode(Index.self, from: data) {
            index = i
            mainIndex = i
        }
    }

    private var indexURL: URL { dir.appendingPathComponent("logos.json") }

    // MARK: - Receiving (TVCore threads)

    func ingest(type: Int32, json: String) {
        queue.async { [self] in
            if type == Int32(TV_EV_LOGO.rawValue), let ev = decode(LogoEvent.self, json) {
                store(ev)
            } else if type == Int32(TV_EV_SERVICE_LOGOS.rawValue), let ev = decode(ServiceLogosEvent.self, json) {
                for s in ev.services {
                    let key = "\(s.onid ?? ev.onid)/\(s.sid)"
                    if index.services[key] != s.logo {
                        index.services[key] = s.logo
                        changed()
                    }
                }
            }
        }
    }

    private func store(_ ev: LogoEvent) {
        let name = "\(ev.onid)_\(ev.id)_\(ev.type).png"
        let url = dir.appendingPathComponent(name)
        if index.versions[name] == ev.ver, FileManager.default.fileExists(atPath: url.path) { return }
        guard let raw = Data(base64Encoded: ev.png), let png = LogoStore.withDefaultPalette(raw) else { return }
        do { try png.write(to: url) } catch { return }
        index.versions[name] = ev.ver
        changed()
    }

    /// Saves the index and tells the main thread, at most once a second.
    private func changed() {
        dirty = true
        guard !notifyPending else { return }
        notifyPending = true
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            notifyPending = false
            guard dirty else { return }
            dirty = false
            let snapshot = index
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(snapshot) { try? data.write(to: indexURL) }
            DispatchQueue.main.async { [self] in
                mainIndex = snapshot
                images = [:]
                NotificationCenter.default.post(name: .logosChanged, object: nil)
            }
        }
    }

    // MARK: - Lookup (main thread)

    func image(for ch: Channel) -> NSImage? {
        let key = "\(ch.onid)/\(ch.sid)"
        if let cached = images[key] { return cached }
        var img: NSImage?
        if let id = mainIndex.services[key] {
            for t in LogoStore.typePreference {
                let url = dir.appendingPathComponent("\(ch.onid)_\(id)_\(t).png")
                if let i = NSImage(contentsOf: url) {
                    img = i
                    break
                }
            }
        }
        images[key] = img
        return img
    }

    // MARK: - PNG

    /// The broadcast PNGs are indexed colour without a PLTE chunk: their colours are the ARIB default
    /// CLUT. Adds it (and its alpha as tRNS) after the IHDR so that ordinary decoders can read them.
    static func withDefaultPalette(_ png: Data) -> Data? {
        let b = [UInt8](png)
        guard b.count > 33, b[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        var chunks: [(type: String, start: Int, end: Int)] = []
        var i = 8
        while i + 12 <= b.count {
            let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let end = i + 12 + len
            guard end <= b.count else { break }
            chunks.append((String(bytes: b[i + 4..<i + 8], encoding: .ascii) ?? "", i, end))
            i = end
        }
        guard let ihdr = chunks.first, ihdr.type == "IHDR", b[ihdr.start + 8 + 9] == 3,
              !chunks.contains(where: { $0.type == "PLTE" }) else { return png }
        // As many entries as the bit depth allows: the CLUT has 128, and the indexes above it are
        // transparent (TVTest draws them as color 8).
        let depth = Int(b[ihdr.start + 8 + 8])
        let count = 1 << min(depth, 8)
        let colors = (0..<count).map { $0 < defaultCLUT.count ? defaultCLUT[$0] : defaultCLUT[8] }
        let plte = colors.flatMap { [$0.0, $0.1, $0.2] }
        let trns = colors.map(\.3)
        var out = Data(b[0..<ihdr.end])
        out.append(chunk("PLTE", plte))
        if !chunks.contains(where: { $0.type == "tRNS" }) { out.append(chunk("tRNS", trns)) }
        out.append(contentsOf: b[ihdr.end...])
        return out
    }

    private static func chunk(_ type: String, _ data: [UInt8]) -> Data {
        var c = Data()
        let n = UInt32(data.count)
        c.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        let body = Array(type.utf8) + data
        c.append(contentsOf: body)
        let crc = crc32(body)
        c.append(contentsOf: [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        return c
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in bytes { c = crcTable[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// ARIB STD-B24 default CLUT (the same as the captions' palette): red, green, blue, alpha.
    private static let defaultCLUT: [(UInt8, UInt8, UInt8, UInt8)] = [
        (0, 0, 0, 255), (255, 0, 0, 255), (0, 255, 0, 255), (255, 255, 0, 255),
        (0, 0, 255, 255), (255, 0, 255, 255), (0, 255, 255, 255), (255, 255, 255, 255),
        (0, 0, 0, 0), (170, 0, 0, 255), (0, 170, 0, 255), (170, 170, 0, 255),
        (0, 0, 170, 255), (170, 0, 170, 255), (0, 170, 170, 255), (170, 170, 170, 255),
        (0, 0, 85, 255), (0, 85, 0, 255), (0, 85, 85, 255), (0, 85, 170, 255),
        (0, 85, 255, 255), (0, 170, 85, 255), (0, 170, 255, 255), (0, 255, 85, 255),
        (0, 255, 170, 255), (85, 0, 0, 255), (85, 0, 85, 255), (85, 0, 170, 255),
        (85, 0, 255, 255), (85, 85, 0, 255), (85, 85, 85, 255), (85, 85, 170, 255),
        (85, 85, 255, 255), (85, 170, 0, 255), (85, 170, 85, 255), (85, 170, 170, 255),
        (85, 170, 255, 255), (85, 255, 0, 255), (85, 255, 85, 255), (85, 255, 170, 255),
        (85, 255, 255, 255), (170, 0, 85, 255), (170, 0, 255, 255), (170, 85, 0, 255),
        (170, 85, 85, 255), (170, 85, 170, 255), (170, 85, 255, 255), (170, 170, 85, 255),
        (170, 170, 255, 255), (170, 255, 0, 255), (170, 255, 85, 255), (170, 255, 170, 255),
        (170, 255, 255, 255), (255, 0, 85, 255), (255, 0, 170, 255), (255, 85, 0, 255),
        (255, 85, 85, 255), (255, 85, 170, 255), (255, 85, 255, 255), (255, 170, 0, 255),
        (255, 170, 85, 255), (255, 170, 170, 255), (255, 170, 255, 255), (255, 255, 85, 255),
        (255, 255, 170, 255), (0, 0, 0, 128), (255, 0, 0, 128), (0, 255, 0, 128),
        (255, 255, 0, 128), (0, 0, 255, 128), (255, 0, 255, 128), (0, 255, 255, 128),
        (255, 255, 255, 128), (170, 0, 0, 128), (0, 170, 0, 128), (170, 170, 0, 128),
        (0, 0, 170, 128), (170, 0, 170, 128), (0, 170, 170, 128), (170, 170, 170, 128),
        (0, 0, 85, 128), (0, 85, 0, 128), (0, 85, 85, 128), (0, 85, 170, 128),
        (0, 85, 255, 128), (0, 170, 85, 128), (0, 170, 255, 128), (0, 255, 85, 128),
        (0, 255, 170, 128), (85, 0, 0, 128), (85, 0, 85, 128), (85, 0, 170, 128),
        (85, 0, 255, 128), (85, 85, 0, 128), (85, 85, 85, 128), (85, 85, 170, 128),
        (85, 85, 255, 128), (85, 170, 0, 128), (85, 170, 85, 128), (85, 170, 170, 128),
        (85, 170, 255, 128), (85, 255, 0, 128), (85, 255, 85, 128), (85, 255, 170, 128),
        (85, 255, 255, 128), (170, 0, 85, 128), (170, 0, 255, 128), (170, 85, 0, 128),
        (170, 85, 85, 128), (170, 85, 170, 128), (170, 85, 255, 128), (170, 170, 85, 128),
        (170, 170, 255, 128), (170, 255, 0, 128), (170, 255, 85, 128), (170, 255, 170, 128),
        (170, 255, 255, 128), (255, 0, 85, 128), (255, 0, 170, 128), (255, 85, 0, 128),
        (255, 85, 85, 128), (255, 85, 170, 128), (255, 85, 255, 128), (255, 170, 0, 128),
        (255, 170, 85, 128), (255, 170, 170, 128), (255, 170, 255, 128), (255, 255, 85, 128),
    ]
}
