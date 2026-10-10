// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI

/// 番組表 window: the guide grid with a SwiftUI inspector for the selected program.
final class ProgramGuideWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    private weak var controller: MainController?
    private let guide = ProgramGuideView()
    private var grid: ProgramGridView { guide.grid }
    private var scroll: NSScrollView { guide.scrollView }
    private let detail = ProgramDetailModel()
    private let split = NSSplitViewController()
    private var inspector: NSSplitViewItem!
    private var kind: SpaceKind = .terrestrial
    private var days: [Date] = []
    private var minuteTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private let kindControl = NSSegmentedControl(labels: SpaceKind.allCases.map(\.title), trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let datePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var captureItem: NSMenuToolbarItem?

    private static let dayTitle = BroadcastTime.formatter("M/d(E)")
    private static let subtitleDay = BroadcastTime.formatter("M月d日(E)")

    init(controller: MainController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        super.init(window: window)
        window.title = "番組表"
        window.delegate = self
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 640, height: 400)
        window.tabbingMode = .disallowed

        grid.hourHeight = CGFloat(UserDefaults.standard.object(forKey: "guideHourHeight") as? Double ?? 180)

        let gridVC = NSViewController()
        gridVC.view = guide
        let gridItem = NSSplitViewItem(viewController: gridVC)
        gridItem.minimumThickness = 400
        split.addSplitViewItem(gridItem)

        let hosting = NSHostingController(rootView: ProgramDetailView(model: detail))
        hosting.sizingOptions = []  // the window size is the user's, not the SwiftUI content's
        inspector = NSSplitViewItem(inspectorWithViewController: hosting)
        inspector.minimumThickness = 260
        inspector.maximumThickness = 460
        inspector.canCollapse = true
        split.addSplitViewItem(inspector)
        split.splitView.autosaveName = "ProgramGuideSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameAutosaveName("ProgramGuide")
        if !window.setFrameUsingName("ProgramGuide") { window.center() }

        let toolbar = NSToolbar(identifier: "ProgramGuide")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        kindControl.target = self
        kindControl.action = #selector(kindChanged(_:))
        datePopup.target = self
        datePopup.action = #selector(dateChanged(_:))

        grid.onSelect = { [weak self] ch, ev in
            self?.detail.channel = ch
            self?.detail.event = ev
        }
        grid.onActivate = { [weak self] ch, ev in
            guard let self else { return }
            if ev.isOnAir() { self.controller?.tune(ch) } else { self.showInspector() }
        }
        grid.onTuneChannel = { [weak self] ch in self?.controller?.tune(ch) }
        grid.onShowDetail = { [weak self] in self?.showInspector() }
        detail.onWatch = { [weak self] ch in self?.controller?.tune(ch) }

        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.visibleTimeChanged()
        })
        observers.append(NotificationCenter.default.addObserver(forName: EPGStore.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.reload()
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Showing

    func show() {
        let firstTime = window?.isVisible != true
        if firstTime, let k = controller?.currentChannel?.kind { setKind(k) }
        reload()
        showWindow(nil)
        window?.makeFirstResponder(grid)
        if firstTime { scrollToNow() }
        minuteTimer?.invalidate()
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            // the current-time line moves and programs end
            self.grid.needsDisplay = true
            self.grid.rulersNeedDisplay()
        }
    }

    func windowWillClose(_ notification: Notification) {
        minuteTimer?.invalidate()
        minuteTimer = nil
    }

    var isVisible: Bool { window?.isVisible == true }

    private func setKind(_ k: SpaceKind) {
        kind = k
        kindControl.selectedSegment = k.rawValue
    }

    /// Rebuilds the columns from the channel list and the EPG database.
    func reload() {
        let channels = ChannelStore.shared.channels(of: kind)
        let origin = BroadcastTime.dayStart(containing: Date())
        let schedules = EPGStore.shared.schedules(for: channels, from: origin)
        let last = schedules.compactMap { $0.last?.end }.max() ?? 0
        let span = Double(last) - origin.timeIntervalSince1970
        let dayCount = min(9, max(1, Int(ceil(span / 86400))))
        grid.currentChannelID = controller?.currentChannel?.id
        grid.update(columns: zip(channels, schedules).map { .init(channel: $0, events: $1) }, origin: origin, days: dayCount)

        let newDays = (0..<dayCount).map { origin.addingTimeInterval(TimeInterval($0 * 86400)) }
        if newDays != days {
            days = newDays
            datePopup.removeAllItems()
            for (i, d) in days.enumerated() {
                let prefix = i == 0 ? "今日 " : i == 1 ? "明日 " : ""
                datePopup.addItem(withTitle: prefix + ProgramGuideWindowController.dayTitle.string(from: d))
            }
        }
        visibleTimeChanged()
        updateSubtitle()
    }

    func currentChannelChanged() {
        grid.currentChannelID = controller?.currentChannel?.id
    }

    // MARK: - Navigation

    private func scrollToNow() {
        scroll(to: Date().addingTimeInterval(-1800))
        if let c = grid.columns.firstIndex(where: { $0.channel.id == controller?.currentChannel?.id }) {
            let clip = scroll.contentView
            let x = CGFloat(c) * grid.columnWidth
            if x + grid.columnWidth > clip.bounds.maxX {
                clip.scroll(to: NSPoint(x: max(0, x - grid.columnWidth), y: clip.bounds.minY))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    private func scroll(to t: Date) {
        let clip = scroll.contentView
        let maxY = max(0, grid.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(maxY, max(0, grid.y(t)))))
        scroll.reflectScrolledClipView(clip)
    }

    private func visibleTimeChanged() {
        let top = grid.time(atY: scroll.contentView.bounds.minY + 1)
        let day = BroadcastTime.dayStart(containing: top)
        if let i = days.firstIndex(of: day), datePopup.indexOfSelectedItem != i { datePopup.selectItem(at: i) }
        updateSubtitle()
    }

    private func updateSubtitle() {
        guard let window else { return }
        if let cap = controller?.epgCapture, let stop = cap.current {
            let min = Int((cap.remainingTime / 60).rounded(.up))
            window.subtitle = "番組表を取得中 \(cap.index + 1)/\(cap.stops.count) · \(stop.title) · 残り約\(min)分"
        } else {
            let top = grid.time(atY: scroll.contentView.bounds.minY + 1)
            window.subtitle = ProgramGuideWindowController.subtitleDay.string(from: BroadcastTime.dayStart(containing: top))
        }
    }

    func captureStateChanged() {
        if let item = captureItem {
            let running = controller?.epgCapture.isRunning == true
            item.image = NSImage(systemSymbolName: running ? "stop.circle" : "arrow.triangle.2.circlepath",
                                 accessibilityDescription: nil)
            item.label = running ? "取得を中止" : "番組表を取得"
            item.toolTip = running ? "番組表の取得を中止" : "表示中の放送の番組表を取得（チャンネルを巡回します）"
        }
        updateSubtitle()
    }

    private func showInspector() {
        if inspector.isCollapsed { inspector.animator().isCollapsed = false }
    }

    // MARK: - Actions

    @objc private func kindChanged(_ sender: NSSegmentedControl) {
        guard let k = SpaceKind(rawValue: sender.selectedSegment), k != kind else { return }
        let top = grid.time(atY: scroll.contentView.bounds.minY)
        kind = k
        grid.clearSelection()
        reload()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, grid.y(top))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func dateChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0 && i < days.count else { return }
        if i == 0 { scrollToNow() } else { scroll(to: days[i]) }
    }

    @objc func goToNow(_ sender: Any?) { scrollToNow() }

    @objc private func toggleCapture(_ sender: Any?) {
        guard let controller else { return }
        if controller.epgCapture.isRunning {
            controller.stopEPGCapture()
        } else {
            controller.startEPGCapture(kinds: [kind])
        }
    }

    @objc private func captureKinds(_ sender: NSMenuItem) {
        controller?.startEPGCapture(kinds: sender.tag < 0 ? SpaceKind.allCases : [SpaceKind(rawValue: sender.tag)!])
    }

    @objc func zoomInGuide(_ sender: Any?) { setHourHeight(grid.hourHeight * 1.25) }
    @objc func zoomOutGuide(_ sender: Any?) { setHourHeight(grid.hourHeight / 1.25) }

    private func setHourHeight(_ h: CGFloat) {
        let top = grid.time(atY: scroll.contentView.bounds.minY)
        grid.hourHeight = min(600, max(60, h))
        UserDefaults.standard.set(Double(grid.hourHeight), forKey: "guideHourHeight")
        scroll(to: top)
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .search }) as? NSSearchToolbarItem {
            item.beginSearchInteraction()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        grid.query = field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func searchSubmitted(_ sender: NSSearchField) {
        grid.query = sender.stringValue.trimmingCharacters(in: .whitespaces)
        grid.selectNextMatch()
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.kind, .date, .now, .flexibleSpace, .capture, .search, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .kind:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "放送"
            item.view = kindControl
            return item
        case .date:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "日付"
            item.view = datePopup
            return item
        case .now:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "現在"
            item.toolTip = "現在の時刻へ移動"
            item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "現在")
            item.target = self
            item.action = #selector(goToNow(_:))
            item.isBordered = true
            return item
        case .capture:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            let menu = NSMenu()
            for k in SpaceKind.allCases {
                let mi = menu.addItem(withTitle: "\(k.title)の番組表を取得", action: #selector(captureKinds(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = k.rawValue
            }
            menu.addItem(.separator())
            let all = menu.addItem(withTitle: "すべての番組表を取得", action: #selector(captureKinds(_:)), keyEquivalent: "")
            all.target = self
            all.tag = -1
            item.menu = menu
            item.showsIndicator = true
            item.target = self
            item.action = #selector(toggleCapture(_:))
            captureItem = item
            captureStateChanged()
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "番組を検索"
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchSubmitted(_:))
            item.searchField.sendsWholeSearchString = true
            return item
        default:
            return nil
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let kind = Self("kind")
    static let date = Self("date")
    static let now = Self("now")
    static let capture = Self("capture")
    static let search = Self("search")
}
