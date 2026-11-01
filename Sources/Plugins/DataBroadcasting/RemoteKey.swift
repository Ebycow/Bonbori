// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// The buttons of a TV remote control, as ARIB key codes.
enum RemoteKey: Int, CaseIterable {
    case up = 1, down, left, right
    case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9, digit10, digit11, digit12
    case enter, back, dataButton
    case blue, red, green, yellow

    /// The number on the button, for the digits.
    var number: Int? {
        (RemoteKey.digit0.rawValue...RemoteKey.digit12.rawValue).contains(rawValue) ? rawValue - RemoteKey.digit0.rawValue : nil
    }

    static func digit(_ number: Int) -> RemoteKey? {
        RemoteKey(rawValue: RemoteKey.digit0.rawValue + number).flatMap { $0.number == number ? $0 : nil }
    }

    /// The keys of a document, in the groups it says it uses.
    var group: KeyGroup? {
        switch self {
        case .up, .down, .left, .right, .enter, .back: return .basic
        case .blue, .red, .green, .yellow: return .dataButton
        case .dataButton: return nil
        default: return .numericTuning
        }
    }

    /// The button a key of the Mac keyboard stands for. These keys mean something else to the app,
    /// so they only take this meaning while the data broadcast is being operated.
    init?(keyCode: UInt16, characters: String?) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 36, 76: self = .enter  // return, keypad enter
        case 51: self = .back       // delete
        case 122: self = .blue      // F1
        case 120: self = .red       // F2
        case 99: self = .green      // F3
        case 118: self = .yellow    // F4
        default:
            // the same keys as the channel buttons of the app, with 0 as itself
            switch characters {
            case let c? where c.count == 1 && "0123456789".contains(c):
                guard let digit = RemoteKey.digit(Int(c)!) else { return nil }
                self = digit
            case "-": self = .digit11
            case "^", "=": self = .digit12
            default: return nil
            }
        }
    }
}

/// Groups of keys in the `used-key-list` of a BML document.
enum KeyGroup: String {
    case basic
    case dataButton = "data-button"
    case numericTuning = "numeric-tuning"
}
