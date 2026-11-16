// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One connection to a channel of ニコニコ実況 itself, which is a program of ニコニコ生放送, made
/// the way jkcnsl makes it:
///
/// 1. The watch page of the channel names the watch session (a WebSocket) of today's program.
/// 2. The watch session keeps the seat and tells where the comments are (`messageServer`).
/// 3. The comments are read over HTTP as streams of length-prefixed protobuf messages: one stream
///    lists the segments as their time comes, and each segment carries the comments of its seconds.
///
/// Not logged in, with no posting and no past comments. Use it once.
final class NiconicoClient: CommentConnection {
    var onEvent: ((CommentEvent) -> Void)?

    private let session = URLSession(configuration: .ephemeral)
    private let log: (String) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    /// Comments older than this (unix time) are from before we joined.
    private var joinedAt = Date().timeIntervalSince1970

    private struct Ended: Error { let reason: String }

    private struct Embedded: Decodable {
        struct Site: Decodable {
            struct Relive: Decodable { let webSocketUrl: String? }
            let relive: Relive?
        }
        let site: Site?
    }

    private struct WatchMessage: Decodable {
        struct Payload: Decodable {
            let keepIntervalSec: Double?
            let viewers: Int?
            let viewUri: String?
            let currentMs: String?
            let code: String?
            let reason: String?
        }
        let type: String
        let data: Payload?
    }

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// `channel` is the id of a ニコニコ生放送 channel or program (ch…, lv…).
    func connect(channel: String) {
        let t = Task { [self] in
            var reason = "接続が終了しました"
            do {
                try await run(channel)
            } catch let e as Ended {
                reason = e.reason
            } catch {
                reason = error.localizedDescription
            }
            send(.ended(reason))
        }
        lock.withLock { task = t }
    }

    func close() {
        onEvent = nil
        let (t, s) = lock.withLock { (task, socket) }
        t?.cancel()
        s?.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func send(_ event: CommentEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    /// As the watch page would ask (the servers answer nothing useful without Origin).
    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(commentUserAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("https://live.nicovideo.jp", forHTTPHeaderField: "Origin")
        r.setValue("https://live.nicovideo.jp/", forHTTPHeaderField: "Referer")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    private func run(_ channel: String) async throws {
        let watch = session.webSocketTask(with: request(try await watchSessionURL(channel)))
        lock.withLock { socket = watch }
        watch.resume()
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer {
                watch.cancel(with: .normalClosure, reason: nil)
                group.cancelAll()
            }
            // No "stream": we only want the comments.
            try await watch.send(.string(#"{"type":"startWatching","data":{"reconnect":false}}"#))
            var joined = false
            while true {
                let text: String
                switch try await watch.receive() {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                guard let m = try? JSONDecoder().decode(WatchMessage.self, from: Data(text.utf8)) else { continue }
                switch m.type {
                case "ping":
                    try await watch.send(.string(#"{"type":"pong"}"#))
                case "seat":
                    if let every = m.data?.keepIntervalSec, every > 0 {
                        group.addTask {
                            while true {
                                try await Task.sleep(for: .seconds(every))
                                try await watch.send(.string(#"{"type":"keepSeat"}"#))
                            }
                        }
                    }
                case "serverTime":
                    // Our clock may be off: go by the server's.
                    if !joined, let now = m.data?.currentMs.flatMap(Self.parseTime) { lock.withLock { joinedAt = now } }
                case "statistics":
                    if let n = m.data?.viewers { send(.viewers(n)) }
                case "messageServer":
                    guard !joined, let uri = m.data?.viewUri, uri.hasPrefix("https://") else { continue }
                    joined = true
                    log("joined \(channel)")
                    group.addTask { [self] in
                        defer { watch.cancel(with: .normalClosure, reason: nil) }  // which also ends the receive above
                        try await receiveComments(viewURI: uri)
                    }
                case "disconnect", "reconnect":
                    throw Ended(reason: "サーバーが接続を終了しました (\(m.data?.reason ?? m.type))")
                case "error":
                    // Not all of them end the session: the server closes it when they do.
                    log("watch session error \(m.data?.code ?? "?")")
                default:
                    break
                }
            }
        }
    }

    // MARK: - Watch page

    /// The watch page carries its data in `<script id="embedded-data" data-props="{json}">`.
    private func watchSessionURL(_ channel: String) async throws -> URL {
        guard channel.wholeMatch(of: try Regex("(ch|co|lv)[0-9]+")) != nil,
              let page = URL(string: "https://live.nicovideo.jp/watch/\(channel)") else {
            throw Ended(reason: "チャンネルの指定が正しくありません")
        }
        let (data, response) = try await session.data(for: request(page))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Ended(reason: "視聴ページを取得できません (HTTP \(status))") }
        let html = String(decoding: data, as: UTF8.self)
        guard let id = html.range(of: "id=\"embedded-data\""),
              let open = html[..<id.lowerBound].range(of: "<script", options: .backwards),
              let close = html[id.upperBound...].firstIndex(of: ">"),
              case let tag = html[open.lowerBound..<close],
              let props = tag.range(of: " data-props=\""),
              let end = tag[props.upperBound...].firstIndex(of: "\""),
              let embedded = try? JSONDecoder().decode(Embedded.self, from: Data(Self.unescapeHTML(tag[props.upperBound..<end]).utf8))
        else { throw Ended(reason: "視聴ページを読み取れません") }
        // The page is scraped: make sure of where it sends us.
        guard let s = embedded.site?.relive?.webSocketUrl, let url = URL(string: s), url.scheme == "wss",
              let host = url.host, host.hasSuffix(".nicovideo.jp") else {
            throw Ended(reason: "放送中の番組がありません")
        }
        return url
    }

    static func unescapeHTML(_ s: Substring) -> String {
        var out = ""
        var rest = s
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.firstIndex(of: ";"), rest.distance(from: amp, to: semi) <= 10 else {
                out.append("&")
                rest = rest.dropFirst()
                continue
            }
            let name = rest[rest.index(after: amp)..<semi]
            var ch: Character?
            switch name {
            case "quot": ch = "\""
            case "amp": ch = "&"
            case "lt": ch = "<"
            case "gt": ch = ">"
            case "apos": ch = "'"
            default:
                var code: UInt32?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    code = UInt32(name.dropFirst(2), radix: 16)
                } else if name.hasPrefix("#") {
                    code = UInt32(name.dropFirst())
                }
                ch = code.flatMap(Unicode.Scalar.init).map(Character.init)
            }
            if let ch {
                out.append(ch)
                rest = rest[rest.index(after: semi)...]
            } else {
                out.append("&")
                rest = rest.dropFirst()
            }
        }
        return out + rest
    }

    private static func parseTime(_ s: String) -> TimeInterval? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }

    // MARK: - Comments

    /// Calls `handle` with each message of a stream of varint-length-prefixed messages, until the
    /// server ends it.
    private func readMessages(_ url: URL, handle: ([UInt8]) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Ended(reason: "コメントを取得できません (HTTP \(status))") }
        var it = bytes.makeAsyncIterator()
        var message: [UInt8] = []
        while true {
            var length = 0, shift = 0
            while true {
                guard let b = try await it.next() else { return }
                length |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { break }
                shift += 7
                guard shift < 28 else { throw Ended(reason: "コメントのストリームを読み取れません") }
            }
            message.removeAll(keepingCapacity: true)
            while message.count < length {
                guard let b = try await it.next() else { return }
                message.append(b)
            }
            handle(message)
        }
    }

    /// Follows the list of segments from now on. Each request is answered for a while and ends
    /// with where to ask next.
    private func receiveComments(viewURI: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            var at = "now"
            while true {
                guard let url = URL(string: "\(viewURI)?at=\(at)") else { throw Ended(reason: "コメントの場所が正しくありません") }
                var next: UInt64?
                try await readMessages(url) { entry in
                    // ChunkedEntry: segment = 1, backward = 2, previous = 3 (both of the past), next = 4
                    for (field, value) in ProtoReader(entry) {
                        guard case .bytes(let body) = value else { continue }
                        if field == 1 {
                            // MessageSegment: from = 1, until = 2, uri = 3
                            // A segment is announced a little before its time: start on it at once.
                            guard let uri = ProtoReader(body).string(3), uri.hasPrefix("https://"), let u = URL(string: uri) else { continue }
                            group.addTask { [self] in
                                do {
                                    try await readMessages(u) { self.receive(chunkedMessage: $0) }
                                } catch {
                                    if Task.isCancelled { return }
                                    // The list of segments goes on: lose the comments of this one only.
                                    log("segment failed: \((error as? Ended)?.reason ?? error.localizedDescription)")
                                }
                            }
                        } else if field == 4 {
                            next = ProtoReader(body).varint(1)  // ReadyForNext: at = 1
                        }
                    }
                }
                try Task.checkCancellation()
                guard let next else { throw Ended(reason: "コメントのストリームが終了しました") }
                at = String(next)
            }
        }
    }

    private func receive(chunkedMessage: [UInt8]) {
        // ChunkedMessage: meta = 1 { at = 2 (Timestamp) }, message = 2 (NicoliveMessage) { chat = 1 }
        let m = ProtoReader(chunkedMessage)
        guard let chat = m.bytes(2).flatMap({ ProtoReader($0).bytes(1) }),
              let at = m.bytes(1).flatMap({ ProtoReader($0).bytes(2) }).flatMap({ ProtoReader($0).varint(1) }),
              Double(at) >= lock.withLock({ joinedAt }).rounded(.down) else { return }
        // Chat: content = 1, modifier = 7
        let c = ProtoReader(chat)
        guard let text = c.string(1), !text.isEmpty else { return }
        send(.comment(Comment(text: text, mail: c.bytes(7).map(Self.mail) ?? "")))
    }

    /// The display commands of a Chat.Modifier, as the `mail` they would have been.
    static func mail(modifier: [UInt8]) -> String {
        // position = 1 (naka, shita, ue), size = 2 (medium, small, big), named_color = 3, full_color = 4 { r, g, b }
        let m = ProtoReader(modifier)
        var words: [String] = []
        switch m.varint(1) {
        case 1: words.append("shita")
        case 2: words.append("ue")
        default: break
        }
        switch m.varint(2) {
        case 1: words.append("small")
        case 2: words.append("big")
        default: break
        }
        if let rgb = m.bytes(4) {
            let c = ProtoReader(rgb)
            words.append(String(format: "#%02X%02X%02X", Int(c.varint(1) ?? 0) & 0xFF, Int(c.varint(2) ?? 0) & 0xFF,
                                Int(c.varint(3) ?? 0) & 0xFF))
        } else if let n = m.varint(3), n > 0, n < UInt64(namedColors.count) {
            words.append(namedColors[Int(n)])
        }
        return words.joined(separator: " ")
    }

    private static let namedColors = [
        "white", "red", "pink", "orange", "yellow", "green", "cyan", "blue", "purple", "black",
        "white2", "red2", "pink2", "orange2", "yellow2", "green2", "cyan2", "blue2", "purple2", "black2",
    ]
}

/// The fields of one protobuf message, as far as the comments need them.
struct ProtoReader: Sequence, IteratorProtocol {
    enum Value {
        case varint(UInt64)
        case bytes([UInt8])
        /// fixed32 / fixed64
        case fixed
    }

    private let b: [UInt8]
    private var i = 0

    init(_ bytes: [UInt8]) {
        b = bytes
    }

    private mutating func readVarint() -> UInt64? {
        var v: UInt64 = 0, shift: UInt64 = 0
        while i < b.count, shift < 64 {
            let x = b[i]
            i += 1
            v |= UInt64(x & 0x7F) << shift
            if x & 0x80 == 0 { return v }
            shift += 7
        }
        return nil
    }

    /// Ends at the end of the message, or at anything malformed.
    mutating func next() -> (field: Int, value: Value)? {
        guard let key = readVarint() else { return nil }
        let field = Int(key >> 3)
        switch key & 7 {
        case 0:
            return readVarint().map { (field, .varint($0)) }
        case 1, 5:
            let n = key & 7 == 1 ? 8 : 4
            guard i + n <= b.count else { return nil }
            i += n
            return (field, .fixed)
        case 2:
            guard let n = readVarint(), n <= UInt64(b.count - i) else { return nil }
            defer { i += Int(n) }
            return (field, .bytes(Array(b[i..<i + Int(n)])))
        default:
            return nil
        }
    }

    func varint(_ field: Int) -> UInt64? {
        for case (field, .varint(let v)) in self { return v }
        return nil
    }

    func bytes(_ field: Int) -> [UInt8]? {
        for case (field, .bytes(let v)) in self { return v }
        return nil
    }

    func string(_ field: Int) -> String? {
        bytes(field).flatMap { String(bytes: $0, encoding: .utf8) }
    }
}
