// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// How a plugin appears in the host.
public struct PluginInfo {
    /// Stable identifier: names the plugin's settings.
    public let id: String
    /// Shown in the プラグイン menu.
    public let name: String
    /// Turns the plugin on and off while the video has the keyboard focus.
    public let key: Character?

    public init(id: String, name: String, key: Character? = nil) {
        self.id = id
        self.name = name
        self.key = key
    }
}

/// A broadcast service, as the plugin needs to identify it.
public struct WatchedService: Equatable {
    public let networkID: Int  // original network id
    public let serviceID: Int
    public let name: String

    public init(networkID: Int, serviceID: Int, name: String) {
        self.networkID = networkID
        self.serviceID = serviceID
        self.name = name
    }
}

/// One PES of the ARIB captions of the service being watched.
public struct CaptionPacket {
    /// 文字スーパー rather than 字幕.
    public let isSuperimpose: Bool
    /// When to show it, on the clock of `PluginHost.presentationTime`. 文字スーパー have no time.
    public let presentationTime: TimeInterval?
    /// The PES payload.
    public let data: Data
    /// Changes when playback starts over, on a channel change or a new clock.
    public let generation: UInt32

    public init(isSuperimpose: Bool, presentationTime: TimeInterval?, data: Data, generation: UInt32) {
        self.isSuperimpose = isSuperimpose
        self.presentationTime = presentationTime
        self.data = data
        self.generation = generation
    }
}

/// Something in `PluginHost` changed.
public enum PluginEvent {
    case serviceChanged
    case visibilityChanged
    case playbackDelayChanged
}

/// A feature that the app can do without. It sees the app only through `PluginHost`, and is
/// listed in the app's `installedPlugins`. Everything here runs on the main thread.
public protocol BonboriPlugin: AnyObject {
    static var info: PluginInfo { get }

    /// Called once at launch, whether or not the plugin is on: do no work here.
    init(host: PluginHost)

    /// The plugin was turned on (also at launch, if it was on last time).
    func activate()
    /// The plugin was turned off, or the app is quitting: stop all work, close all connections.
    func deactivate()
    /// Only called while active.
    func handle(_ event: PluginEvent)
    /// Options, shown below the plugin in the プラグイン menu. Built each time the menu opens.
    func makeMenuItems() -> [NSMenuItem]
}

public extension BonboriPlugin {
    func handle(_ event: PluginEvent) {}
    func makeMenuItems() -> [NSMenuItem] { [] }
}

/// What the app offers to a plugin. Everything here is to be used on the main thread.
public protocol PluginHost: AnyObject {
    /// The service being watched. Nil when there is none, and while the tuner is only passing
    /// through channels (channel scan, 番組表の取得).
    var service: WatchedService? { get }
    /// False while nothing of the video can be seen (window covered, minimized, display off).
    var isVideoVisible: Bool { get }
    /// Seconds by which the picture is held back beyond normal live viewing (翻訳字幕).
    var playbackDelay: TimeInterval { get }
    /// Where the picture on screen is on the broadcast timeline. Nil until the clock runs after a tune.
    var presentationTime: TimeInterval? { get }
    /// The volume the viewer has chosen, 0 to 1; 0 while muted.
    var volume: Float { get }
    /// Settings of this plugin, kept apart from the app's.
    var defaults: UserDefaults { get }

    /// Starts (or with nil, stops) delivering the captions of the service being watched. They come
    /// through any delay of the picture, in order of arrival.
    func setCaptionHandler(_ handler: ((CaptionPacket) -> Void)?)
    /// Shows `view` over the picture and below subtitles and the HUD, and over the views of plugins
    /// listed before this one. It is kept the size of the picture, does not receive mouse events,
    /// and appears in captures.
    func addOverlay(_ view: NSView)
    func removeOverlay(_ view: NSView)
    /// Briefly shows a message over the video.
    func showMessage(_ title: String, detail: String?)
    /// BONBORI_DEBUG log line.
    func log(_ message: String)
}
