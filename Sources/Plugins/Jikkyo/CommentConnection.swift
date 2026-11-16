// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum CommentEvent {
    case comment(Comment)
    case viewers(Int)
    /// The connection is over, for whatever reason.
    case ended(String)
}

/// One connection to one 実況 channel. Use it once; JikkyoPlugin decides when to connect.
protocol CommentConnection: AnyObject {
    /// Main thread. Nothing arrives after close().
    var onEvent: ((CommentEvent) -> Void)? { get set }
    func close()
}

let commentUserAgent = "Bonbori (macOS; +https://github.com/Ebycow/Bonbori)"

/// Where the comments come from.
enum CommentSource: String, CaseIterable {
    /// NX-Jikkyo, which also forwards the comments of ニコニコ実況.
    case nxJikkyo = "nx-jikkyo"
    /// ニコニコ実況 itself (ニコニコ生放送).
    case niconico

    var title: String {
        switch self {
        case .nxJikkyo: return "NX-Jikkyo"
        case .niconico: return "ニコニコ実況（公式）"
        }
    }

    func hasChannel(_ jikkyoID: Int) -> Bool {
        switch self {
        case .nxJikkyo: return true  // ChannelTable lists the channels of NX-Jikkyo
        case .niconico: return ChannelTable.niconicoChannel(jikkyoID: jikkyoID) != nil
        }
    }

    /// Starts connecting. `hasChannel(jikkyoID)` must hold.
    func connect(jikkyoID: Int, log: @escaping (String) -> Void) -> CommentConnection? {
        switch self {
        case .nxJikkyo:
            let c = NXJikkyoClient(log: log)
            c.connect(jikkyoID: jikkyoID)
            return c
        case .niconico:
            guard let channel = ChannelTable.niconicoChannel(jikkyoID: jikkyoID) else { return nil }
            let c = NiconicoClient(log: log)
            c.connect(channel: channel)
            return c
        }
    }
}
