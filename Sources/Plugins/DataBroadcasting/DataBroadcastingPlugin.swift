// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import BonboriPluginKit
import SwiftUI

/// データ放送: shows the BML of the broadcast over the picture, and lets the document place the
/// picture, like the data button of a TV. See `BMLBrowser` for how the document is run.
public final class DataBroadcastingPlugin: NSObject, BonboriPlugin {
    public static let info = PluginInfo(id: "databroadcasting", name: "データ放送", key: "g")

    /// About ten seconds of TS, which is what the page can fall behind by. A document repeats on its
    /// carousel, so what is dropped comes round again.
    private static let maxPendingBlocks = 100
    /// How long the TS of the last channel may keep coming after a channel change.
    private static let tuneTimeout: TimeInterval = 3

    private let host: PluginHost
    private let network = BMLNetwork()
    private var browser: BMLBrowser?
    private var remote: RemoteControlPanel?
    private var inputSheet: TextInputSheet?
    private var settingsWindow: NSWindow?

    /// The generation of TS that the page was loaded for, and until when to wait for a new one.
    private var generation: UInt32?
    private var previousGeneration: (value: UInt32, deadline: Date)?
    private var pending: [Data] = []
    private var isSending = false

    private var isDocumentLoaded = false
    /// The document has nothing on show: the picture is the whole screen and keys are for the app.
    private var isInvisible = true
    /// Arrow keys and the like go to the document. Starts with the data button or when the document
    /// makes room for itself, and ends when it goes away.
    private var hasKeyFocus = false
    private var usedKeys: Set<KeyGroup> = [.basic, .dataButton]
    /// What to go back to when a document has changed the sound.
    private var mainAudio: AudioSelection?

    public required init(host: PluginHost) {
        self.host = host
        super.init()
    }

    public func activate() {
        guard let resources = BMLBrowser.resources else {
            host.showMessage("データ放送を表示できません", detail: "アプリにデータ放送の部品が含まれていません（build-app.sh には npm が必要です）")
            return
        }
        let browser = BMLBrowser(resources: resources, network: network, debug: ProcessInfo.processInfo.environment["BONBORI_DEBUG"] != nil)
        browser.log = { [host] in host.log($0) }
        browser.onMessage = { [weak self] in self?.received(message: $0) }
        browser.onPageLoaded = { [weak self] in self?.pageLoaded() }
        browser.onPageLost = { [weak self] in
            self?.generation = nil
            self?.isSending = false
        }
        self.browser = browser
        network.isEnabled = usesNetwork
        host.addOverlay(browser.webView)
        browser.prepare { [weak self] in
            guard let self, self.browser === browser else { return }
            self.host.setTransportStreamHandler { [weak self] in self?.received($0) }
        }
        if showsRemote { showRemote() }
    }

    public func deactivate() {
        host.setTransportStreamHandler(nil)
        reset()
        generation = nil
        previousGeneration = nil
        isSending = false
        network.cancelAll()
        remote?.close()
        settingsWindow.map { $0.sheetParent?.endSheet($0) }
        browser?.close()
        browser = nil
    }

    public func handle(_ event: PluginEvent) {
        switch event {
        case .serviceChanged:
            reset()
            if let generation { previousGeneration = (generation, Date().addingTimeInterval(DataBroadcastingPlugin.tuneTimeout)) }
        case .volumeChanged:
            browser?.call("volume", [host.volume])
        case .audioChanged:
            mainAudioChanged()
        case .visibilityChanged, .playbackDelayChanged:
            break
        }
    }

    /// Takes the document of the last channel off the screen.
    private func reset() {
        inputSheet?.cancel()
        inputSheet = nil
        pending = []
        isDocumentLoaded = false
        isInvisible = true
        hasKeyFocus = false
        usedKeys = [.basic, .dataButton]
        browser?.webView.isHidden = true
        host.setPictureRegion(nil)
        restoreMainAudio()
    }

    // MARK: - The stream

    private func received(_ block: TransportStreamBlock) {
        guard let browser, let service = host.service else { return }
        if let previous = previousGeneration {
            if block.generation == previous.value, Date() < previous.deadline { return }
            previousGeneration = nil
            generation = nil
        }
        if block.generation != generation {
            generation = block.generation
            pending = []
            browser.webView.isHidden = false
            browser.load(serviceID: service.serviceID)
        }
        pending.append(block.data)
        if pending.count > DataBroadcastingPlugin.maxPendingBlocks { pending.removeFirst() }
        sendPending()
    }

    private func sendPending() {
        guard let browser, browser.isPageLoaded, !isSending, !pending.isEmpty else { return }
        isSending = true
        let data = pending.count == 1 ? pending[0] : pending.reduce(into: Data()) { $0.append($1) }
        pending = []
        browser.stream(data) { [weak self] in
            self?.isSending = false
            self?.sendPending()
        }
    }

    private func pageLoaded() {
        browser?.call("volume", [host.volume])
        browser?.call("enableNetwork", [usesNetwork])
        mainAudioChanged()
        sendPending()
    }

    // MARK: - Messages from the page

    private func received(message: [String: Any]) {
        switch message["type"] as? String {
        case "video":
            videoChanged(message)
        case "documentLoaded":
            isDocumentLoaded = true
        case "usedKeyList":
            usedKeys = Set((message["usedKeyList"] as? [String] ?? []).compactMap(KeyGroup.init(rawValue:)))
        case "tune":
            tune(message)
        case "input":
            showInput(message)
        case "cancelInput":
            inputSheet?.cancel()
            inputSheet = nil
        case "changeAudioStream":
            changeAudioStream(message)
        case "changeMainAudioStream":
            changeMainAudioStream(message)
        case "startBrowser":
            (message["uri"] as? String).map(confirmOpening)
        case "error":
            host.showMessage(message["title"] as? String ?? "データ放送", detail: message["message"] as? String)
        case "log":
            host.log(message["text"] as? String ?? "")
        default:
            break
        }
    }

    private func videoChanged(_ message: [String: Any]) {
        let number = { (key: String) in (message[key] as? NSNumber)?.doubleValue ?? 0 }
        isInvisible = message["invisible"] as? Bool ?? true
        let isFullScreen = message["fullScreen"] as? Bool ?? true
        if isInvisible {
            hasKeyFocus = false
        } else if !isFullScreen {
            hasKeyFocus = true
        }
        let region = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
        if isInvisible || isFullScreen {
            host.setPictureRegion(nil)
        } else if !region.isEmpty {
            host.setPictureRegion(region)
        }
    }

    private func tune(_ message: [String: Any]) {
        guard let network = message["originalNetworkId"] as? Int, let ts = message["transportStreamId"] as? Int,
              let service = message["serviceId"] as? Int else { return }
        if !host.tune(networkID: network, transportStreamID: ts, serviceID: service) {
            host.showMessage("データ放送からの選局に失敗しました", detail: "映像や音声のないサービスか、チャンネルスキャンされていないチャンネルです")
        }
    }

    private func showInput(_ message: [String: Any]) {
        guard let request = TextInputRequest(message), let window = browser?.webView.window, window.attachedSheet == nil else {
            browser?.call("cancelInput")
            return
        }
        let sheet = TextInputSheet(request) { [weak self] text in
            self?.inputSheet = nil
            if let text {
                self?.browser?.call("changeInput", [text])
            } else {
                self?.browser?.call("cancelInput")
            }
        }
        inputSheet = sheet
        sheet.begin(on: window)
    }

    /// A document may ask to open a site in a browser. Broadcasts are not to do that on their own.
    private func confirmOpening(_ uri: String) {
        guard let url = URL(string: uri), ["http", "https"].contains(url.scheme?.lowercased()),
              let window = browser?.webView.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "ブラウザで開きますか？"
        alert.informativeText = "データ放送が次のページを開こうとしています。\n\(uri)"
        alert.addButton(withTitle: "開く")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: - Sound

    private func selection(index: Int, channelID: Int?) -> AudioSelection {
        // 第一チャンネル, 第二チャンネル; 両方 is the same as no choice
        AudioSelection(index: index, dualMono: channelID == 1 || channelID == 2 ? channelID! : 0)
    }

    private func changeAudioStream(_ message: [String: Any]) {
        guard let component = message["componentId"] as? Int, let index = message["index"] as? Int else { return }
        if component < 0 {
            restoreMainAudio()
        } else if index >= 0 {
            mainAudio = mainAudio ?? host.audioSelection
            host.selectAudio(selection(index: index, channelID: message["channelId"] as? Int))
        }
    }

    private func changeMainAudioStream(_ message: [String: Any]) {
        guard let index = message["index"] as? Int else { return }
        let main = selection(index: index, channelID: message["channelId"] as? Int)
        if mainAudio != nil {
            mainAudio = main
        } else {
            host.selectAudio(main)
        }
    }

    private func restoreMainAudio() {
        mainAudio.map(host.selectAudio)
        mainAudio = nil
    }

    private func mainAudioChanged() {
        guard mainAudio == nil else { return }
        let audio = host.audioSelection
        browser?.call("mainAudioStreamChanged", audio.dualMono == 0 ? [audio.index] : [audio.index, audio.dualMono])
    }

    // MARK: - Keys

    public func handleKey(_ event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers?.lowercased() == "g" {
            press(.dataButton)
            return true
        }
        guard hasKeyFocus, let key = RemoteKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers),
              let group = key.group, usedKeys.contains(group) else { return false }
        browser?.call("key", [key.rawValue])
        return true
    }

    /// A button of the remote control.
    private func press(_ key: RemoteKey) {
        if key == .dataButton {
            if !isDocumentLoaded {
                host.showMessage("データ放送を受信しています", detail: "放送局によっては表示できるまで 1 分近くかかります")
                return
            }
            // A document that does not answer must not keep the arrow keys from the app.
            hasKeyFocus.toggle()
        } else if let group = key.group, !usedKeys.contains(group) {
            if let number = key.number, number > 0 { host.tune(remoteKey: number) }
            return
        }
        browser?.call("key", [key.rawValue])
    }

    // MARK: - Capture

    public func snapshotOverlay(completion: @escaping (CGImage?) -> Void) {
        guard let webView = browser?.webView, !isInvisible else {
            completion(nil)
            return
        }
        webView.takeSnapshot(with: nil) { image, _ in
            completion(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    // MARK: - Menu

    private var showsRemote: Bool {
        get { host.defaults.bool(forKey: "showRemote") }
        set { host.defaults.set(newValue, forKey: "showRemote") }
    }

    private var usesNetwork: Bool {
        get { host.defaults.bool(forKey: "network") }
        set {
            host.defaults.set(newValue, forKey: "network")
            network.isEnabled = newValue
            browser?.call("enableNetwork", [newValue])
        }
    }

    public func makeMenuItems() -> [NSMenuItem] {
        [
            item("リモコンを表示", #selector(toggleRemote(_:)), on: showsRemote),
            item("通信機能を使う", #selector(toggleNetwork(_:)), on: usesNetwork),
            item("受信機の設定…", #selector(showSettings(_:))),
            item("再読み込み", #selector(reload(_:))),
        ]
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.indentationLevel = 1
        item.state = on ? .on : .off
        return item
    }

    private func showRemote() {
        if remote == nil {
            remote = RemoteControlPanel { [weak self] in self?.press($0) }
            remote?.onClose = { [weak self] in self?.showsRemote = false }
        }
        remote?.show()
    }

    @objc private func toggleRemote(_ sender: NSMenuItem) {
        showsRemote.toggle()
        if showsRemote {
            if browser != nil { showRemote() }
        } else {
            remote?.close()
        }
    }

    @objc private func toggleNetwork(_ sender: NSMenuItem) {
        usesNetwork.toggle()
        host.showMessage(usesNetwork ? "データ放送の通信機能 オン" : "データ放送の通信機能 オフ", detail: nil)
    }

    @objc private func reload(_ sender: NSMenuItem) {
        reset()
        generation = nil
    }

    @objc private func showSettings(_ sender: NSMenuItem) {
        guard let browser, browser.isPageLoaded, let window = browser.webView.window, window.attachedSheet == nil else {
            host.showMessage("データ放送の受信中に設定できます", detail: nil)
            return
        }
        Task { @MainActor in
            let zip = (await nvramRead("zipcode", "S:7B"))?.first as? String ?? ""
            let code = (await nvramRead("regioncode", "U:2B"))?.first as? Int
            let prefecture = (await nvramRead("prefecture", "U:1B"))?.first as? Int
            let region = ReceiverRegion.all.first { $0.prefecture == prefecture && $0.regionCode == code } ?? .unset
            presentSettings(ReceiverSettingsModel(zipCode: zip.filter(\.isNumber), region: region), on: window)
        }
    }

    private func presentSettings(_ model: ReceiverSettingsModel, on window: NSWindow) {
        let close = { [weak self] in
            self?.settingsWindow.map { $0.sheetParent?.endSheet($0) }
            self?.settingsWindow = nil
        }
        let view = ReceiverSettingsView(model: model, onSave: { [weak self] zip, region in
            self?.nvramWrite("zipcode", "S:7B", zip)
            self?.nvramWrite("prefecture", "U:1B", region.prefecture)
            self?.nvramWrite("regioncode", "U:2B", region.regionCode)
            close()
        }, onDeleteAll: { [weak self] in
            self?.browser?.call("nvramDelete")
            close()
        }, onClose: close)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        settingsWindow = sheet
        window.beginSheet(sheet, completionHandler: nil)
    }

    private func nvramRead(_ name: String, _ structure: String) async -> [Any]? {
        await withCheckedContinuation { continuation in
            guard let browser else { return continuation.resume(returning: nil) }
            browser.call("nvramRead", ["nvram://receiverinfo/\(name)", structure]) {
                continuation.resume(returning: $0 as? [Any])
            }
        }
    }

    private func nvramWrite(_ name: String, _ structure: String, _ value: Any) {
        browser?.call("nvramWrite", ["nvram://receiverinfo/\(name)", structure, [value]])
    }
}

extension DataBroadcastingPlugin: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(reload(_:)), #selector(showSettings(_:)):
            return browser != nil
        default:
            return true
        }
    }
}
