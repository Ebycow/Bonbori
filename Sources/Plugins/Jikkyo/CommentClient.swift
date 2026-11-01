// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One connection to a channel of NX-Jikkyo, which also carries the comments of ニコニコ実況:
/// a watch session (keeps the seat, tells where the comments are) and a comment session.
///
/// NX-Jikkyo is run by volunteers, so this asks for no more than it shows: no posting rights and
/// no past comments. Use it once; JikkyoPlugin decides when to connect.
final class CommentClient {
    enum Event {
        case comment(Comment)
        case viewers(Int)
        /// The connection is over, for whatever reason.
        case ended(String)
    }

    /// Main thread. Nothing arrives after close().
    var onEvent: ((Event) -> Void)?

    private let session = URLSession(configuration: .ephemeral)
    private let log: (String) -> Void
    private let lock = NSLock()
    private var sockets: [URLSessionWebSocketTask] = []

    private static let userAgent = "Bonbori (macOS; +https://github.com/Ebycow/Bonbori)"

    private struct Ended: Error { let reason: String }

    private struct WatchMessage: Decodable {
        struct Payload: Decodable {
            struct MessageServer: Decodable { let uri: String? }
            let keepIntervalSec: Double?
            let viewers: Int?
            let threadId: String?
            let yourPostKey: String?
            let messageServer: MessageServer?
            let code: String?
            let reason: String?
        }
        let type: String
        let data: Payload?
    }

    private struct CommentMessage: Decodable {
        struct Chat: Decodable {
            let date: Int?
            let mail: String?
            let premium: Int?
            let content: String?
        }
        struct Thread: Decodable {
            let server_time: Int?
        }
        let chat: Chat?
        let thread: Thread?
    }

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func connect(jikkyoID: Int) {
        Task { [self] in
            var reason = "接続が終了しました"
            do {
                try await run(jikkyoID)
            } catch let e as Ended {
                reason = e.reason
            } catch {
                reason = error.localizedDescription
            }
            send(.ended(reason))
        }
    }

    func close() {
        onEvent = nil
        closeSockets()
        session.finishTasksAndInvalidate()
    }

    /// Says goodbye to the server. Receiving ends with an error, which is how run() learns of it.
    private func closeSockets() {
        let open = lock.withLock {
            defer { sockets = [] }
            return sockets
        }
        open.forEach { $0.cancel(with: .normalClosure, reason: nil) }
    }

    private func send(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    private func socket(_ url: URL) -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        request.setValue(CommentClient.userAgent, forHTTPHeaderField: "User-Agent")
        let s = session.webSocketTask(with: request)
        lock.withLock { sockets.append(s) }
        s.resume()
        return s
    }

    private func decode<T: Decodable>(_ type: T.Type, _ message: URLSessionWebSocketTask.Message) -> T? {
        switch message {
        case .string(let s): return try? JSONDecoder().decode(type, from: Data(s.utf8))
        case .data(let d): return try? JSONDecoder().decode(type, from: d)
        @unknown default: return nil
        }
    }

    private func run(_ jikkyoID: Int) async throws {
        let url = URL(string: "wss://nx-jikkyo.tsukumijima.net/api/v1/channels/jk\(jikkyoID)/ws/watch")!
        let watch = socket(url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer {
                closeSockets()
                group.cancelAll()
            }
            try await watch.send(.string(#"{"type":"startWatching","data":{"room":{"protocol":"webSocket","commentable":false},"reconnect":false}}"#))
            var joined = false
            while true {
                guard let m = decode(WatchMessage.self, try await watch.receive()) else { continue }
                switch m.type {
                case "ping":
                    try await watch.send(.string(#"{"type":"pong"}"#))
                case "seat":
                    if let every = m.data?.keepIntervalSec, every > 0 {
                        group.addTask { try await Self.keepSending(#"{"type":"keepSeat"}"#, to: watch, every: every) }
                    }
                case "statistics":
                    if let n = m.data?.viewers { send(.viewers(n)) }
                case "room":
                    guard !joined, let thread = m.data?.threadId,
                          let uri = m.data?.messageServer?.uri, let server = URL(string: uri), uri.hasPrefix("wss://") else { continue }
                    joined = true
                    let comments = socket(server)
                    try await comments.send(.string(Self.openThread(thread, key: m.data?.yourPostKey)))
                    log("joined jk\(jikkyoID) thread \(thread)")
                    group.addTask { [self] in
                        defer { closeSockets() }  // which also ends the receive above
                        try await receiveComments(from: comments)
                    }
                    group.addTask { try await Self.keepSending("", to: comments, every: 60) }
                case "disconnect", "reconnect":
                    throw Ended(reason: "サーバーが接続を終了しました (\(m.data?.reason ?? m.type))")
                case "error":
                    throw Ended(reason: "サーバーのエラー (\(m.data?.code ?? "?"))")
                default:
                    break
                }
            }
        }
    }

    private static func keepSending(_ text: String, to socket: URLSessionWebSocketTask, every seconds: Double) async throws {
        while true {
            try await Task.sleep(for: .seconds(seconds))
            try await socket.send(.string(text))
        }
    }

    private static func openThread(_ thread: String, key: String?) -> String {
        var open: [String: Any] = ["thread": thread, "user_id": "guest", "res_from": 0, "version": "20061206",
                                   "nicoru": 0, "scores": 1, "with_global": 1]
        if let key { open["threadkey"] = key }
        let messages: [[String: Any]] = [
            ["ping": ["content": "rs: 0"]], ["ping": ["content": "ps: 0"]],
            ["thread": open],
            ["ping": ["content": "pf: 0"]], ["ping": ["content": "rf: 0"]],
        ]
        let data = try? JSONSerialization.data(withJSONObject: messages)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private func receiveComments(from socket: URLSessionWebSocketTask) async throws {
        var joinedAt = Int.max
        while true {
            guard let m = decode(CommentMessage.self, try await socket.receive()) else { continue }
            if let t = m.thread?.server_time { joinedAt = t }
            guard let chat = m.chat, let text = chat.content, !text.isEmpty else { continue }
            // Comments from before we joined, and the system's own messages (/nicoad and so on).
            if chat.date ?? 0 < joinedAt { continue }
            if text.hasPrefix("/") && (chat.premium ?? 0) >= 2 { continue }
            send(.comment(Comment(text: text, mail: chat.mail ?? "")))
        }
    }
}
