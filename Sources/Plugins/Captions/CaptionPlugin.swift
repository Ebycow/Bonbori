// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import BonboriPluginKit
import MediaAccessibility

/// 放送字幕: shows the ARIB captions and 文字スーパー of the broadcast over the picture.
///
/// Captions have the time of their speech on them, so they are held until the picture gets there,
/// which also takes care of a delayed picture. A timer runs only while something is waiting.
public final class CaptionPlugin: NSObject, BonboriPlugin {
    public static let info = PluginInfo(id: "captions", name: "放送字幕", key: "k")

    /// Anything further from the clock than this belongs to another timeline.
    private static let maxDistance: TimeInterval = 30
    /// How often to look again for a clock that is not running yet.
    private static let clockRetry: TimeInterval = 0.1

    /// Items that take effect at the same moment.
    private struct Batch {
        var items: [CaptionItem]
        /// On the host's presentation clock; nil means as soon as possible.
        var due: TimeInterval?
    }

    private let host: PluginHost
    private lazy var overlay = CaptionOverlay(frame: .zero)
    private let captions = CaptionStream()
    private let superimpose = CaptionStream()
    private var waiting: [CaptionOverlay.Plane: [Batch]] = [:]
    private var timer: Timer?
    private var generation: UInt32?
    private var appearanceObserver: NSObjectProtocol?

    public required init(host: PluginHost) {
        self.host = host
        super.init()
    }

    public func activate() {
        applySettings()
        host.addOverlay(overlay)
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String), object: nil, queue: .main
        ) { [weak self] _ in self?.applySettings() }
        host.setCaptionHandler { [weak self] in self?.received($0) }
    }

    public func deactivate() {
        host.setCaptionHandler(nil)
        appearanceObserver.map(NotificationCenter.default.removeObserver)
        appearanceObserver = nil
        reset()
        host.removeOverlay(overlay)
    }

    public func handle(_ event: PluginEvent) {
        switch event {
        case .serviceChanged:
            reset()
        case .playbackDelayChanged:
            forgetDisplayed()
        case .visibilityChanged, .volumeChanged, .audioChanged:
            break
        }
    }

    private func reset() {
        captions.reset()
        superimpose.reset()
        forgetDisplayed()
    }

    private func forgetDisplayed() {
        timer?.invalidate()
        timer = nil
        waiting = [:]
        overlay.clear()
    }

    // MARK: - Timing

    private func received(_ packet: CaptionPacket) {
        if packet.generation != generation {
            generation = packet.generation
            reset()
        }
        let plane: CaptionOverlay.Plane = packet.isSuperimpose ? .superimpose : .caption
        let stream = packet.isSuperimpose ? superimpose : captions
        let items = stream.feed([UInt8](packet.data))
        // still fed while hidden, so that turning it back on does not wait for the language again
        guard !items.isEmpty, shows(plane) else { return }

        let immediate = packet.isSuperimpose || timing == CaptionPlugin.asReceived
        let base = immediate ? host.presentationTime : packet.presentationTime
        let offset = packet.isSuperimpose || immediate ? 0 : TimeInterval(timing) / 1000
        // In order: a clear at the end of a statement must not overtake what it clears.
        var batches: [Batch] = []
        for item in items {
            if let last = batches.last, last.items.last?.wait == item.wait {
                batches[batches.count - 1].items.append(item)
            } else {
                batches.append(Batch(items: [item], due: base.map { $0 + offset + TimeInterval(item.wait) / 1000 }))
            }
        }
        waiting[plane, default: []] += batches
        showWhatIsDue()
    }

    private func showWhatIsDue() {
        timer?.invalidate()
        timer = nil
        var next: TimeInterval?
        for plane in CaptionOverlay.Plane.allCases {
            while let batch = waiting[plane]?.first {
                guard let due = batch.due else {
                    show(batch, on: plane)
                    continue
                }
                guard let now = host.presentationTime else {
                    next = CaptionPlugin.clockRetry
                    break
                }
                let wait = due - now
                if wait > 0, wait <= CaptionPlugin.maxDistance {
                    next = min(next ?? wait, wait)
                    break
                }
                if abs(wait) <= CaptionPlugin.maxDistance {
                    show(batch, on: plane)
                } else {
                    host.log("dropped a caption \(Int(wait)) s away from the clock")
                    waiting[plane]?.removeFirst()
                }
            }
        }
        guard let next else { return }
        // in the common mode, so that an open menu does not hold the captions back
        let t = Timer(timeInterval: next, repeats: false) { [weak self] _ in self?.showWhatIsDue() }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func show(_ batch: Batch, on plane: CaptionOverlay.Plane) {
        waiting[plane]?.removeFirst()
        if let due = batch.due, let now = host.presentationTime {
            host.log(String(format: "%@ showing %d items, %+.3f s from their time", "\(plane)", batch.items.count, now - due))
        }
        overlay.apply(batch.items, to: plane)
        guard playsSounds else { return }
        for case .row(let row) in batch.items {
            for run in row.runs {
                if let sound = run.sound { CaptionSounds.play(sound, volume: host.volume) }
            }
        }
    }

    // MARK: - Menu

    /// `timing` value: show captions as they arrive, ignoring their time.
    private static let asReceived = Int.max

    private var statusText: String {
        if host.service == nil { return "選局していません" }
        guard let language = captions.language else { return "字幕を待っています" }
        return "\(languageName(language)) 字幕"
    }

    private func languageName(_ language: CaptionStream.Language) -> String {
        Locale.current.localizedString(forLanguageCode: language.code) ?? language.code
    }

    public func makeMenuItems() -> [NSMenuItem] {
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.indentationLevel = 1
        var items = [status]

        if captions.languages.count > 1 {
            let language = option("言語", nil)
            let list = captions.languages.prefix(2).enumerated().map { (languageName($0.element), $0.offset) }
            language.submenu = choices(list, current: usesSecondLanguage ? 1 : 0, action: #selector(setLanguage(_:)))
            items.append(language)
        }
        let typeface = option("書体", nil)
        typeface.submenu = choices(CaptionTypeface.allCases.map { ($0.title, $0.rawValue) }, current: typefaceSetting.rawValue,
                                   action: #selector(setTypeface(_:)))
        items.append(typeface)
        let backdrop = option("文字の背景", nil)
        backdrop.submenu = choices(CaptionBackdrop.allCases.map { ($0.title, $0.rawValue) }, current: backdropSetting.rawValue,
                                   action: #selector(setBackdrop(_:)))
        items.append(backdrop)
        let timingItem = option("表示のタイミング", nil)
        timingItem.submenu = choices([("0.5 秒早める", -500), ("放送のとおり", 0), ("0.5 秒遅らせる", 500), ("1 秒遅らせる", 1000),
                                      ("受信したらすぐ", CaptionPlugin.asReceived)],
                                     current: timing, action: #selector(setTiming(_:)))
        items.append(timingItem)
        items.append(toggle("字幕を表示", showsCaptions, #selector(toggleCaptions)))
        items.append(toggle("文字スーパーを表示", showsSuperimpose, #selector(toggleSuperimpose)))
        items.append(toggle("振り仮名を隠す", hidesRuby, #selector(toggleRuby)))
        items.append(toggle("中央に小さく表示", isCentered, #selector(toggleCentered)))
        items.append(toggle("内蔵音を鳴らす", playsSounds, #selector(toggleSounds)))
        return items
    }

    private func option(_ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.indentationLevel = 1
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = option(title, action)
        item.state = on ? .on : .off
        return item
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

    // MARK: - Settings

    private var usesSecondLanguage: Bool {
        get { host.defaults.bool(forKey: "secondLanguage") }
        set { host.defaults.set(newValue, forKey: "secondLanguage") }
    }

    private var typefaceSetting: CaptionTypeface {
        get { CaptionTypeface(rawValue: host.defaults.integer(forKey: "typeface")) ?? .roundedGothic }
        set { host.defaults.set(newValue.rawValue, forKey: "typeface") }
    }

    private var backdropSetting: CaptionBackdrop {
        get { CaptionBackdrop(rawValue: host.defaults.integer(forKey: "backdrop")) ?? .broadcast }
        set { host.defaults.set(newValue.rawValue, forKey: "backdrop") }
    }

    /// Milliseconds, or `asReceived`.
    private var timing: Int {
        get { host.defaults.integer(forKey: "timing") }
        set { host.defaults.set(newValue, forKey: "timing") }
    }

    private var showsCaptions: Bool {
        get { host.defaults.object(forKey: "captions") == nil || host.defaults.bool(forKey: "captions") }
        set { host.defaults.set(newValue, forKey: "captions") }
    }

    private var showsSuperimpose: Bool {
        get { host.defaults.object(forKey: "superimpose") == nil || host.defaults.bool(forKey: "superimpose") }
        set { host.defaults.set(newValue, forKey: "superimpose") }
    }

    private var hidesRuby: Bool {
        get { host.defaults.bool(forKey: "hideRuby") }
        set { host.defaults.set(newValue, forKey: "hideRuby") }
    }

    private var isCentered: Bool {
        get { host.defaults.bool(forKey: "centered") }
        set { host.defaults.set(newValue, forKey: "centered") }
    }

    private var playsSounds: Bool {
        get { host.defaults.bool(forKey: "sounds") }
        set { host.defaults.set(newValue, forKey: "sounds") }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        usesSecondLanguage = sender.tag == 1
        applySettings()
        forgetDisplayed()
    }

    @objc private func setTypeface(_ sender: NSMenuItem) {
        typefaceSetting = CaptionTypeface(rawValue: sender.tag) ?? .roundedGothic
        applySettings()
    }

    @objc private func setBackdrop(_ sender: NSMenuItem) {
        backdropSetting = CaptionBackdrop(rawValue: sender.tag) ?? .broadcast
        applySettings()
    }

    @objc private func setTiming(_ sender: NSMenuItem) {
        timing = sender.tag
    }

    private func shows(_ plane: CaptionOverlay.Plane) -> Bool {
        switch plane {
        case .caption: return showsCaptions
        case .superimpose: return showsSuperimpose
        }
    }

    @objc private func toggleCaptions() {
        showsCaptions.toggle()
        hideIfOff(.caption)
    }

    @objc private func toggleSuperimpose() {
        showsSuperimpose.toggle()
        hideIfOff(.superimpose)
    }

    private func hideIfOff(_ plane: CaptionOverlay.Plane) {
        guard !shows(plane) else { return }
        waiting[plane] = nil
        overlay.clear(plane)
    }

    @objc private func toggleRuby() {
        hidesRuby.toggle()
        applySettings()
    }

    @objc private func toggleCentered() {
        isCentered.toggle()
        applySettings()
    }

    @objc private func toggleSounds() {
        playsSounds.toggle()
        if playsSounds { CaptionSounds.play(CaptionSounds.sample, volume: host.volume) }
    }

    private func applySettings() {
        captions.usesSecondLanguage = usesSecondLanguage
        superimpose.usesSecondLanguage = usesSecondLanguage
        overlay.isCentered = isCentered
        var options = CaptionRenderOptions()
        options.typeface = typefaceSetting
        options.backdrop = backdropSetting
        options.hidesRuby = hidesRuby
        options.appearance = .current
        overlay.options = options
    }
}

/// The receiver's built-in sounds (ARIB TR-B14). build-app.sh puts TVCaptionMod2's recordings into
/// the app when it finds them; an app built without them makes do with the sounds of the system.
enum CaptionSounds {
    /// A short one, to show what turning the sounds on does.
    static let sample = 5

    private static var loaded: [Int: NSSound] = [:]

    /// 速報チャイム 2 to 5 share one recording.
    static func fileName(for index: Int) -> String? {
        switch index {
        case 0: return "00"
        case 1...4: return "01"
        case 5...13: return String(format: "%02d", index)
        default: return nil
        }
    }

    private static func systemSound(for index: Int) -> NSSound? {
        switch index {
        case 0...4: return NSSound(named: "Glass")   // 速報チャイム
        case 5...12: return NSSound(named: "Tink")   // ボタン操作音
        case 13: return NSSound(named: "Sosumi")     // アラート音
        default: return nil
        }
    }

    private static func sound(for index: Int) -> NSSound? {
        guard let name = fileName(for: index) else { return nil }
        if let sound = loaded[index] { return sound }
        let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "CaptionSounds")
        let sound = url.flatMap { NSSound(contentsOf: $0, byReference: true) } ?? systemSound(for: index)
        loaded[index] = sound
        return sound
    }

    static func play(_ index: Int, volume: Float) {
        guard let sound = sound(for: index) else { return }
        sound.stop()
        sound.volume = volume
        sound.play()
    }
}
