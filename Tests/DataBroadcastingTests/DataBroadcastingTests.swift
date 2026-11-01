// SPDX-License-Identifier: GPL-2.0-or-later
import Testing
@testable import DataBroadcasting

@Test func keyCodesAreThoseOfARIB() {
    #expect(RemoteKey.up.rawValue == 1)
    #expect(RemoteKey.right.rawValue == 4)
    #expect(RemoteKey.digit0.rawValue == 5)
    #expect(RemoteKey.digit12.rawValue == 17)
    #expect(RemoteKey.enter.rawValue == 18)
    #expect(RemoteKey.back.rawValue == 19)
    #expect(RemoteKey.dataButton.rawValue == 20)
    #expect(RemoteKey.blue.rawValue == 21)
    #expect(RemoteKey.yellow.rawValue == 24)
}

@Test func digitsMapBothWays() {
    for n in 0...12 {
        #expect(RemoteKey.digit(n)?.number == n)
    }
    #expect(RemoteKey.digit(13) == nil)
    #expect(RemoteKey.enter.number == nil)
}

@Test func keyboardMapsToRemoteButtons() {
    #expect(RemoteKey(keyCode: 126, characters: nil) == .up)
    #expect(RemoteKey(keyCode: 36, characters: "\r") == .enter)
    #expect(RemoteKey(keyCode: 51, characters: nil) == .back)
    #expect(RemoteKey(keyCode: 122, characters: nil) == .blue)
    #expect(RemoteKey(keyCode: 118, characters: nil) == .yellow)
    #expect(RemoteKey(keyCode: 29, characters: "0") == .digit0)
    #expect(RemoteKey(keyCode: 18, characters: "1") == .digit1)
    #expect(RemoteKey(keyCode: 27, characters: "-") == .digit11)
    #expect(RemoteKey(keyCode: 24, characters: "^") == .digit12)
    #expect(RemoteKey(keyCode: 0, characters: "a") == nil)
}

@Test func keysBelongToTheGroupsDocumentsName() {
    #expect(RemoteKey.down.group == .basic)
    #expect(RemoteKey.back.group == .basic)
    #expect(RemoteKey.red.group == .dataButton)
    #expect(RemoteKey.digit5.group == .numericTuning)
    #expect(RemoteKey.dataButton.group == nil)
    #expect(KeyGroup(rawValue: "numeric-tuning") == .numericTuning)
}

@Test func zipCodesAreNormalized() throws {
    #expect(try ZipCode.normalize("100-0001").get() == "1000001")
    #expect(try ZipCode.normalize("１００－０００１").get() == "1000001")
    #expect(try ZipCode.normalize("").get() == "")
    #expect(ZipCode.normalize("100") == .failure(.wrongLength))
    #expect(ZipCode.normalize("1O00001") == .failure(.invalidCharacter("O")))
}

@Test func regionsKeepTheirCodes() {
    #expect(ReceiverRegion.all.count == 51)
    #expect(ReceiverRegion.all.first == .unset)
    let tokyo = ReceiverRegion.all.first { $0.name == "東京都(島部を除く)" }
    #expect(tokyo?.prefecture == 14)
    #expect(tokyo?.regionCode == 0xAAC)
}

@Test func inputIsCheckedLikeOnATV() throws {
    let request = try #require(TextInputRequest([
        "characterType": "number", "maxLength": 4, "allowedCharacters": "0123456789", "value": "12", "inputMode": "password",
    ]))
    #expect(request.isPassword)
    #expect(request.problem(with: "1234") == nil)
    #expect(request.problem(with: "12345") != nil)
    #expect(request.problem(with: "12a") != nil)
    #expect(TextInputRequest(["maxLength": 4]) == nil)
}
