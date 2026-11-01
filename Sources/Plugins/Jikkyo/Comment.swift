// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics

/// One comment, with its display commands (the `mail` attribute of a chat) resolved.
struct Comment {
    enum Position { case scroll, top, bottom }
    enum Size { case small, medium, big }
    struct Color: Equatable {
        var r, g, b: CGFloat
        init(_ rgb: Int) {
            r = CGFloat(rgb >> 16 & 0xFF) / 255
            g = CGFloat(rgb >> 8 & 0xFF) / 255
            b = CGFloat(rgb & 0xFF) / 255
        }
        var brightness: CGFloat { 0.299 * r + 0.587 * g + 0.114 * b }
    }

    let text: String
    var position = Position.scroll
    var size = Size.medium
    var color = Color(0xFFFFFF)

    init(text: String, mail: String) {
        self.text = text
        for token in mail.split(separator: " ") {
            switch token {
            case "ue": position = .top
            case "shita": position = .bottom
            case "small": size = .small
            case "big": size = .big
            default:
                if let c = Comment.namedColors[String(token)] {
                    color = c
                } else if token.hasPrefix("#"), token.count == 7, let rgb = Int(token.dropFirst(), radix: 16) {
                    color = Color(rgb)
                }
            }
        }
    }

    private static let namedColors: [String: Color] = [
        "white": Color(0xFFFFFF), "red": Color(0xFF0000), "pink": Color(0xFF8080), "orange": Color(0xFFC000),
        "yellow": Color(0xFFFF00), "green": Color(0x00FF00), "cyan": Color(0x00FFFF), "blue": Color(0x0000FF),
        "purple": Color(0xC000FF), "black": Color(0x000000),
        "white2": Color(0xCCCC99), "niconicowhite": Color(0xCCCC99),
        "red2": Color(0xCC0033), "truered": Color(0xCC0033), "pink2": Color(0xFF33CC),
        "orange2": Color(0xFF6600), "passionorange": Color(0xFF6600),
        "yellow2": Color(0x999900), "madyellow": Color(0x999900),
        "green2": Color(0x00CC66), "elementalgreen": Color(0x00CC66), "cyan2": Color(0x00CCCC),
        "blue2": Color(0x3399FF), "marineblue": Color(0x3399FF),
        "purple2": Color(0x6633CC), "nobleviolet": Color(0x6633CC), "black2": Color(0x666666),
    ]
}
