// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// A program found by the program guide's search.
struct ProgramSearchResult: Identifiable {
    let channel: Channel
    let event: EPGEvent
    var id: String { "\(channel.id)#\(event.id)" }
}

/// State of the program guide's search results.
final class ProgramSearchModel: ObservableObject {
    struct Day: Identifiable {
        let start: Date
        var results: [ProgramSearchResult]
        var id: Date { start }
    }

    @Published private(set) var query = ""
    @Published private(set) var days: [Day] = []
    @Published private(set) var count = 0
    /// Set by the guide when its selection changes; the list reports the user's picks through onPick.
    @Published var selection: String?
    var onPick: ((ProgramSearchResult) -> Void)?
    var onActivate: ((ProgramSearchResult) -> Void)?

    /// Searches the programs of every channel (地デジ, BS and CS) that have not ended yet.
    func search(_ query: String) {
        self.query = query
        guard !query.isEmpty else {
            days = []
            count = 0
            return
        }
        let now = Date()
        let t = Int64(now.timeIntervalSince1970)
        let channels = SpaceKind.allCases.flatMap { ChannelStore.shared.channels(of: $0) }
        let schedules = EPGStore.shared.schedules(for: channels, from: BroadcastTime.dayStart(containing: now))
        var found: [ProgramSearchResult] = []
        for (ch, events) in zip(channels, schedules) {
            for e in events where (e.start > t || e.isOnAir(at: now)) && e.matches(query) {
                found.append(.init(channel: ch, event: e))
            }
        }
        // stable: programs at the same time stay in channel order
        found = found.enumerated().sorted { ($0.element.event.start, $0.offset) < ($1.element.event.start, $1.offset) }.map(\.element)
        var out: [Day] = []
        for r in found {
            let day = BroadcastTime.dayStart(containing: r.event.startDate)
            if out.last?.start == day { out[out.count - 1].results.append(r) } else { out.append(Day(start: day, results: [r])) }
        }
        days = out
        count = found.count
    }

    func result(_ id: String) -> ProgramSearchResult? {
        for d in days { if let r = d.results.first(where: { $0.id == id }) { return r } }
        return nil
    }
}

/// The list of programs that match the search, shown beside the program guide.
struct ProgramSearchView: View {
    @ObservedObject var model: ProgramSearchModel

    private static let dayTitle = BroadcastTime.formatter("M/d(E)")

    var body: some View {
        if model.days.isEmpty {
            ContentUnavailableView("一致する番組はありません", systemImage: "magnifyingglass",
                                   description: Text(model.query.isEmpty ? "番組名や番組の説明で検索できます。"
                                                                         : "これから放送される番組から「\(model.query)」を探しました。"))
        } else {
            ScrollViewReader { proxy in
                List(selection: Binding(get: { model.selection }, set: { id in
                    model.selection = id
                    if let id, let r = model.result(id) { model.onPick?(r) }
                })) {
                    ForEach(model.days) { day in
                        Section(dayTitle(day.start)) {
                            ForEach(day.results) { r in
                                ProgramSearchRow(result: r, query: model.query).tag(r.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                // follow the grid (e.g. Return in the search field selects the next match there)
                .onChange(of: model.selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("\(model.count)件の番組")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let r = model.result(id) {
                    Button(r.event.isOnAir() ? "視聴する" : "番組の詳細を表示") { model.onActivate?(r) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let r = model.result(id) { model.onActivate?(r) }
            }
        }
    }

    private func dayTitle(_ d: Date) -> String {
        let today = BroadcastTime.dayStart(containing: Date())
        let prefix = d == today ? "今日 " : d == today.addingTimeInterval(86400) ? "明日 " : ""
        return prefix + ProgramSearchView.dayTitle.string(from: d)
    }
}

private struct ProgramSearchRow: View {
    let result: ProgramSearchResult
    let query: String

    private static let clock = BroadcastTime.formatter("H:mm")

    var body: some View {
        let ev = result.event
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: (ev.mainGenre ?? .other).color))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(timeText(ev))
                        .monospacedDigit()
                    Text(result.channel.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if ev.isOnAir() {
                        Text("放送中")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(ev.title.isEmpty ? "(番組情報なし)" : ev.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                // found in the description only: show where
                if !ev.title.localizedCaseInsensitiveContains(query) {
                    Text(ev.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func timeText(_ ev: EPGEvent) -> String {
        let start = ProgramSearchRow.clock.string(from: ev.startDate)
        return ev.duration >= 0 ? "\(start)〜\(ProgramSearchRow.clock.string(from: ev.endDate))" : "\(start)〜"
    }
}
