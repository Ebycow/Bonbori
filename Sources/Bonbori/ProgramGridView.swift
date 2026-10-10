// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// The program guide: a scrolling time × channel grid with the channel names along the top and
/// the hours down the left side, which follow the grid's scrolling.
final class ProgramGuideView: NSView {
    let grid = ProgramGridView()
    let scrollView = NSScrollView()
    private let channelHeader = ChannelHeaderView()
    private let timeHeader = TimeHeaderView()
    private let corner = NSVisualEffectView()
    static let headerHeight: CGFloat = 34
    static let timeWidth: CGFloat = 44

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.documentView = grid
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.backgroundColor = .textBackgroundColor
        channelHeader.grid = grid
        timeHeader.grid = grid
        grid.headers = [channelHeader, timeHeader]
        corner.material = .headerView
        for v in [scrollView, channelHeader, timeHeader, corner] as [NSView] { addSubview(v) }
        // the default since macOS 14 lets drawing spill over neighbours
        for v in [self, grid, channelHeader, timeHeader] as [NSView] { v.clipsToBounds = true }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let h = ProgramGuideView.headerHeight, w = ProgramGuideView.timeWidth
        corner.frame = NSRect(x: 0, y: 0, width: w, height: h)
        channelHeader.frame = NSRect(x: w, y: 0, width: max(0, bounds.width - w), height: h)
        timeHeader.frame = NSRect(x: 0, y: h, width: w, height: max(0, bounds.height - h))
        scrollView.frame = NSRect(x: w, y: h, width: max(0, bounds.width - w), height: max(0, bounds.height - h))
    }

    @objc private func scrolled(_ n: Notification) {
        grid.rulersNeedDisplay()
        grid.setNeedsDisplay(grid.visibleRect)  // titles stick to the top edge
    }
}

final class ProgramGridView: NSView {
    struct Column {
        let channel: Channel
        var events: [EPGEvent]
    }

    private(set) var columns: [Column] = []
    /// Time at y = 0.
    private(set) var origin = Date()
    private var hours = 24
    let columnWidth: CGFloat = 150
    var hourHeight: CGFloat = 180 {
        didSet { if hourHeight != oldValue { resize(); needsDisplay = true; rulersNeedDisplay() } }
    }

    private(set) var selection: (channel: Channel, event: EPGEvent)?
    /// Channel and time headers, redrawn when the grid scrolls or changes.
    var headers: [NSView] = []
    var currentChannelID: String? { didSet { rulersNeedDisplay() } }
    var query = "" { didSet { updateMatches(); needsDisplay = true } }
    private var matches = Set<String>()

    var onSelect: ((Channel, EPGEvent?) -> Void)?
    var onActivate: ((Channel, EPGEvent) -> Void)?
    var onTuneChannel: ((Channel) -> Void)?
    var onShowDetail: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: - Data

    func update(columns: [Column], origin: Date, days: Int) {
        self.columns = columns
        self.origin = origin
        hours = days * 24
        updateMatches()
        if let sel = selection {
            if let c = columns.first(where: { $0.channel.id == sel.channel.id }),
               let e = c.events.first(where: { $0.id == sel.event.id }) {
                selection = (c.channel, e)
            } else {
                selection = nil
            }
            onSelect?(sel.channel, selection?.event)
        }
        resize()
        needsDisplay = true
        rulersNeedDisplay()
    }

    private func updateMatches() {
        matches = query.isEmpty ? [] : Set(columns.flatMap { col in
            col.events.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
                .map { "\(col.channel.id)#\($0.id)" }
        })
    }

    private func resize() {
        setFrameSize(NSSize(width: CGFloat(columns.count) * columnWidth, height: CGFloat(hours) * hourHeight))
    }

    func rulersNeedDisplay() {
        headers.forEach { $0.needsDisplay = true }
    }

    // MARK: - Geometry

    func y(_ t: Int64) -> CGFloat {
        CGFloat(Double(t) - origin.timeIntervalSince1970) / 3600 * hourHeight
    }

    func y(_ d: Date) -> CGFloat { y(Int64(d.timeIntervalSince1970)) }

    func time(atY y: CGFloat) -> Date {
        origin.addingTimeInterval(TimeInterval(y / hourHeight * 3600))
    }

    func columnIndex(atX x: CGFloat) -> Int? {
        let c = Int(floor(x / columnWidth))
        return c >= 0 && c < columns.count ? c : nil
    }

    /// End used for drawing: an undecided duration lasts until the next program (at most 1 hour).
    private func drawEnd(_ events: [EPGEvent], _ i: Int) -> Int64 {
        let e = events[i]
        if e.duration >= 0 { return e.end }
        let next = i + 1 < events.count ? events[i + 1].start : e.start + 3600
        return min(next, e.start + 3600)
    }

    func rect(column c: Int, event i: Int) -> NSRect {
        let ev = columns[c].events
        let top = y(ev[i].start), bottom = y(drawEnd(ev, i))
        return NSRect(x: CGFloat(c) * columnWidth, y: top, width: columnWidth, height: max(bottom - top, 1))
    }

    /// Index of the first event that is still running at `t`.
    private func firstIndex(in events: [EPGEvent], endingAfter t: Int64) -> Int {
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].start < t { lo = mid + 1 } else { hi = mid }
        }
        while lo > 0 && drawEnd(events, lo - 1) > t { lo -= 1 }
        return lo
    }

    private func hit(_ p: NSPoint) -> (column: Int, index: Int)? {
        guard let c = columnIndex(atX: p.x) else { return nil }
        let t = Int64(time(atY: p.y).timeIntervalSince1970)
        let ev = columns[c].events
        let i = firstIndex(in: ev, endingAfter: t)
        guard i < ev.count, ev[i].start <= t else { return nil }
        return (c, i)
    }

    // MARK: - Drawing

    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let textFont = NSFont.systemFont(ofSize: 11)
    private static let clock = BroadcastTime.formatter("H:mm")
    private static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 1
        return p
    }()

    override func draw(_ dirty: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(dirty).fill()
        guard !columns.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? 2
        let hair = 1 / scale

        // hour lines
        NSColor.separatorColor.setFill()
        let h0 = max(0, Int(floor(dirty.minY / hourHeight))), h1 = Int(ceil(dirty.maxY / hourHeight))
        for h in h0...h1 {
            NSRect(x: dirty.minX, y: CGFloat(h) * hourHeight, width: dirty.width, height: hair).fill()
        }

        let now = Date()
        let tTop = Int64(time(atY: dirty.minY).timeIntervalSince1970)
        let tBottom = Int64(time(atY: dirty.maxY).timeIntervalSince1970)
        let c0 = max(0, Int(floor(dirty.minX / columnWidth)))
        let c1 = min(columns.count - 1, Int(floor(dirty.maxX / columnWidth)))
        if c0 <= c1 {
            for c in c0...c1 {
                let ev = columns[c].events
                var i = firstIndex(in: ev, endingAfter: tTop)
                while i < ev.count && ev[i].start < tBottom {
                    drawEvent(column: c, index: i, now: now)
                    i += 1
                }
                NSColor.separatorColor.setFill()
                NSRect(x: CGFloat(c + 1) * columnWidth - hair, y: dirty.minY, width: hair, height: dirty.height).fill()
            }
        }

        // current time
        let ny = y(now)
        if ny >= dirty.minY - 2 && ny <= dirty.maxY + 2 {
            NSColor.systemRed.setFill()
            NSRect(x: dirty.minX, y: ny - 0.75, width: dirty.width, height: 1.5).fill()
        }
    }

    private func drawEvent(column c: Int, index i: Int, now: Date) {
        let ev = columns[c].events[i]
        let cell = rect(column: c, event: i).insetBy(dx: 1.5, dy: 0.75)
        guard cell.height >= 1 else { return }
        let ended = Int64(now.timeIntervalSince1970) >= drawEnd(columns[c].events, i)
        let isSelected = selection.map { $0.channel.id == columns[c].channel.id && $0.event.id == ev.id } ?? false
        let isMatch = matches.contains("\(columns[c].channel.id)#\(ev.id)")
        let dimmed = ended || (!query.isEmpty && !isMatch)
        let tint = (ev.mainGenre ?? .other).color

        let shape = NSBezierPath(roundedRect: cell, xRadius: 4, yRadius: 4)
        tint.withAlphaComponent(isSelected ? 0.42 : dimmed ? 0.07 : 0.17).setFill()
        shape.fill()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        tint.withAlphaComponent(dimmed ? 0.35 : 1).setFill()
        NSRect(x: cell.minX, y: cell.minY, width: 3, height: cell.height).fill()

        // a program that started above the visible area keeps its title in view
        let top = max(cell.minY, min(visibleRect.minY, cell.maxY - 40))
        let textRect = NSRect(x: cell.minX + 7, y: top + 2, width: cell.width - 10, height: cell.maxY - top - 3)
        if textRect.height >= 8 {
            let primary: NSColor = dimmed ? .tertiaryLabelColor : .labelColor
            let secondary: NSColor = dimmed ? .quaternaryLabelColor : .secondaryLabelColor
            let s = NSMutableAttributedString(string: ProgramGridView.clock.string(from: ev.startDate) + " ",
                                              attributes: [.font: ProgramGridView.timeFont, .foregroundColor: secondary])
            s.append(NSAttributedString(string: ev.title.isEmpty ? "(番組情報なし)" : ev.title,
                                        attributes: [.font: ProgramGridView.titleFont, .foregroundColor: primary]))
            if !ev.text.isEmpty && textRect.height > 34 {
                s.append(NSAttributedString(string: "\n" + ev.text,
                                            attributes: [.font: ProgramGridView.textFont, .foregroundColor: secondary]))
            }
            s.addAttribute(.paragraphStyle, value: ProgramGridView.paragraph, range: NSRange(location: 0, length: s.length))
            s.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        NSGraphicsContext.restoreGraphicsState()

        if isSelected || isMatch {
            let border = NSBezierPath(roundedRect: cell.insetBy(dx: 1, dy: 1), xRadius: 3.5, yRadius: 3.5)
            border.lineWidth = 2
            (isSelected ? NSColor.controlAccentColor : NSColor.findHighlightColor).setStroke()
            border.stroke()
        }
    }

    // MARK: - Selection

    func select(column c: Int, index i: Int, scroll: Bool = true) {
        let ch = columns[c].channel, ev = columns[c].events[i]
        if let old = selection, let r = rectOf(old) { setNeedsDisplay(r) }
        selection = (ch, ev)
        let r = rect(column: c, event: i)
        setNeedsDisplay(r)
        if scroll {
            // long programs: bring their start into view
            var target = r.insetBy(dx: -8, dy: -8)
            target.size.height = min(target.height, visibleRect.height)
            scrollToVisible(target)
        }
        onSelect?(ch, ev)
    }

    func clearSelection() {
        guard let old = selection else { return }
        if let r = rectOf(old) { setNeedsDisplay(r) }
        selection = nil
        onSelect?(old.channel, nil)
    }

    private func rectOf(_ sel: (channel: Channel, event: EPGEvent)) -> NSRect? {
        guard let c = columns.firstIndex(where: { $0.channel.id == sel.channel.id }),
              let i = columns[c].events.firstIndex(where: { $0.id == sel.event.id }) else { return nil }
        return rect(column: c, event: i)
    }

    private var selectedPosition: (column: Int, index: Int)? {
        guard let sel = selection,
              let c = columns.firstIndex(where: { $0.channel.id == sel.channel.id }),
              let i = columns[c].events.firstIndex(where: { $0.id == sel.event.id }) else { return nil }
        return (c, i)
    }

    /// Selects the next program that matches the search, in time order.
    func selectNextMatch() {
        guard !matches.isEmpty else { return }
        var all: [(Int, Int, Int64)] = []
        for (c, col) in columns.enumerated() {
            for (i, e) in col.events.enumerated() where matches.contains("\(col.channel.id)#\(e.id)") {
                all.append((c, i, e.start))
            }
        }
        all.sort { ($0.2, $0.0) < ($1.2, $1.0) }
        let now = Int64(Date().timeIntervalSince1970)
        var start = all.firstIndex { $0.2 >= now - 3600 } ?? 0
        if let cur = selectedPosition, let k = all.firstIndex(where: { $0.0 == cur.column && $0.1 == cur.index }) {
            start = (k + 1) % all.count
        }
        let m = all[start]
        select(column: m.0, index: m.1)
    }

    // MARK: - Mouse and keyboard

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let h = hit(p) else { clearSelection(); return }
        select(column: h.column, index: h.index, scroll: false)
        if event.clickCount == 2 { onActivate?(columns[h.column].channel, columns[h.column].events[h.index]) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let h = hit(p) else { return nil }
        select(column: h.column, index: h.index, scroll: false)
        let ev = columns[h.column].events[h.index]
        let menu = NSMenu()
        menu.addItem(withTitle: ev.isOnAir() ? "視聴する" : "このチャンネルを見る", action: #selector(tuneSelected(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "番組の詳細を表示", action: #selector(showDetail(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "番組名をコピー", action: #selector(copy(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func tuneSelected(_ sender: Any?) {
        if let sel = selection { onTuneChannel?(sel.channel) }
    }

    @objc private func showDetail(_ sender: Any?) { onShowDetail?() }

    @objc func copy(_ sender: Any?) {
        guard let sel = selection else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sel.event.title, forType: .string)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 125, 126:  // down / up: next / previous program of the channel
            if let cur = selectedPosition {
                let i = cur.index + (event.keyCode == 125 ? 1 : -1)
                if i >= 0 && i < columns[cur.column].events.count { select(column: cur.column, index: i) }
            } else {
                selectAt(column: 0, time: Date())
            }
        case 123, 124:  // left / right: the program running at the same time on the next channel
            if let cur = selectedPosition {
                let c = cur.column + (event.keyCode == 124 ? 1 : -1)
                let ev = columns[cur.column].events[cur.index]
                let t = max(ev.startDate, time(atY: visibleRect.minY))
                if c >= 0 && c < columns.count { selectAt(column: c, time: t) }
            } else {
                selectAt(column: 0, time: Date())
            }
        case 36, 76:  // return
            if let sel = selection { onActivate?(sel.channel, sel.event) }
        default:
            super.keyDown(with: event)
        }
    }

    private func selectAt(column c: Int, time: Date) {
        let ev = columns[c].events
        guard !ev.isEmpty else { return }
        let i = min(firstIndex(in: ev, endingAfter: Int64(time.timeIntervalSince1970)), ev.count - 1)
        select(column: c, index: i)
    }

    /// Pinch to change the time scale, keeping the time under the pointer in place.
    override func magnify(with event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let p = convert(event.locationInWindow, from: nil)
        let anchor = time(atY: p.y)
        let offset = p.y - clip.bounds.minY
        hourHeight = min(600, max(60, hourHeight * (1 + event.magnification)))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, y(anchor) - offset)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

/// Channel names along the top. Clicking one tunes to it (as in TVTest).
final class ChannelHeaderView: NSView {
    weak var grid: ProgramGridView?

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirty).fill()
        guard let grid, grid.window != nil else { return }
        let hair = 1 / (window?.backingScaleFactor ?? 2)
        for (i, col) in grid.columns.enumerated() {
            let x = convert(NSPoint(x: CGFloat(i) * grid.columnWidth, y: 0), from: grid).x
            let r = NSRect(x: x, y: 0, width: grid.columnWidth, height: bounds.height)
            guard r.intersects(dirty) else { continue }
            let current = col.channel.id == grid.currentChannelID
            if current {
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                r.fill()
            }
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineBreakMode = .byTruncatingTail
            let key = col.channel.remoteKey > 0 ? "\(col.channel.remoteKey)  " : ""
            let s = NSMutableAttributedString(string: key, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: current ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                .paragraphStyle: p,
            ])
            s.append(NSAttributedString(string: col.channel.name, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: current ? .bold : .medium),
                .foregroundColor: current ? NSColor.controlAccentColor : NSColor.labelColor,
                .paragraphStyle: p,
            ]))
            let h = s.boundingRect(with: NSSize(width: r.width - 8, height: 100), options: .usesLineFragmentOrigin).height
            s.draw(with: NSRect(x: r.minX + 4, y: (bounds.height - min(h, 16)) / 2, width: r.width - 8, height: 16),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSColor.separatorColor.setFill()
            NSRect(x: r.maxX - hair, y: 6, width: hair, height: bounds.height - 12).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: dirty.minX, y: bounds.height - hair, width: dirty.width, height: hair).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let grid else { return }
        let p = grid.convert(event.locationInWindow, from: nil)
        if let c = grid.columnIndex(atX: p.x) { grid.onTuneChannel?(grid.columns[c].channel) }
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .pointingHand)
    }
}

/// Hours down the left side, with the date at the start of each broadcast day.
final class TimeHeaderView: NSView {
    weak var grid: ProgramGridView?
    private let dateFormat = BroadcastTime.formatter("M/d")
    private let weekdayFormat = BroadcastTime.formatter("(E)")

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirty).fill()
        guard let grid, grid.window != nil else { return }
        let hair = 1 / (window?.backingScaleFactor ?? 2)
        let cal = BroadcastTime.calendar
        let top = grid.time(atY: convert(NSPoint(x: 0, y: dirty.minY), to: grid).y)
        let bottom = grid.time(atY: convert(NSPoint(x: 0, y: dirty.maxY), to: grid).y)
        var t = cal.dateInterval(of: .hour, for: top)?.start ?? top
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        while t <= bottom {
            let y = convert(NSPoint(x: 0, y: grid.y(t)), from: grid).y
            let hour = cal.component(.hour, from: t)
            let dayStart = hour == BroadcastTime.dayStartHour
            NSColor.separatorColor.setFill()
            NSRect(x: dayStart ? 0 : 6, y: y, width: bounds.width, height: dayStart ? 1 : hair).fill()
            // night hours are shaded like a calendar's off hours
            if hour < BroadcastTime.dayStartHour {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: grid.hourHeight).fill()
            }
            String(hour).draw(with: NSRect(x: 0, y: y + 4, width: bounds.width, height: 22), options: .usesLineFragmentOrigin, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: center,
            ])
            if dayStart || t == cal.dateInterval(of: .hour, for: top)?.start {
                let day = BroadcastTime.dayStart(containing: t)
                let text = "\(dateFormat.string(from: day))\n\(weekdayFormat.string(from: day))"
                text.draw(with: NSRect(x: 0, y: y + 28, width: bounds.width, height: 30), options: .usesLineFragmentOrigin, attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: weekdayColor(day), .paragraphStyle: center,
                ])
            }
            t = t.addingTimeInterval(3600)
        }
        let ny = convert(NSPoint(x: 0, y: grid.y(Date())), from: grid).y
        if ny >= dirty.minY - 4 && ny <= dirty.maxY + 4 {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 7, y: ny - 3.5, width: 7, height: 7)).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - hair, y: dirty.minY, width: hair, height: dirty.height).fill()
    }

    private func weekdayColor(_ d: Date) -> NSColor {
        switch BroadcastTime.calendar.component(.weekday, from: d) {
        case 1: return .systemRed
        case 7: return .systemBlue
        default: return .secondaryLabelColor
        }
    }
}
