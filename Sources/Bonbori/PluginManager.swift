// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import BonboriPluginKit

/// Owns the plugins and is the app's only contact with them: MainController reports its state
/// here, and each plugin sees it through its own `Slot`.
final class PluginManager: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private(set) var service: WatchedService?
    private(set) var isVideoVisible = true
    private(set) var playbackDelay: TimeInterval = 0

    private let videoView: VideoView
    private var slots: [Slot] = []

    /// One plugin and the host it talks to.
    private final class Slot: PluginHost {
        unowned let manager: PluginManager
        let info: PluginInfo
        let defaults: UserDefaults
        var plugin: BonboriPlugin!
        var isActive = false

        init(_ type: BonboriPlugin.Type, manager: PluginManager) {
            self.manager = manager
            info = type.info
            defaults = UserDefaults(suiteName: "net.ebycow.bonbori.plugin.\(type.info.id)") ?? .standard
            plugin = type.init(host: self)
        }

        var enabledKey: String { "plugin.\(info.id).enabled" }
        var isEnabled: Bool {
            get { UserDefaults.standard.bool(forKey: enabledKey) }
            set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
        }

        var service: WatchedService? { manager.service }
        var isVideoVisible: Bool { manager.isVideoVisible }
        var playbackDelay: TimeInterval { manager.playbackDelay }

        func addOverlay(_ view: NSView) { manager.videoView.addPluginOverlay(view) }
        func removeOverlay(_ view: NSView) { view.removeFromSuperview() }
        func showMessage(_ title: String, detail: String?) { manager.videoView.showHUD(title, detail, duration: 3) }
        func log(_ message: String) {
            if envVar("DEBUG") != nil { debugLog(info.id, message) }
        }
    }

    init(videoView: VideoView, plugins: [BonboriPlugin.Type]) {
        self.videoView = videoView
        super.init()
        slots = plugins.map { Slot($0, manager: self) }
    }

    func start() {
        for s in slots where s.isEnabled { setActive(s, true) }
    }

    /// The app is quitting. The plugins stay enabled for the next launch.
    func stop() {
        for s in slots { setActive(s, false) }
    }

    private func setActive(_ s: Slot, _ on: Bool) {
        guard s.isActive != on else { return }
        s.isActive = on
        if on { s.plugin.activate() } else { s.plugin.deactivate() }
    }

    private func toggle(_ s: Slot) {
        s.isEnabled.toggle()
        // first, so that the plugin can replace it with something more telling
        videoView.showHUD("\(s.info.name) \(s.isEnabled ? "オン" : "オフ")", nil, duration: 2)
        setActive(s, s.isEnabled)
    }

    private func send(_ event: PluginEvent) {
        for s in slots where s.isActive { s.plugin.handle(event) }
    }

    // MARK: - State reported by the app

    func update(service new: WatchedService?) {
        guard new != service else { return }
        service = new
        send(.serviceChanged)
    }

    func update(isVideoVisible new: Bool) {
        guard new != isVideoVisible else { return }
        isVideoVisible = new
        send(.visibilityChanged)
    }

    func update(playbackDelay new: TimeInterval) {
        guard new != playbackDelay else { return }
        playbackDelay = new
        send(.playbackDelayChanged)
    }

    // MARK: - Keys and menus

    func handleKey(_ c: Character) -> Bool {
        guard let s = slots.first(where: { $0.info.key == c }) else { return false }
        toggle(s)
        return true
    }

    /// The プラグイン menu, or nil if there are no plugins.
    func makeMenu() -> NSMenu? {
        guard !slots.isEmpty else { return nil }
        let menu = NSMenu(title: "プラグイン")
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (i, s) in slots.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            let key = s.info.key.map { " (\($0.uppercased()))" } ?? ""
            let item = menu.addItem(withTitle: s.info.name + key, action: #selector(toggleItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            for option in s.plugin.makeMenuItems() { menu.addItem(option) }
        }
    }

    @objc private func toggleItem(_ sender: NSMenuItem) {
        toggle(slots[sender.tag])
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleItem(_:)) { item.state = slots[item.tag].isEnabled ? .on : .off }
        return true
    }
}
