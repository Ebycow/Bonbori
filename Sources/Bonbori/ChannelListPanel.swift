// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// Floating channel list (L key). Double-click or Return tunes.
final class ChannelListPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private weak var controller: MainController?
    private let table = NSTableView()
    private var rows: [Row] = []

    private enum Row {
        case header(String)
        case channel(Channel)
    }

    init(controller: MainController) {
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered, defer: true)
        title = "チャンネル"
        isFloatingPanel = true
        hidesOnDeactivate = false

        let col = NSTableColumn(identifier: .init("ch"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 22
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activate(_:))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        contentView = scroll
        reload()
    }

    func show(relativeTo w: NSWindow) {
        if !isVisible {
            let f = w.frame
            setFrameTopLeftPoint(NSPoint(x: f.maxX + 8, y: f.maxY))
        }
        reload()
        orderFront(nil)
    }

    func reload() {
        rows = []
        for kind in SpaceKind.allCases {
            let list = ChannelStore.shared.channels(of: kind)
            if list.isEmpty { continue }
            rows.append(.header(kind.title))
            rows.append(contentsOf: list.map { .channel($0) })
        }
        table.reloadData()
        if let cur = controller?.currentChannel,
           let idx = rows.firstIndex(where: { if case .channel(let c) = $0 { return c.id == cur.id }; return false }) {
            table.selectRowIndexes([idx], byExtendingSelection: false)
            table.scrollRowToVisible(idx)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        switch rows[row] {
        case .header(let t):
            tf.stringValue = t
            tf.font = .boldSystemFont(ofSize: 12)
        case .channel(let c):
            let key = c.remoteKey > 0 ? String(format: "%2d", c.remoteKey) : "  "
            tf.stringValue = "\(key)  \(c.name)"
            tf.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            tf.toolTip = "\(c.spaceName) \(c.channelName)  SID \(c.sid)  \(c.tsName)"
        }
        return tf
    }

    @objc private func activate(_ sender: Any?) {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, case .channel(let c) = rows[r] else { return }
        controller?.tune(c)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { activate(nil) } else { super.keyDown(with: event) }
    }
}
