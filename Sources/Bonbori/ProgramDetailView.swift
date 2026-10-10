// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// State of the program guide's inspector.
final class ProgramDetailModel: ObservableObject {
    @Published var channel: Channel?
    @Published var event: EPGEvent?
    var onWatch: ((Channel) -> Void)?
}

/// Details of the selected program, shown in the program guide's inspector.
struct ProgramDetailView: View {
    @ObservedObject var model: ProgramDetailModel

    var body: some View {
        if let ch = model.channel, let ev = model.event {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(ch, ev)
                    Button {
                        model.onWatch?(ch)
                    } label: {
                        Label(ev.isOnAir() ? "視聴する" : "このチャンネルを見る", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if !ev.text.isEmpty || !ev.extended.isEmpty {
                        Divider()
                    }
                    if !ev.text.isEmpty {
                        Text(ev.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(ev.extended.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.first ?? "")
                                .font(.headline)
                            Text(item.count > 1 ? item[1] : "")
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    let specs = specs(ev)
                    if !specs.isEmpty {
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            ForEach(specs, id: \.0) { spec in
                                GridRow {
                                    Text(spec.0).foregroundStyle(.secondary)
                                    Text(spec.1)
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("番組が選択されていません", systemImage: "list.bullet.rectangle",
                                   description: Text("番組表で番組をクリックすると、詳しい情報がここに表示されます。"))
        }
    }

    @ViewBuilder
    private func header(_ ch: Channel, _ ev: EPGEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ch.remoteKey > 0 ? "\(ch.remoteKey)  \(ch.name)" : ch.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if ev.isOnAir() {
                    Text("放送中")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }
            }
            Text(ev.title.isEmpty ? "(番組情報なし)" : ev.title)
                .font(.title3.weight(.bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Label(timeText(ev), systemImage: "clock")
                .foregroundStyle(.secondary)
            ForEach(Array(genreTexts(ev).enumerated()), id: \.offset) { _, g in
                Label(g.text, systemImage: "tag")
                    .foregroundStyle(Color(nsColor: g.color))
            }
        }
    }

    private func timeText(_ ev: EPGEvent) -> String {
        let day = BroadcastTime.formatter("M月d日(E) H:mm").string(from: ev.startDate)
        guard ev.duration >= 0 else { return "\(day)〜 (時間未定)" }
        let end = BroadcastTime.formatter("H:mm").string(from: ev.endDate)
        return "\(day)〜\(end) (\(ev.duration / 60)分)"
    }

    private func genreTexts(_ ev: EPGEvent) -> [(text: String, color: NSColor)] {
        var seen = Set<Int>()
        return ev.genres.compactMap { code in
            guard code >> 4 != 0xE, seen.insert(code).inserted, let g = Genre(rawValue: code >> 4) else { return nil }
            let text = Genre.subName(code).map { "\(g.name) › \($0)" } ?? g.name
            return (text, g.color)
        }
    }

    private func specs(_ ev: EPGEvent) -> [(String, String)] {
        var out: [(String, String)] = []
        if let v = ev.video, let s = videoText(v) { out.append(("映像", s)) }
        let audio = ev.audio.compactMap(audioText)
        if !audio.isEmpty { out.append(("音声", audio.joined(separator: " / "))) }
        out.append(("視聴", ev.freeCA ? "有料 (スクランブル)" : "無料"))
        return out
    }

    /// component_type of the video component (ARIB STD-B10).
    private func videoText(_ t: Int) -> String? {
        let res: String
        switch t >> 4 {
        case 0x0: res = "480i"
        case 0x8: res = "4320p"
        case 0x9: res = "2160p"
        case 0xA: res = "480p"
        case 0xB: res = "1080i"
        case 0xC: res = "720p"
        case 0xD: res = "240p"
        case 0xE: res = "1080p"
        case 0xF: res = "180p"
        default: return nil
        }
        switch t & 0x0F {
        case 1: return "\(res) (4:3)"
        case 2, 3: return "\(res) (16:9)"
        case 4: return "\(res) (16:9 以上)"
        default: return res
        }
    }

    private func audioText(_ t: Int) -> String? {
        switch t {
        case 0x01: return "モノラル"
        case 0x02: return "二重音声"
        case 0x03: return "ステレオ"
        case 0x07: return "3/1"
        case 0x08: return "3/2"
        case 0x09: return "5.1ch"
        case 0x11: return "22.2ch"
        default: return nil
        }
    }
}
