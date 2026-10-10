// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// 番組表の取得: tunes through the channels with the viewing tuner and stays on each one until
/// its EIT schedule is complete (port of TVTest's CEpgCaptureManager).
///
/// Satellites send the basic schedule of every service of the network on each transponder, so one
/// transponder per network is enough there; terrestrial schedules are per TS.
final class EPGCapture {
    struct Stop {
        let tune: Channel
        let services: [Channel]
        let satellite: Bool
        var title: String { "\(tune.kind.title) \(tune.name)" }
    }

    private(set) var stops: [Stop] = []
    private(set) var index = -1
    private var stopStarted = Date()
    private var timer: Timer?
    private let tuneHandler: (Channel) -> Void
    private let finishHandler: () -> Void
    /// Progress changed (main thread).
    var onChange: (() -> Void)?

    var isRunning: Bool { index >= 0 }
    var current: Stop? { isRunning ? stops[index] : nil }

    init(tune: @escaping (Channel) -> Void, finished: @escaping () -> Void) {
        tuneHandler = tune
        finishHandler = finished
    }

    @discardableResult
    func start(kinds: [SpaceKind]) -> Bool {
        guard !isRunning else { return false }
        var order: [String] = []
        var groups: [String: [Channel]] = [:]
        for c in ChannelStore.shared.channels where ChannelStore.isTV(c) && kinds.contains(c.kind) {
            let k = c.kind == .terrestrial ? "\(c.group)/\(c.space)/\(c.channel)" : "\(c.group)/network/\(c.onid)"
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(c)
        }
        stops = order.map { k in
            let list = groups[k]!
            return Stop(tune: list[0], services: list, satellite: list[0].kind != .terrestrial)
        }
        guard !stops.isEmpty else { return false }
        index = -1
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        next()
        return true
    }

    /// Stops without returning to the channel that was being watched.
    func cancel() {
        guard isRunning else { return }
        end(notify: false)
    }

    /// The channel could not be tuned: move on.
    func skip() {
        if isRunning { next() }
    }

    /// Rough estimate, as in TVTest: 3 minutes per satellite network, 1 minute per terrestrial TS.
    var remainingTime: TimeInterval {
        guard isRunning else { return 0 }
        return stops[index...].reduce(0) { $0 + ($1.satellite ? 180 : 60) }
    }

    private func tick() {
        guard let stop = current else { return }
        let elapsed = Date().timeIntervalSince(stopStarted)
        guard elapsed >= 15 else { return }

        var complete = true, basic = false, noBasic = false
        for c in stop.services {
            let st = EPGStore.shared.status(onid: c.onid, sid: c.sid)
            guard st.hasBasic else { noBasic = true; continue }
            basic = true
            if !st.basicComplete || (!stop.satellite && st.hasExtended && !st.extendedComplete) {
                complete = false
                break
            }
        }
        // some services may simply be late: give them at least a minute
        if complete && basic && noBasic && elapsed < 60 { complete = false }
        if !complete && elapsed < (stop.satellite ? 360 : 120) { return }
        if envVar("DEBUG") != nil {
            debugLog("epg", String(format: "%@: %@ after %.0f s", stop.title, complete ? "complete" : "timeout", elapsed))
        }
        next()
    }

    private func next() {
        index += 1
        guard index < stops.count else {
            end(notify: true)
            return
        }
        stopStarted = Date()
        tuneHandler(stops[index].tune)
        onChange?()
    }

    private func end(notify: Bool) {
        timer?.invalidate()
        timer = nil
        index = -1
        stops = []
        if notify { finishHandler() }
        onChange?()
    }
}
