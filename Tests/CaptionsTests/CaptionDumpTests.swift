// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Foundation
import Testing
@testable import Captions

/// Plays back captions saved by tvprobe (CAPDUMP=path), to see what a broadcast decodes to:
/// CAPTION_DUMP=path [CAPTION_IMAGES=folder] swift test --filter dump
@Test(.enabled(if: ProcessInfo.processInfo.environment["CAPTION_DUMP"] != nil))
func dump() throws {
    let env = ProcessInfo.processInfo.environment
    let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: env["CAPTION_DUMP"]!)))
    let caption = CaptionStream(), superimpose = CaptionStream()
    var position = 0, count = 0, pictures = 0
    var page: [CaptionRow] = []
    var rendered = 0
    func save() {
        guard let folder = env["CAPTION_IMAGES"], !page.isEmpty else { return }
        rendered += 1
        let scale: CGFloat = 2
        let size = page[0].area.planeSize
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.3, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        for row in page {
            for part in CaptionRenderer.render(row, options: CaptionRenderOptions(), scaleX: scale, scaleY: scale) {
                let r = part.rect
                ctx.draw(part.image, in: CGRect(x: r.minX * scale, y: (size.height - r.maxY) * scale, width: r.width * scale, height: r.height * scale))
            }
        }
        let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        try? png.write(to: URL(fileURLWithPath: "\(folder)/page\(rendered).png"))
    }
    while position + 13 <= data.count {
        let superimposed = data[position] != 0
        let length = data[(position + 9)..<(position + 13)].reversed().reduce(0) { $0 << 8 | Int($1) }
        let pts = data[(position + 1)..<(position + 9)].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let payload = Array(data[(position + 13)..<(position + 13 + length)])
        position += 13 + length
        count += 1
        let stream = superimposed ? superimpose : caption
        let hadLanguages = !stream.languages.isEmpty
        let items = stream.feed(payload)
        if !hadLanguages, !stream.languages.isEmpty { print("\(superimposed ? "super" : "caption") languages: \(stream.languages)") }
        for item in items {
            switch item {
            case .clear(let wait):
                print(String(format: "%10.3f +%4d CLEAR", Double(pts) / 90000, wait))
                save()
                page = []
            case .row(let row):
                page.append(row)
                let line = row.runs.flatMap(\.cells).map { cell -> String in
                    switch cell {
                    case .text(let s): return s
                    case .space: return "_"
                    case .block: return "■"
                    case .glyph(let g): return "[\(g.width)x\(g.height)]"
                    }
                }.joined()
                let s = row.runs.first?.style
                print(String(format: "%10.3f +%4d ", Double(pts) / 90000, row.wait)
                      + "fmt\(row.area.format) area\(row.area.x),\(row.area.y) \(row.area.width)x\(row.area.height) at \(row.x),\(row.y) "
                      + "\(s.map { "\($0.size) fg\($0.foreground.red),\($0.foreground.green),\($0.foreground.blue),\($0.foreground.alpha) bg\($0.background.red),\($0.background.green),\($0.background.blue),\($0.background.alpha)" } ?? "") \(line)")
            case .bitmap:
                pictures += 1
            }
        }
    }
    save()
    print("\(count) PES, \(pictures) pictures")
}
