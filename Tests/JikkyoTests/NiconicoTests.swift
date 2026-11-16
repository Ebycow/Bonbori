// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import Jikkyo

// MARK: - Building protobuf messages

private func varint(_ v: UInt64) -> [UInt8] {
    var v = v, out: [UInt8] = []
    repeat {
        out.append(UInt8(v & 0x7F) | (v > 0x7F ? 0x80 : 0))
        v >>= 7
    } while v > 0
    return out
}

private func field(_ n: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }
private func field(_ n: Int, _ body: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(body.count)) + body }

// MARK: - Tests

@Test func readsFieldsOfEveryWireType() {
    let message = field(1, 300) + [0x15, 1, 2, 3, 4] + field(3, Array("こめ".utf8)) + [0x21, 1, 2, 3, 4, 5, 6, 7, 8] + field(5, 7)
    let r = ProtoReader(message)
    #expect(r.varint(1) == 300)
    #expect(r.string(3) == "こめ")
    #expect(r.varint(5) == 7)
    #expect(r.varint(3) == nil)
    #expect(r.bytes(9) == nil)
}

@Test func stopsAtTruncatedMessage() {
    let message = field(1, 5) + [0x12, 10, 1, 2]  // a length that runs past the end
    #expect(Array(ProtoReader(message)).count == 1)
    #expect(ProtoReader([0x80]).varint(1) == nil)
}

@Test func modifierBecomesMail() {
    #expect(NiconicoClient.mail(modifier: []) == "")
    #expect(NiconicoClient.mail(modifier: field(1, 2) + field(2, 1) + field(3, 6)) == "ue small cyan")
    #expect(NiconicoClient.mail(modifier: field(1, 1) + field(2, 2) + field(3, 19)) == "shita big black2")
    #expect(NiconicoClient.mail(modifier: field(4, field(1, 255) + field(3, 16))) == "#FF0010")
    #expect(NiconicoClient.mail(modifier: field(3, 99)) == "")

    let c = Comment(text: "a", mail: NiconicoClient.mail(modifier: field(1, 1) + field(4, field(2, 128))))
    #expect(c.position == .bottom)
    #expect(c.color == Comment.Color(0x008000))
}

@Test func unescapesTheWatchPageProperties() {
    #expect(NiconicoClient.unescapeHTML("{&quot;a&quot;:&quot;x&amp;y &lt;b&gt; &#39;c&#x27; &#12354;&quot;}") == "{\"a\":\"x&y <b> 'c' あ\"}")
    #expect(NiconicoClient.unescapeHTML("a & b &unknown; &") == "a & b &unknown; &")
}

@Test func officialChannelsAreASubset() {
    #expect(ChannelTable.niconicoChannel(jikkyoID: 1) == "ch2646436")
    #expect(ChannelTable.niconicoChannel(jikkyoID: 141) == nil)
    #expect(CommentSource.niconico.hasChannel(211))
    #expect(!CommentSource.niconico.hasChannel(333))
    #expect(CommentSource.nxJikkyo.hasChannel(333))
}
