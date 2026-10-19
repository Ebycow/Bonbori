// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct Channel: Codable, Hashable {
    var group: String        // BonDriverProxyEx group, e.g. "BonDriver-T"
    var space: Int
    var channel: Int         // BonDriver channel index
    var spaceName: String
    var channelName: String  // "17Ch", "BS01/TS0"...
    var sid: Int
    var name: String
    var serviceType: Int
    var remoteKey: Int
    var tsName: String
    var onid: Int
    var tsid: Int
    var signal: Double? = nil

    var id: String { "\(group)/\(space)/\(channel)/\(sid)" }
    func sameTS(_ o: Channel) -> Bool { o.group == group && o.space == space && o.channel == channel }

    var kind: SpaceKind {
        if group.hasSuffix("T") || spaceName.contains("地デジ") || spaceName.contains("UHF") { return .terrestrial }
        if spaceName.uppercased().hasPrefix("BS") { return .bs }
        return .cs
    }
}

enum SpaceKind: Int, CaseIterable {
    case terrestrial, bs, cs
    var title: String {
        switch self {
        case .terrestrial: return "地デジ"
        case .bs: return "BS"
        case .cs: return "CS"
        }
    }
}

struct ServicesEvent: Decodable {
    struct Service: Decodable { let sid: Int; let type: Int; let name: String }
    let onid: Int
    let tsid: Int
    let nid: Int
    let remote_key: Int
    let complete: Bool
    let tsname: String
    let network: String
    let services: [Service]
    let pat: [Int]
}

struct ProgramEvent: Decodable {
    struct Event: Decodable {
        let event_id: Int
        let start: Int64
        let duration: Int
        let title: String
        let text: String
    }
    let sid: Int
    let present: Event?
    let following: Event?
}

struct StatusEvent: Decodable {
    let signal: Double
    let bitrate: Double
    let packets: UInt64
    let scrambled: UInt64
    let drops: UInt64
    let errors: UInt64
    let vqueue: Int
    let aqueue: Int
}

struct StreamEvent: Decodable {
    let sid: Int
    let video: String
    let audio: String
    let audio_count: Int
    let audio_index: Int
}

struct FormatEvent: Decodable {
    let kind: String
    let codec: String
    let width: Int?
    let height: Int?
    let sar_num: Int?
    let sar_den: Int?
    let interlaced: Bool?
    let channels: Int?
    let rate: Int?
    let layout: String?
}

struct TunedEvent: Decodable {
    let ok: Bool
    let result: Int
    let ms: Int
    let gen: Int
}

let appName = "Bonbori"

/// Debug/test switch from the environment: BONBORI_<name>, or the former ITV_<name>.
func envVar(_ name: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    return env["BONBORI_" + name] ?? env["ITV_" + name]
}

/// ~/Library/Application Support/Bonbori (created on demand).
func appSupportDir() -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(appName, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Persistent settings.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var host: String {
        get { d.string(forKey: "host") ?? "" }
        set { d.set(newValue, forKey: "host") }
    }
    var port: Int {
        get { let p = d.integer(forKey: "port"); return p == 0 ? 1192 : p }
        set { d.set(newValue, forKey: "port") }
    }
    var groups: [String] {
        get { d.stringArray(forKey: "groups") ?? ["BonDriver-T", "BonDriver-S"] }
        set { d.set(newValue, forKey: "groups") }
    }
    var lastChannelID: String? {
        get { d.string(forKey: "lastChannel") }
        set { d.set(newValue, forKey: "lastChannel") }
    }
    var volume: Float {
        get { d.object(forKey: "volume") == nil ? 1.0 : d.float(forKey: "volume") }
        set { d.set(newValue, forKey: "volume") }
    }
    var deinterlace: Bool {
        get { d.object(forKey: "deinterlace") == nil ? true : d.bool(forKey: "deinterlace") }
        set { d.set(newValue, forKey: "deinterlace") }
    }
    /// Keep the display awake while watching.
    var preventSleep: Bool {
        get { d.object(forKey: "preventSleep") == nil ? true : d.bool(forKey: "preventSleep") }
        set { d.set(newValue, forKey: "preventSleep") }
    }
    /// 翻訳字幕 (English speech recognized and translated into Japanese).
    var subtitles: Bool {
        get { d.bool(forKey: "subtitles") }
        set { d.set(newValue, forKey: "subtitles") }
    }
    /// Hold the picture back so that subtitles appear with the speech (otherwise they come late).
    var subtitleSync: Bool {
        get { d.bool(forKey: "subtitleSync") }
        set { d.set(newValue, forKey: "subtitleSync") }
    }
    /// Seconds the picture is held back when subtitleSync is on.
    var subtitleDelay: Double {
        get { d.object(forKey: "subtitleDelay") == nil ? 8 : d.double(forKey: "subtitleDelay") }
        set { d.set(newValue, forKey: "subtitleDelay") }
    }
    /// Audio to recognize: 0 = auto (副音声 for dual-mono programs, else both), 1 = 主 (left), 2 = 副 (right), 3 = both mixed.
    var subtitleSource: Int {
        get { d.integer(forKey: "subtitleSource") }
        set { d.set(newValue, forKey: "subtitleSource") }
    }
    /// Show the recognized English under the translation.
    var subtitleShowOriginal: Bool {
        get { d.object(forKey: "subtitleShowOriginal") == nil ? true : d.bool(forKey: "subtitleShowOriginal") }
        set { d.set(newValue, forKey: "subtitleShowOriginal") }
    }
    /// Include terrestrial/BS sub-channels (e.g. NHK総合2) when zapping.
    var showSubChannels: Bool {
        get { d.bool(forKey: "showSubChannels") }
        set { d.set(newValue, forKey: "showSubChannels") }
    }
    /// Ask BonDriverProxyEx to descramble on the server (eDesireToUseB25).
    var serverB25: Bool {
        get { d.object(forKey: "serverB25") == nil ? true : d.bool(forKey: "serverB25") }
        set { d.set(newValue, forKey: "serverB25") }
    }
    /// Presentation delay behind the broadcast clock (seconds).
    var latency: Double {
        get { d.object(forKey: "latency") == nil ? 1.0 : d.double(forKey: "latency") }
        set { d.set(newValue, forKey: "latency") }
    }
}

/// Channel list persistence (~/Library/Application Support/Bonbori/channels.json).
final class ChannelStore {
    static let shared = ChannelStore()
    private(set) var channels: [Channel] = []

    private var url: URL {
        appSupportDir().appendingPathComponent("channels.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Channel].self, from: data) else { return }
        channels = Player.dedupe(list)
    }

    func replace(group: String, with list: [Channel]) {
        channels.removeAll { $0.group == group }
        channels.append(contentsOf: list)
        save()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(channels) { try? data.write(to: url) }
    }

    static func isTV(_ c: Channel) -> Bool { [0x01, 0xA5, 0xAD].contains(c.serviceType) }

    /// Channels used for zapping: TV services, without sub-channels (the lowest service id of a
    /// terrestrial/BS TS is the main channel; CS transponders carry independent channels).
    var tvChannels: [Channel] {
        // Match TVTest's default scan sort: terrestrial remote-control key, BS/CS service ID.
        let tv = channels.filter(ChannelStore.isTV).sorted { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.kind == .terrestrial && a.remoteKey != b.remoteKey {
                return a.remoteKey < b.remoteKey
            }
            return a.sid < b.sid
        }
        if Settings.shared.showSubChannels { return tv }
        var mainSid: [String: Int] = [:]
        for c in tv where c.kind != .cs {
            let k = "\(c.group)/\(c.space)/\(c.channel)"
            mainSid[k] = min(mainSid[k] ?? Int.max, c.sid)
        }
        return tv.filter { c in
            c.kind == .cs || mainSid["\(c.group)/\(c.space)/\(c.channel)"] == c.sid
        }
    }

    func channels(of kind: SpaceKind) -> [Channel] {
        tvChannels.filter { $0.kind == kind }
    }

    func find(id: String) -> Channel? { channels.first { $0.id == id } }
}

/// Remote-control key for BS services (the TS information descriptor is terrestrial only).
func bsRemoteKey(sid: Int) -> Int {
    switch sid {
    case 101: return 1
    case 103: return 3
    case 141: return 4
    case 151: return 5
    case 161: return 6
    case 171: return 7
    case 181: return 8
    case 191: return 9
    case 192: return 10
    case 193: return 11
    case 211: return 12
    default: return 0
    }
}

func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
    try? JSONDecoder().decode(type, from: Data(json.utf8))
}

private let debugTimeFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = .current
    return f
}()

/// BONBORI_DEBUG log line on stderr, prefixed with the local time: "[tag 2026-10-10T09:45:12.345+09:00] ..."
func debugLog(_ tag: String, _ s: String) {
    let line = "[\(tag) \(debugTimeFormatter.string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}
