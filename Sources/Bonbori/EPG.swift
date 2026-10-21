// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// One program from the EIT (p/f or schedule).
struct EPGEvent: Codable, Hashable {
    var id: Int
    var start: Int64          // unix seconds
    var duration: Int         // seconds, -1 = undecided
    var title: String
    var text: String
    var genres: [Int]         // content descriptor: level1 << 4 | level2
    var extended: [[String]]  // extended event items: [item, text]
    var group: [[Int]]        // shared ("common") event: [service id, event id]
    var video: Int?           // component_type of the video component
    var audio: [Int]
    var freeCA: Bool

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    var endDate: Date { startDate.addingTimeInterval(TimeInterval(max(duration, 0))) }
    var end: Int64 { start + Int64(max(duration, 0)) }

    /// First genre that is not the "extension" (0xE) code.
    var mainGenre: Genre? {
        genres.lazy.map { $0 >> 4 }.first { $0 != 0xE }.flatMap(Genre.init(rawValue:))
    }

    func isOnAir(at now: Date = Date()) -> Bool {
        let t = Int64(now.timeIntervalSince1970)
        return start <= t && (duration < 0 ? t < start + 3600 : t < end)
    }

    /// Whether the program guide's search finds this program.
    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query) || text.localizedCaseInsensitiveContains(query)
    }
}

/// ARIB STD-B10 content_nibble_level_1 (names from TVTest's EpgUtil).
enum Genre: Int, CaseIterable {
    case news, sports, information, drama, music, variety, movie, anime
    case documentary, theater, hobby, welfare
    case other = 15

    var name: String { Genre.table[rawValue]?.0 ?? "その他" }

    static func subName(_ code: Int) -> String? {
        guard let t = table[code >> 4] else { return nil }
        let sub = t.1[code & 0x0F]
        return sub.isEmpty ? nil : sub
    }

    /// Calendar-style tint. System colors adapt to light/dark mode and the accessibility settings.
    var color: NSColor {
        switch self {
        case .news: return .systemYellow
        case .sports: return .systemBlue
        case .information: return .systemPink
        case .drama: return .systemRed
        case .music: return .systemGreen
        case .variety: return .systemTeal
        case .movie: return .systemOrange
        case .anime: return .systemPurple
        case .documentary: return .systemBrown
        case .theater: return .systemOrange
        case .hobby: return .systemIndigo
        case .welfare: return .systemMint
        case .other: return .systemGray
        }
    }

    private static let table: [Int: (String, [String])] = [
        0x0: ("ニュース／報道", ["定時・総合", "天気", "特集・ドキュメント", "政治・国会", "経済・市況", "海外・国際", "解説", "討論・会談", "報道特番", "ローカル・地域", "交通", "", "", "", "", "その他"]),
        0x1: ("スポーツ", ["スポーツニュース", "野球", "サッカー", "ゴルフ", "その他の球技", "相撲・格闘技", "オリンピック・国際大会", "マラソン・陸上・水泳", "モータースポーツ", "マリン・ウィンタースポーツ", "競馬・公営競技", "", "", "", "", "その他"]),
        0x2: ("情報／ワイドショー", ["芸能・ワイドショー", "ファッション", "暮らし・住まい", "健康・医療", "ショッピング・通販", "グルメ・料理", "イベント", "番組紹介・お知らせ", "", "", "", "", "", "", "", "その他"]),
        0x3: ("ドラマ", ["国内ドラマ", "海外ドラマ", "時代劇", "", "", "", "", "", "", "", "", "", "", "", "", "その他"]),
        0x4: ("音楽", ["国内ロック・ポップス", "海外ロック・ポップス", "クラシック・オペラ", "ジャズ・フュージョン", "歌謡曲・演歌", "ライブ・コンサート", "ランキング・リクエスト", "カラオケ・のど自慢", "民謡・邦楽", "童謡・キッズ", "民族音楽・ワールドミュージック", "", "", "", "", "その他"]),
        0x5: ("バラエティ", ["クイズ", "ゲーム", "トークバラエティ", "お笑い・コメディ", "音楽バラエティ", "旅バラエティ", "料理バラエティ", "", "", "", "", "", "", "", "", "その他"]),
        0x6: ("映画", ["洋画", "邦画", "アニメ", "", "", "", "", "", "", "", "", "", "", "", "", "その他"]),
        0x7: ("アニメ／特撮", ["国内アニメ", "海外アニメ", "特撮", "", "", "", "", "", "", "", "", "", "", "", "", "その他"]),
        0x8: ("ドキュメンタリー／教養", ["社会・時事", "歴史・紀行", "自然・動物・環境", "宇宙・科学・医学", "カルチャー・伝統文化", "文学・文芸", "スポーツ", "ドキュメンタリー全般", "インタビュー・討論", "", "", "", "", "", "", "その他"]),
        0x9: ("劇場／公演", ["現代劇・新劇", "ミュージカル", "ダンス・バレエ", "落語・演芸", "歌舞伎・古典", "", "", "", "", "", "", "", "", "", "", "その他"]),
        0xA: ("趣味／教育", ["旅・釣り・アウトドア", "園芸・ペット・手芸", "音楽・美術・工芸", "囲碁・将棋", "麻雀・パチンコ", "車・オートバイ", "コンピュータ・TVゲーム", "会話・語学", "幼児・小学生", "中学生・高校生", "大学生・受験", "生涯学習・資格", "教育問題", "", "", "その他"]),
        0xB: ("福祉", ["高齢者", "障害者", "社会福祉", "ボランティア", "手話", "文字(字幕)", "音声解説", "", "", "", "", "", "", "", "", "その他"]),
        0xF: ("その他", ["", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "その他"]),
    ]
}

/// Broadcast time helpers. Programs are scheduled in JST regardless of the Mac's time zone.
enum BroadcastTime {
    static let zone = TimeZone(identifier: "Asia/Tokyo")!
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.locale = Locale(identifier: "ja_JP")
        return c
    }()
    /// The broadcast day starts at 4:00 (the guide shows 4:00 – 28:00).
    static let dayStartHour = 4

    static func dayStart(containing date: Date) -> Date {
        let shifted = date.addingTimeInterval(-TimeInterval(dayStartHour * 3600))
        let midnight = calendar.startOfDay(for: shifted)
        return midnight.addingTimeInterval(TimeInterval(dayStartHour * 3600))
    }

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = zone
        f.dateFormat = format
        return f
    }
}

/// Section bookkeeping of the EIT schedule of one service, to tell when it has been received
/// completely (port of LibISDB's EPGDatabase::ScheduleInfo).
struct ScheduleTables {
    private struct Segment { var count = 0; var flags = 0 }
    private struct Table {
        var version = -1
        var complete = false
        var segments = [Segment](repeating: Segment(), count: 32)
    }
    private(set) var tableCount = 0
    private var tables = [Table](repeating: Table(), count: 8)

    var hasSchedule: Bool { tableCount > 0 }

    mutating func onSection(tid: Int, lastTid: Int, section: Int, segmentLast: Int, version: Int, hour: Int) {
        let firstTid = lastTid & 0xF8, firstSection = segmentLast & 0xF8
        guard tid >= firstTid, tid <= lastTid, section >= firstSection, section <= segmentLast else { return }
        let count = lastTid - firstTid + 1
        let index = tid & 0x07
        if tableCount != count {
            tableCount = count
            tables = [Table](repeating: Table(), count: 8)
            tables[index].version = version
        } else if tables[index].version != version {
            tables[index] = Table()
            tables[index].version = version
        }
        let si = section >> 3
        let sectionCount = segmentLast - firstSection + 1
        if tables[index].segments[si].count != sectionCount {
            tables[index].segments[si] = Segment(count: sectionCount, flags: 0)
        }
        let flag = 1 << (section & 0x07)
        if tables[index].segments[si].flags & flag == 0 {
            tables[index].segments[si].flags |= flag
            if tables[index].segments[si].flags == (1 << sectionCount) - 1 {
                tables[index].complete = isTableComplete(index, hour: hour)
            }
        }
    }

    /// Table 0 only needs the segments from the current 3-hour block on.
    private func isTableComplete(_ index: Int, hour: Int) -> Bool {
        guard index < tableCount else { return false }
        for seg in tables[index].segments[(index == 0 ? hour / 3 : 0)...] {
            if seg.count == 0 || seg.flags != (1 << seg.count) - 1 { return false }
        }
        return true
    }

    func isComplete(hour: Int) -> Bool {
        guard tableCount > 0 else { return false }
        if !tables[0].complete && !isTableComplete(0, hour: hour) { return false }
        return tables[1..<tableCount].allSatisfy(\.complete)
    }
}

struct ScheduleStatus {
    var hasBasic = false, basicComplete = false
    var hasExtended = false, extendedComplete = false
}

/// The program database, fed with every EIT section the demultiplexer sees (while watching and
/// while patrolling channels), kept in ~/Library/Application Support/Bonbori/epg.json.
final class EPGStore {
    static let shared = EPGStore()
    static let didChange = Notification.Name("EPGStoreDidChange")

    private struct Service {
        var events: [Int: EPGEvent] = [:]
        var pendingExtended: [Int: [[String]]] = [:]  // extended items that came before the event
        var basic = ScheduleTables()
        var extended = ScheduleTables()
    }

    private struct Section: Decodable {
        struct Event: Decodable {
            let id: Int
            let start: Int64
            let dur: Int
            let ca: Int
            let title: String?
            let text: String?
            let genre: [Int]?
            let ext: [[String]]?
            let group: [[Int]]?
            let video: Int?
            let audio: [Int]?
        }
        let onid, tsid, sid, tid, ver, sec, seg_last, last_tid: Int
        let events: [Event]
    }

    private let q = DispatchQueue(label: "tv.epg", qos: .utility)
    private var services: [Int: Service] = [:]
    private var dirty = false
    private var notifyPending = false
    private var lastSave = Date()

    private var url: URL {
        appSupportDir().appendingPathComponent("epg.json")
    }

    static func key(onid: Int, sid: Int) -> Int { onid << 16 | sid }

    private init() {
        q.async { self.load() }
    }

    // MARK: - Input (network thread)

    func ingest(_ json: String) {
        q.async { self.apply(json) }
    }

    private func apply(_ json: String) {
        guard let s = decode(Section.self, json) else { return }
        let key = EPGStore.key(onid: s.onid, sid: s.sid)
        var svc = services[key] ?? Service()
        let isSchedule = s.tid >= 0x50
        let isExtendedTable = isSchedule && s.tid & 0x08 != 0

        for e in s.events where e.start > 0 {
            if isExtendedTable {
                // extended tables carry only the extended event descriptor
                guard let ext = e.ext, !ext.isEmpty else { continue }
                if svc.events[e.id] != nil {
                    svc.events[e.id]!.extended = ext
                } else {
                    svc.pendingExtended[e.id] = ext
                }
                continue
            }
            var ev = EPGEvent(id: e.id, start: e.start, duration: e.dur, title: e.title ?? "", text: e.text ?? "",
                              genres: e.genre ?? [], extended: e.ext ?? [], group: e.group ?? [],
                              video: e.video, audio: e.audio ?? [], freeCA: e.ca != 0)
            if ev.extended.isEmpty {
                ev.extended = svc.pendingExtended.removeValue(forKey: e.id) ?? svc.events[e.id]?.extended ?? []
            }
            if ev.duration > 0 {
                // a rescheduled program replaces whatever was planned in its time slot
                let overlapping = svc.events.values.filter {
                    $0.id != ev.id && $0.start < ev.end && ($0.duration < 0 ? $0.start >= ev.start : $0.end > ev.start)
                }
                for o in overlapping { svc.events[o.id] = nil }
            }
            svc.events[e.id] = ev
        }
        if isSchedule {
            let hour = BroadcastTime.calendar.component(.hour, from: Date())
            if isExtendedTable {
                svc.extended.onSection(tid: s.tid, lastTid: s.last_tid, section: s.sec, segmentLast: s.seg_last, version: s.ver, hour: hour)
            } else {
                svc.basic.onSection(tid: s.tid, lastTid: s.last_tid, section: s.sec, segmentLast: s.seg_last, version: s.ver, hour: hour)
            }
        }
        services[key] = svc
        changed()
    }

    private func changed() {
        dirty = true
        guard !notifyPending else { return }
        notifyPending = true
        q.asyncAfter(deadline: .now() + 0.8) { [self] in
            notifyPending = false
            DispatchQueue.main.async { NotificationCenter.default.post(name: EPGStore.didChange, object: self) }
            if Date().timeIntervalSince(lastSave) > 300 { save() }
        }
    }

    // MARK: - Queries (any thread)

    /// Programs of each channel, sorted by start time, from `from` on. Shared events of
    /// sub-channels are resolved to the main channel's description.
    func schedules(for channels: [Channel], from: Date) -> [[EPGEvent]] {
        let t0 = Int64(from.timeIntervalSince1970)
        return q.sync {
            channels.map { ch in
                guard let svc = services[EPGStore.key(onid: ch.onid, sid: ch.sid)] else { return [] }
                return svc.events.values
                    .filter { $0.duration < 0 || $0.end > t0 }
                    .map { resolveShared($0, onid: ch.onid) }
                    .sorted { $0.start < $1.start }
            }
        }
    }

    private func resolveShared(_ e: EPGEvent, onid: Int) -> EPGEvent {
        guard e.title.isEmpty, !e.group.isEmpty else { return e }
        for g in e.group where g.count == 2 {
            guard let ref = services[EPGStore.key(onid: onid, sid: g[0])]?.events[g[1]], !ref.title.isEmpty else { continue }
            var r = e
            r.title = ref.title
            r.text = ref.text
            if r.genres.isEmpty { r.genres = ref.genres }
            if r.extended.isEmpty { r.extended = ref.extended }
            return r
        }
        return e
    }

    func status(onid: Int, sid: Int) -> ScheduleStatus {
        let hour = BroadcastTime.calendar.component(.hour, from: Date())
        return q.sync {
            guard let svc = services[EPGStore.key(onid: onid, sid: sid)] else { return ScheduleStatus() }
            return ScheduleStatus(hasBasic: svc.basic.hasSchedule, basicComplete: svc.basic.isComplete(hour: hour),
                                  hasExtended: svc.extended.hasSchedule, extendedComplete: svc.extended.isComplete(hour: hour))
        }
    }

    // MARK: - Persistence

    /// Programs that ended before the start of yesterday's broadcast day are dropped.
    private func prune() {
        let limit = Int64(BroadcastTime.dayStart(containing: Date()).addingTimeInterval(-86400).timeIntervalSince1970)
        for (k, var svc) in services {
            let old = svc.events.values.filter { ($0.duration < 0 ? $0.start : $0.end) < limit }
            guard !old.isEmpty else { continue }
            for e in old { svc.events[e.id] = nil }
            services[k] = svc
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: [EPGEvent]].self, from: data) else { return }
        for (k, list) in saved {
            guard let key = Int(k) else { continue }
            var svc = services[key] ?? Service()
            for e in list where svc.events[e.id] == nil { svc.events[e.id] = e }
            services[key] = svc
        }
        prune()
        DispatchQueue.main.async { NotificationCenter.default.post(name: EPGStore.didChange, object: self) }
    }

    private func save() {
        prune()
        var out: [String: [EPGEvent]] = [:]
        for (k, svc) in services where !svc.events.isEmpty {
            out[String(k)] = Array(svc.events.values)
        }
        if let data = try? JSONEncoder().encode(out) {
            try? data.write(to: url, options: .atomic)
        }
        dirty = false
        lastSave = Date()
    }

    /// Writes pending changes before the app quits.
    func flush() {
        q.sync { if dirty { save() } }
    }
}
