// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// The Touch Bar of the main window: 地デジ/BS/CS, the channels of that kind to scrub through,
/// the buttons of the plugins, and the controls that are also on the keyboard.
/// The viewer can rearrange it with 表示 → Touch Bar をカスタマイズ.
final class MainTouchBar: NSObject, NSTouchBarDelegate, NSScrubberDataSource, NSScrubberFlowLayoutDelegate {
    private unowned let controller: MainController
    private let store = ChannelStore.shared

    /// The channels in the scrubber, of the kind being watched.
    private var channels: [Channel] = []
    /// The channel the scrubber shows as being watched.
    private var shownIndex: Int?
    private weak var kindControl: NSSegmentedControl?
    private weak var scrubber: NSScrubber?
    /// The items that show some state. The same item can be in the bar and in the volume popover.
    private let stateItems = NSHashTable<NSTouchBarItem>.weakObjects()

    private static let channelItem = NSUserInterfaceItemIdentifier("channel")

    init(controller: MainController) {
        self.controller = controller
        super.init()
    }

    /// A new Touch Bar, with the plugins' items as they are now.
    func make(pluginItems: [NSTouchBarItem]) -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = "net.ebycow.bonbori.main"
        bar.templateItems = Set(pluginItems)
        let plugins = pluginItems.map(\.identifier)
        bar.defaultItemIdentifiers = [.kind, .channels] + plugins + [.record, .volume, .otherItemsProxy]
        bar.customizationAllowedItemIdentifiers = [.kind, .channels] + plugins
            + [.record, .capture, .subtitles, .channelList, .programGuide, .fullScreen, .volume, .mute, .volumeSlider,
               .flexibleSpace, .fixedSpaceSmall, .fixedSpaceLarge]
        bar.customizationRequiredItemIdentifiers = [.channels]
        return bar
    }

    // MARK: - Items

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item: NSTouchBarItem
        switch id {
        case .kind:
            item = makeKindItem()
        case .channels:
            item = makeChannelsItem()
        case .volume:
            item = makeVolumeItem()
        case .volumeSlider:
            item = makeVolumeSlider()
        case .mute:
            item = button(id, "ミュート", "speaker.slash", #selector(MainController.toggleMute(_:)))
        case .record:
            item = button(id, "録画", "record.circle", #selector(MainController.toggleRecording(_:)))
        case .capture:
            item = button(id, "キャプチャ", "camera", #selector(MainController.capture(_:)))
            item.visibilityPriority = .low
        case .subtitles:
            item = button(id, "翻訳字幕", "captions.bubble", #selector(MainController.toggleSubtitles(_:)))
            item.visibilityPriority = .low
        case .channelList:
            item = button(id, "チャンネル一覧", "list.bullet", #selector(MainController.toggleChannelList(_:)))
            item.visibilityPriority = .low
        case .programGuide:
            item = button(id, "番組表", "calendar", #selector(MainController.toggleProgramGuide(_:)))
            item.visibilityPriority = .low
        case .fullScreen:
            // through the responder chain to the window
            let b = NSButtonTouchBarItem(identifier: id, image: symbol("arrow.up.left.and.arrow.down.right", "フルスクリーン"),
                                         target: nil, action: #selector(NSWindow.toggleFullScreen(_:)))
            b.customizationLabel = "フルスクリーン"
            b.visibilityPriority = .low
            item = b
        default:
            return nil
        }
        stateItems.add(item)
        refresh()
        return item
    }

    private func symbol(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }

    private func button(_ id: NSTouchBarItem.Identifier, _ label: String, _ image: String, _ action: Selector) -> NSButtonTouchBarItem {
        let b = NSButtonTouchBarItem(identifier: id, image: symbol(image, label), target: controller, action: action)
        b.customizationLabel = label
        return b
    }

    private func makeKindItem() -> NSTouchBarItem {
        let control = NSSegmentedControl(labels: SpaceKind.allCases.map(\.title), trackingMode: .selectOne,
                                         target: self, action: #selector(kindChosen(_:)))
        for k in SpaceKind.allCases { control.setWidth(46, forSegment: k.rawValue) }
        kindControl = control
        let item = NSCustomTouchBarItem(identifier: .kind)
        item.view = control
        item.customizationLabel = "地デジ / BS / CS"
        return item
    }

    private func makeChannelsItem() -> NSTouchBarItem {
        let s = NSScrubber()
        s.register(ChannelItemView.self, forItemIdentifier: Self.channelItem)
        let layout = NSScrubberFlowLayout()
        layout.itemSpacing = 4
        s.scrubberLayout = layout
        s.mode = .free
        s.showsAdditionalContentIndicators = true
        s.dataSource = self
        s.delegate = self
        s.widthAnchor.constraint(equalToConstant: 250).isActive = true
        scrubber = s
        shownIndex = nil
        // It only scrolls once it has its items, which is after it is in the bar.
        DispatchQueue.main.async { [weak self, weak s] in
            guard let self, let s else { return }
            self.showCurrentChannel(in: s, reloaded: true)
        }
        let item = NSCustomTouchBarItem(identifier: .channels)
        item.view = s
        item.customizationLabel = "チャンネル"
        item.visibilityPriority = .high
        return item
    }

    /// A speaker that opens the mute button and the volume slider, like the one of the system.
    private func makeVolumeItem() -> NSTouchBarItem {
        let item = NSPopoverTouchBarItem(identifier: .volume)
        item.collapsedRepresentationImage = symbol("speaker.wave.2.fill", "音量")
        item.customizationLabel = "音量"
        item.visibilityPriority = .high
        let popover = NSTouchBar()
        popover.delegate = self
        popover.defaultItemIdentifiers = [.mute, .volumeSlider]
        item.popoverTouchBar = popover
        return item
    }

    private func makeVolumeSlider() -> NSTouchBarItem {
        let item = NSSliderTouchBarItem(identifier: .volumeSlider)
        item.slider.minValue = 0
        item.slider.maxValue = 1
        item.minimumValueAccessory = NSSliderAccessory(image: symbol("speaker.fill", "音量を下げる"))
        item.maximumValueAccessory = NSSliderAccessory(image: symbol("speaker.wave.3.fill", "音量を上げる"))
        item.valueAccessoryWidth = .default
        item.maximumSliderWidth = 400
        item.target = self
        item.action = #selector(volumeSlid(_:))
        item.customizationLabel = "音量スライダー"
        return item
    }

    // MARK: - Actions

    @objc private func kindChosen(_ sender: NSSegmentedControl) {
        guard let kind = SpaceKind(rawValue: sender.selectedSegment) else { return }
        if kind == controller.currentChannel?.kind { return }
        controller.switchKind(kind)
        // with no channel of that kind, nothing changes
        refresh()
    }

    @objc private func volumeSlid(_ sender: NSSliderTouchBarItem) {
        controller.setVolume(Float(sender.doubleValue))
    }

    // MARK: - State

    /// Shows what is being watched and played. Called by the controller whenever that changes.
    func refresh() {
        let kind = controller.currentChannel?.kind ?? .terrestrial
        if let c = kindControl {
            c.selectedSegment = kind.rawValue
            for k in SpaceKind.allCases { c.setEnabled(!store.channels(of: k).isEmpty, forSegment: k.rawValue) }
        }
        let list = store.channels(of: kind)
        let reloaded = list.map(\.id) != channels.map(\.id)
        if reloaded { channels = list }
        if let s = scrubber { showCurrentChannel(in: s, reloaded: reloaded) }
        let player = controller.player
        for item in stateItems.allObjects {
            switch (item.identifier, item) {
            case (.volumeSlider, let slider as NSSliderTouchBarItem):
                slider.doubleValue = Double(player.volume)
            case (.volume, let popover as NSPopoverTouchBarItem):
                popover.collapsedRepresentationImage = symbol(player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", "音量")
            case (.mute, let b as NSButtonTouchBarItem):
                b.bezelColor = player.isMuted ? .controlAccentColor : nil
            case (.record, let b as NSButtonTouchBarItem):
                b.bezelColor = player.isRecording ? .systemRed : nil
            case (.subtitles, let b as NSButtonTouchBarItem):
                b.bezelColor = Settings.shared.subtitles ? .controlAccentColor : nil
            default:
                break
            }
        }
    }

    /// Marks the channel being watched and brings it into view. `reloaded`: the channels have changed.
    private func showCurrentChannel(in s: NSScrubber, reloaded: Bool = false) {
        let index = channels.firstIndex { $0.id == controller.currentChannel?.id }
        // A new scrubber has not asked for its items yet.
        if reloaded || s.numberOfItems != channels.count {
            s.reloadData()
        } else if index != shownIndex {
            // On the views on show rather than by reloadItems, which leaves the old views behind
            // while the scrubber is handling a tap; the others are marked when they come into view.
            for i in [shownIndex, index].compactMap({ $0 }) where channels.indices.contains(i) {
                (s.itemViewForItem(at: i) as? ChannelItemView)?.isCurrent = i == index
            }
        } else {
            return
        }
        shownIndex = index
        // so that tapping another channel always counts as a new selection
        s.selectedIndex = index ?? -1
        if let index { s.scrollItem(at: index, to: .center) }
    }

    // MARK: - Scrubber

    private func title(_ ch: Channel) -> String {
        ch.remoteKey > 0 ? "\(ch.remoteKey) \(ch.name)" : ch.name
    }

    func numberOfItems(for scrubber: NSScrubber) -> Int {
        channels.count
    }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = scrubber.makeItem(withIdentifier: Self.channelItem, owner: nil) as! ChannelItemView
        view.label.stringValue = title(channels[index])
        view.isCurrent = channels[index].id == controller.currentChannel?.id
        return view
    }

    func scrubber(_ scrubber: NSScrubber, layout: NSScrubberFlowLayout, sizeForItemAt index: Int) -> NSSize {
        let width = (title(channels[index]) as NSString).size(withAttributes: [.font: ChannelItemView.font]).width
        return NSSize(width: ceil(width) + 24, height: 30)
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        guard channels.indices.contains(index), channels[index].id != controller.currentChannel?.id else { return }
        controller.tune(channels[index])
    }
}

/// A channel in the scrubber, on a background if it is being watched.
private final class ChannelItemView: NSScrubberItemView {
    static let font = NSFont.systemFont(ofSize: 0)
    let label = NSTextField(labelWithString: "")

    var isCurrent = false {
        didSet { layer?.backgroundColor = isCurrent ? NSColor(white: 1, alpha: 0.3).cgColor : nil }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = Self.font
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private extension NSTouchBarItem.Identifier {
    static let kind = Self("net.ebycow.bonbori.kind")
    static let channels = Self("net.ebycow.bonbori.channels")
    static let volume = Self("net.ebycow.bonbori.volume")
    static let volumeSlider = Self("net.ebycow.bonbori.volumeSlider")
    static let mute = Self("net.ebycow.bonbori.mute")
    static let record = Self("net.ebycow.bonbori.record")
    static let capture = Self("net.ebycow.bonbori.capture")
    static let subtitles = Self("net.ebycow.bonbori.subtitles")
    static let channelList = Self("net.ebycow.bonbori.channelList")
    static let programGuide = Self("net.ebycow.bonbori.programGuide")
    static let fullScreen = Self("net.ebycow.bonbori.fullScreen")
}
