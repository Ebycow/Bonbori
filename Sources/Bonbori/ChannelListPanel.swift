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
        /// A data, temporary or engineering service (not for zapping).
        case other(Channel)

        var channel: Channel? {
            switch self {
            case .header: return nil
            case .channel(let c), .other(let c): return c
            }
        }
    }

    private static let logoSize = NSSize(width: 32, height: 18)

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
        NotificationCenter.default.addObserver(self, selector: #selector(logosChanged), name: .logosChanged, object: nil)
    }

    @objc private func logosChanged() {
        if isVisible { table.reloadData() }
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
            let others = ChannelStore.shared.otherServices(of: kind)
            if !others.isEmpty {
                rows.append(.header("\(kind.title)  その他のサービス"))
                rows.append(contentsOf: others.map { .other($0) })
            }
        }
        table.reloadData()
        if let cur = controller?.currentChannel,
           let idx = rows.firstIndex(where: { $0.channel?.id == cur.id }) {
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
        let c: Channel
        switch rows[row] {
        case .header(let t):
            tf.stringValue = t
            tf.font = .boldSystemFont(ofSize: 12)
            return tf
        case .channel(let ch):
            c = ch
            let key = c.remoteKey > 0 ? String(format: "%2d", c.remoteKey) : "  "
            tf.stringValue = "\(key)  \(c.displayName)"
            tf.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            tf.toolTip = "\(c.spaceName) \(c.channelName)  SID \(c.sid)  \(c.tsName)"
        case .other(let ch):
            c = ch
            let s = NSMutableAttributedString(string: c.displayName, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            s.append(NSAttributedString(string: "  \(c.serviceTypeName)", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            tf.attributedStringValue = s
            tf.toolTip = String(format: "%@ %@  SID %d  service_type 0x%02X  %@", c.spaceName, c.channelName, c.sid,
                                c.serviceType, c.tsName)
        }
        let logo = NSImageView()
        logo.image = LogoStore.shared.image(for: c)
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: ChannelListPanel.logoSize.width).isActive = true
        logo.heightAnchor.constraint(equalToConstant: ChannelListPanel.logoSize.height).isActive = true
        let stack = NSStackView(views: [logo, tf])
        stack.spacing = 6
        stack.alignment = .centerY
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    @objc private func activate(_ sender: Any?) {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, let c = rows[r].channel else { return }
        controller?.tune(c)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { activate(nil) } else { super.keyDown(with: event) }
    }
}
