// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import BonboriPluginKit

/// Owns the plugins and is the app's only contact with them: MainController reports its state
/// here, and each plugin sees it through its own `Slot`.
final class PluginManager: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private(set) var service: WatchedService?
    private(set) var isVideoVisible = true
    private(set) var playbackDelay: TimeInterval = 0
    /// What the app does for the plugins. Set before `start`.
    var audioSelection: () -> AudioSelection = { AudioSelection(index: 0, dualMono: 0) }
    var selectAudio: (AudioSelection) -> Void = { _ in }
    var tuneService: (_ networkID: Int, _ transportStreamID: Int, _ serviceID: Int) -> Bool = { _, _, _ in false }
    var tuneRemoteKey: (Int) -> Void = { _ in }

    private let player: Player
    private let videoView: VideoView
    private var slots: [Slot] = []

    /// One plugin and the host it talks to.
    private final class Slot: PluginHost {
        unowned let manager: PluginManager
        let info: PluginInfo
        let defaults: UserDefaults
        let overlays: NSView
        var plugin: BonboriPlugin!
        var isActive = false
        var captionHandler: ((CaptionPacket) -> Void)?
        var transportStreamHandler: ((TransportStreamBlock) -> Void)?

        init(_ type: BonboriPlugin.Type, manager: PluginManager) {
            self.manager = manager
            info = type.info
            defaults = UserDefaults(suiteName: "net.ebycow.bonbori.plugin.\(type.info.id)") ?? .standard
            overlays = manager.videoView.makePluginOverlayHost()
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
        var presentationTime: TimeInterval? { manager.player.isClockRunning ? manager.player.presentationTime : nil }
        var volume: Float { manager.player.isMuted ? 0 : manager.player.volume }
        var audioSelection: AudioSelection { manager.audioSelection() }

        func setCaptionHandler(_ handler: ((CaptionPacket) -> Void)?) {
            captionHandler = handler
            manager.updateCaptionTap()
        }

        func setTransportStreamHandler(_ handler: ((TransportStreamBlock) -> Void)?) {
            transportStreamHandler = handler
            manager.updateTransportStreamTap()
        }

        func addOverlay(_ view: NSView) {
            view.frame = overlays.bounds
            view.autoresizingMask = [.width, .height]
            overlays.addSubview(view)
        }

        func removeOverlay(_ view: NSView) { view.removeFromSuperview() }
        func setPictureRegion(_ region: CGRect?) { manager.videoView.setPictureRegion(region, ownedBy: overlays) }
        func tune(networkID: Int, transportStreamID: Int, serviceID: Int) -> Bool {
            manager.tuneService(networkID, transportStreamID, serviceID)
        }
        func tune(remoteKey: Int) { manager.tuneRemoteKey(remoteKey) }
        func selectAudio(_ selection: AudioSelection) { manager.selectAudio(selection) }
        func showMessage(_ title: String, detail: String?) { manager.videoView.showHUD(title, detail, duration: 3) }
        func log(_ message: String) {
            if envVar("DEBUG") != nil { debugLog(info.id, message) }
        }
    }

    init(player: Player, videoView: VideoView, plugins: [BonboriPlugin.Type]) {
        self.player = player
        self.videoView = videoView
        super.init()
        slots = plugins.map { Slot($0, manager: self) }
    }

    private func updateCaptionTap() {
        let handlers = slots.compactMap(\.captionHandler)
        player.setCaptions(handlers.isEmpty ? nil : { [weak self] packet in
            DispatchQueue.main.async {
                self?.slots.forEach { $0.captionHandler?(packet) }
            }
        })
    }

    private func updateTransportStreamTap() {
        let handlers = slots.compactMap(\.transportStreamHandler)
        player.setTransportStream(handlers.isEmpty ? nil : { [weak self] block in
            DispatchQueue.main.async {
                self?.slots.forEach { $0.transportStreamHandler?(block) }
            }
        })
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

    func volumeChanged() { send(.volumeChanged) }
    func audioChanged() { send(.audioChanged) }

    // MARK: - Capture

    /// The overlays that only their plugin can draw, in the order of the plugins.
    func overlaySnapshots(completion: @escaping ([CGImage]) -> Void) {
        let active = slots.filter(\.isActive)
        var images = [CGImage?](repeating: nil, count: active.count)
        let group = DispatchGroup()
        for (i, s) in active.enumerated() {
            group.enter()
            s.plugin.snapshotOverlay { image in
                images[i] = image
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(images.compactMap { $0 }) }
    }

    // MARK: - Keys and menus

    /// Offers a key to the active plugins before the app acts on it.
    func offerKey(_ event: NSEvent) -> Bool {
        slots.contains { $0.isActive && $0.plugin.handleKey(event) }
    }

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
