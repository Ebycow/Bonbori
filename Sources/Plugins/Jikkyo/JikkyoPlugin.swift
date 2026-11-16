// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import BonboriPluginKit

/// ニコニコ実況: flows the comments on the channel being watched over the picture.
///
/// Decides when to be connected, with the server's load in mind: only while on and while the
/// video can be seen, only after staying on a channel for a moment, and at most so often,
/// backing off for as long as the server keeps refusing.
public final class JikkyoPlugin: NSObject, BonboriPlugin {
    public static let info = PluginInfo(id: "jikkyo", name: "ニコニコ実況", key: "j")

    /// Stay on a channel this long before connecting, so that zapping connects to nothing.
    private static let settleTime: TimeInterval = 3
    /// Time between two attempts to connect, whatever the reason.
    private static let minInterval: TimeInterval = 5
    /// Keep the connection this long after the video stops being visible.
    private static let hiddenGrace: TimeInterval = 30
    /// A connection that lasted this long counts as having worked.
    private static let stableTime: TimeInterval = 60
    private static let maxBackoff: TimeInterval = 300

    private let host: PluginHost
    private lazy var overlay = CommentOverlay(frame: .zero)
    private var isActive = false

    private var client: CommentConnection?
    private var clientChannel: Int?
    private var connectedAt = Date.distantPast
    private var viewers: Int?
    private var lastAttempt = Date.distantPast
    private var failures = 0
    private var retryAfter = Date.distantPast
    private var connectTimer: Timer?
    private var hiddenTimer: Timer?
    private var hiddenTooLong = false

    public required init(host: PluginHost) {
        self.host = host
        super.init()
    }

    public func activate() {
        isActive = true
        applyDisplaySettings()
        host.addOverlay(overlay)
        if host.service != nil, let text = unavailableText { host.showMessage(text, detail: nil) }
        update(settle: 0)
    }

    public func deactivate() {
        isActive = false
        connectTimer?.invalidate()
        hiddenTimer?.invalidate()
        hiddenTooLong = false
        closeClient()
        overlay.clear()
        host.removeOverlay(overlay)
    }

    public func handle(_ event: PluginEvent) {
        switch event {
        case .serviceChanged:
            overlay.clear()
            update(settle: JikkyoPlugin.settleTime)
        case .visibilityChanged:
            hiddenTimer?.invalidate()
            if host.isVideoVisible {
                hiddenTooLong = false
                update(settle: 0)
            } else {
                hiddenTimer = Timer.scheduledTimer(withTimeInterval: JikkyoPlugin.hiddenGrace, repeats: false) { [weak self] _ in
                    self?.hiddenTooLong = true
                    self?.update(settle: 0)
                }
            }
        case .playbackDelayChanged:
            overlay.clear()
        case .volumeChanged, .audioChanged:
            break
        }
    }

    /// The jk number of the channel being watched.
    private var channel: Int? {
        host.service.flatMap { ChannelTable.jikkyoID(networkID: $0.networkID, serviceID: $0.serviceID) }
    }

    /// Where the comments come from.
    private var source: CommentSource {
        get { host.defaults.string(forKey: "source").flatMap(CommentSource.init) ?? .nxJikkyo }
        set { host.defaults.set(newValue.rawValue, forKey: "source") }
    }

    /// Why there are no comments for the channel being watched, if so.
    private var unavailableText: String? {
        guard let channel else { return "このチャンネルの実況はありません" }
        return source.hasChannel(channel) ? nil : "このチャンネルの実況は\(source.title)にありません"
    }

    /// Where we should be connected now.
    private var wantedChannel: Int? {
        guard isActive, !hiddenTooLong, let channel, source.hasChannel(channel) else { return nil }
        return channel
    }

    /// Brings the connection in line with `wantedChannel`, after staying `settle` seconds on it.
    private func update(settle: TimeInterval) {
        connectTimer?.invalidate()
        if client != nil, clientChannel != wantedChannel { closeClient() }
        guard client == nil, wantedChannel != nil else { return }
        let earliest = max(lastAttempt.addingTimeInterval(JikkyoPlugin.minInterval), retryAfter)
        let wait = max(settle, earliest.timeIntervalSinceNow)
        connectTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in self?.connect() }
    }

    private func connect() {
        guard client == nil, let channel = wantedChannel else { return }
        host.log("connecting to jk\(channel) (\(source.rawValue))")
        lastAttempt = Date()
        guard let c = source.connect(jikkyoID: channel, log: { [weak host] in host?.log($0) }) else { return }
        c.onEvent = { [weak self] in self?.received($0) }
        client = c
        clientChannel = channel
        connectedAt = Date()
        viewers = nil
    }

    private func closeClient() {
        if client != nil { host.log("closing") }
        client?.close()
        client = nil
        clientChannel = nil
        viewers = nil
    }

    private func received(_ event: CommentEvent) {
        switch event {
        case .comment(let comment):
            if host.isVideoVisible { overlay.add(comment, delay: host.playbackDelay) }
        case .viewers(let n):
            viewers = n
        case .ended(let reason):
            let lasted = Date().timeIntervalSince(connectedAt)
            failures = lasted >= JikkyoPlugin.stableTime ? 1 : failures + 1
            let backoff = min(JikkyoPlugin.minInterval * pow(2, Double(failures - 1)), JikkyoPlugin.maxBackoff)
            retryAfter = Date().addingTimeInterval(backoff * .random(in: 0.8...1.2))
            host.log("connection ended after \(Int(lasted)) s (\(reason)): retrying in about \(Int(backoff)) s")
            closeClient()
            update(settle: 0)
        }
    }

    // MARK: - Menu

    private var statusText: String {
        if host.service == nil { return "選局していません" }
        guard let channel, unavailableText == nil else { return unavailableText ?? "" }
        if client == nil { return isActive ? "jk\(channel) 接続待ち" : "jk\(channel)" }
        return viewers.map { "jk\(channel) 接続中  \($0) 人" } ?? "jk\(channel) 接続しています…"
    }

    public func makeMenuItems() -> [NSMenuItem] {
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.indentationLevel = 1

        let size = NSMenuItem(title: "文字の大きさ", action: nil, keyEquivalent: "")
        size.indentationLevel = 1
        size.submenu = choices([("小さい", 18), ("標準", 14), ("大きい", 11)], current: lineCount, action: #selector(setLineCount(_:)))
        let opacity = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        opacity.indentationLevel = 1
        opacity.submenu = choices([("100%", 100), ("75%", 75), ("50%", 50)], current: opacityPercent, action: #selector(setOpacity(_:)))

        let from = NSMenuItem(title: "受信元", action: nil, keyEquivalent: "")
        from.indentationLevel = 1
        let sources = NSMenu()
        for (i, s) in CommentSource.allCases.enumerated() {
            let item = sources.addItem(withTitle: s.title, action: #selector(setSource(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = s == source ? .on : .off
        }
        from.submenu = sources
        return [status, from, size, opacity]
    }

    private func choices(_ list: [(String, Int)], current: Int, action: Selector) -> NSMenu {
        let menu = NSMenu()
        for (title, tag) in list {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = tag == current ? .on : .off
        }
        return menu
    }

    private var lineCount: Int {
        get { host.defaults.object(forKey: "lineCount") == nil ? 14 : host.defaults.integer(forKey: "lineCount") }
        set { host.defaults.set(newValue, forKey: "lineCount") }
    }

    private var opacityPercent: Int {
        get { host.defaults.object(forKey: "opacity") == nil ? 100 : host.defaults.integer(forKey: "opacity") }
        set { host.defaults.set(newValue, forKey: "opacity") }
    }

    @objc private func setSource(_ sender: NSMenuItem) {
        let new = CommentSource.allCases[sender.tag]
        guard new != source else { return }
        source = new
        guard isActive else { return }
        // The other server has not refused us.
        failures = 0
        retryAfter = .distantPast
        closeClient()
        overlay.clear()
        if host.service != nil, let text = unavailableText { host.showMessage(text, detail: nil) }
        update(settle: 0)
    }

    @objc private func setLineCount(_ sender: NSMenuItem) {
        lineCount = sender.tag
        applyDisplaySettings()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        opacityPercent = sender.tag
        applyDisplaySettings()
    }

    private func applyDisplaySettings() {
        if overlay.lineCount != lineCount { overlay.lineCount = lineCount }
        overlay.commentOpacity = Float(opacityPercent) / 100
    }
}
