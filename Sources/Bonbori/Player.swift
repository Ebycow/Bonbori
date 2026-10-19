// SPDX-License-Identifier: GPL-2.0-or-later
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import os
import TVCore

/// Owns the TVCore session and the AVFoundation renderers, and keeps the
/// presentation clock locked to the broadcast PCR.
final class Player {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var videoRenderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }
    let audioRenderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    private var session: OpaquePointer!
    private let control = DispatchQueue(label: "tv.control", qos: .userInitiated)
    private let media = DispatchQueue(label: "tv.media", qos: .userInteractive)

    /// Main-thread event callback: (type, json)
    var onEvent: ((Int32, String) -> Void)?
    /// Network-thread event tap used by the scanner.
    fileprivate var eventTap: ((Int32, String) -> Void)?
    /// Undelayed decoded audio (both channels) while the audio tap is on; called on a decoder thread.
    /// Set before turning the tap on.
    var onTapAudio: ((CMSampleBuffer, UInt32) -> Void)?
    /// Seconds by which picture and sound are held back (see setOutputDelay).
    private(set) var outputDelay: Double = 0
    private let tapLock = NSLock()

    // media queue state
    private var gen: UInt32 = 0
    private var clockStarted = false
    private var firstVideo = true
    /// Drift correction requested from TVCore (resets with each generation there too).
    private var driftPPM: Int32 = 0
    /// (PCR − latency) − clock, smoothed over ~10 s of PCRs.
    private var smoothedDiff: Double?
    /// smoothedDiff once settled after the anchor: the delay to hold for the rest of the tune.
    private var driftRef: Double?
    private var anchorHostTime = 0.0
    private var lastStatusLog = 0.0
    private let logger = Logger(subsystem: "net.ebycow.bonbori", category: "player")

    // debug statistics (media queue)
    private let debug = envVar("DEBUG") != nil
    /// Skews the PCR by this many ppm from the anchor on, as if the audio device clock drifted.
    private let driftTestPPM = Double(envVar("DRIFT_TEST") ?? "") ?? 0
    private var dbgVideo = 0, dbgAudio = 0, dbgLateV = 0, dbgLateA = 0
    private var dbgMinLeadV = Double.infinity, dbgMinLeadA = Double.infinity
    private var dbgLastPrint = Date()
    private var dbgTuneStart = Date()
    private var dbgFirstFrameLogged = false
    private var dbgFirstPts = 0.0
    private var dbgPrevV = 0.0, dbgPrevAEnd = 0.0
    private var dbgClk = (0.0, 0.0)
    private var dbgLastPCR = 0.0
    private var dbgVDelta: [Int: Int] = [:]
    private var dbgAGaps: [String] = []

    private var recentFrames: [(pts: Double, pb: CVPixelBuffer)] = []

    // control queue state
    private var openGroup: String?
    private var tunedTS: Channel?
    private var pending: Channel?
    private var pendingLock = NSLock()
    private var working = false
    private(set) var current: Channel?

    init() {
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = CGColor.black
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        audioRenderer.volume = Settings.shared.volume

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var cb = tv_callbacks()
        cb.ctx = ctx
        cb.on_video = { ctx, sb, gen in
            guard let ctx, let sb else { return }
            Unmanaged<Player>.fromOpaque(ctx).takeUnretainedValue().video(sb, gen)
        }
        cb.on_audio = { ctx, sb, gen in
            guard let ctx, let sb else { return }
            Unmanaged<Player>.fromOpaque(ctx).takeUnretainedValue().audio(sb, gen)
        }
        cb.on_clock = { ctx, pcr, gen in
            guard let ctx else { return }
            Unmanaged<Player>.fromOpaque(ctx).takeUnretainedValue().clock(pcr, gen)
        }
        cb.on_event = { ctx, type, json in
            guard let ctx, let json else { return }
            Unmanaged<Player>.fromOpaque(ctx).takeUnretainedValue().event(type, String(cString: json))
        }
        cb.on_tap_audio = { ctx, sb, gen in
            guard let ctx, let sb else { return }
            Unmanaged<Player>.fromOpaque(ctx).takeUnretainedValue().onTapAudio?(sb, gen)
        }
        session = tv_session_create(cb)
        tv_session_set_deinterlace(session, Settings.shared.deinterlace)
        prewarmAudio()
    }

    deinit {
        tv_session_destroy(session)
    }

    /// CoreAudio's first LPCM format description can take a while; do it off the hot path.
    private func prewarmAudio() {
        DispatchQueue.global(qos: .utility).async {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                mBitsPerChannel: 32, mReserved: 0)
            var fmt: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        }
    }

    // MARK: - Settings

    var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = max(0, min(1, newValue)); Settings.shared.volume = audioRenderer.volume }
    }

    var isMuted: Bool {
        get { audioRenderer.isMuted }
        set { audioRenderer.isMuted = newValue }
    }

    func setDeinterlace(_ on: Bool) {
        Settings.shared.deinterlace = on
        tv_session_set_deinterlace(session, on)
    }

    func setAudio(index: Int, dualMono: Int) {
        tv_session_set_audio(session, Int32(index), Int32(dualMono))
    }

    func setAudioTap(_ on: Bool) {
        tv_session_set_audio_tap(session, on)
    }

    /// Holds picture and sound back by `seconds` so that subtitles made from the audio tap can
    /// be shown in time. Changing it restarts playback (the new delay builds up from empty).
    func setOutputDelay(_ seconds: Double) {
        guard seconds != outputDelay else { return }
        outputDelay = seconds
        let g = tv_session_set_output_delay(session, Int32(seconds * 1000))
        media.async { _ = self.accept(g) }
    }

    /// Current position of the presentation clock, on the broadcast (PTS) timeline.
    var presentationTime: Double { synchronizer.currentTime().seconds }
    /// False while waiting for the first PCR after a tune (presentationTime is stale then).
    var isClockRunning: Bool { synchronizer.rate != 0 }

    // MARK: - Tuning

    /// Requests a channel. Rapid requests are coalesced: only the latest one is tuned.
    func tune(_ ch: Channel) {
        pendingLock.lock()
        pending = ch
        let start = !working
        working = true
        pendingLock.unlock()
        guard start else { return }
        control.async { [self] in
            while true {
                pendingLock.lock()
                guard let next = pending else {
                    working = false
                    pendingLock.unlock()
                    return
                }
                pending = nil
                pendingLock.unlock()
                doTune(next)
            }
        }
    }

    private func ensureOpen(group: String) -> Bool {
        if openGroup == group && tv_session_is_open(session) { return true }
        defer { if debug { let t = Date(); media.async { self.log(String(format: "+%.0f ms open done", t.timeIntervalSince(self.dbgTuneStart) * 1000)) } } }
        openGroup = nil
        tunedTS = nil
        let s = Settings.shared
        guard !s.host.isEmpty else {
            postError("サーバーが未設定です。⌘, の設定で BonDriverProxyEx サーバーのアドレスを指定してください")
            return false
        }
        tv_session_set_options(session, s.serverB25 ? 1 : 0)
        let rc = tv_session_open(session, s.host, Int32(s.port), group)
        if rc != 0 {
            postError("サーバー \(s.host):\(s.port) の \(group) を開けませんでした (code \(rc))")
            return false
        }
        openGroup = group
        return true
    }

    private func doTune(_ ch: Channel) {
        media.async { self.dbgTuneStart = Date() }
        guard ensureOpen(group: ch.group) else { return }
        current = ch
        if let t = tunedTS, t.sameTS(ch) {
            tv_session_select_service(session, UInt16(ch.sid))
            return
        }
        let r = tv_session_set_channel(session, UInt32(ch.space), UInt32(ch.channel), UInt16(ch.sid), 0)
        switch r {
        case 0:
            tunedTS = ch
        case 1:
            tunedTS = nil
            postError("チューナーは他のクライアントにロックされています")
        default:
            tunedTS = nil
            if !tv_session_is_open(session) { openGroup = nil }
            postError("選局に失敗しました: \(ch.channelName) (result \(r))")
        }
    }

    func stop() {
        control.async { [self] in
            tv_session_close(session)
            openGroup = nil
            tunedTS = nil
            current = nil
        }
    }

    private func postError(_ msg: String) {
        let json = (try? JSONSerialization.data(withJSONObject: ["msg": msg])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        DispatchQueue.main.async { self.onEvent?(Int32(TV_EV_ERROR.rawValue), json) }
    }

    // MARK: - Recording / capture

    var isRecording: Bool { tv_session_is_recording(session) }

    func startRecording(to url: URL) -> Bool {
        tv_session_record_start(session, url.path) == 0
    }

    @discardableResult
    func stopRecording() -> UInt64 {
        tv_session_record_stop(session)
    }

    /// The frame currently on screen, scaled to its display aspect ratio.
    func snapshot(aspect: CGFloat, completion: @escaping (CGImage?) -> Void) {
        media.async { [self] in
            let now = synchronizer.currentTime().seconds
            guard let pb = (recentFrames.last { $0.pts <= now } ?? recentFrames.last)?.pb else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var img = CIImage(cvPixelBuffer: pb)
            let h = img.extent.height
            let sx = (h * aspect) / img.extent.width
            img = img.transformed(by: CGAffineTransform(scaleX: sx, y: 1))
            let cg = CIContext().createCGImage(img, from: img.extent)
            DispatchQueue.main.async { completion(cg) }
        }
    }

    // MARK: - Scanning

    struct ScanProgress {
        var message: String
        var fraction: Double
        var found: Int
    }

    func scan(groups: [String], progress: @escaping (ScanProgress) -> Void, done: @escaping ([Channel]) -> Void) {
        control.async { [self] in
            var all: [Channel] = []
            var satTsids: [String: Set<Int>] = [:]
            // enumerate everything first so progress is meaningful
            var plan: [(group: String, space: Int, spaceName: String, ch: Int, chName: String)] = []
            for g in groups {
                openGroup = nil
                guard ensureOpen(group: g) else { continue }
                var sp: UInt32 = 0
                while let sName = takeString(tv_session_enum_space(session, sp)) {
                    var c: UInt32 = 0
                    while let cName = takeString(tv_session_enum_channel(session, sp, c)) {
                        plan.append((g, Int(sp), sName, Int(c), cName))
                        c += 1
                    }
                    sp += 1
                }
            }
            for (i, item) in plan.enumerated() {
                DispatchQueue.main.async {
                    progress(ScanProgress(message: "\(item.spaceName) \(item.chName)", fraction: Double(i) / Double(max(plan.count, 1)), found: all.count))
                }
                guard ensureOpen(group: item.group) else { continue }
                let terrestrial = item.group.hasSuffix("T") || item.spaceName.contains("地デジ")
                let bs = item.spaceName.uppercased().hasPrefix("BS")
                // Every satellite transponder carries a TS with its own TSID. A timeout, or a TSID
                // already found in this space, means the tuner was still delivering the previous
                // TS (the demux then stays locked to it): tune again.
                let spaceKey = "\(item.group)/\(item.space)"
                var ev: ServicesEvent?
                for attempt in 0..<(terrestrial ? 1 : 3) {
                    if attempt == 2 {
                        // BonDriverProxyEx ignores a request for the current channel: go through another one.
                        _ = tv_session_set_channel(session, UInt32(item.space), item.ch == 0 ? 1 : 0, 0, 0)
                    }
                    let waiter = ServicesWaiter()
                    setTap { type, json in
                        if type == Int32(TV_EV_SERVICES.rawValue), let ev = decode(ServicesEvent.self, json) { waiter.put(ev) }
                    }
                    let r = tv_session_set_channel(session, UInt32(item.space), UInt32(item.ch), 0, 0)
                    tunedTS = nil
                    if r != 0 {
                        setTap(nil)
                        if !tv_session_is_open(session) { openGroup = nil }
                        break
                    }
                    ev = waiter.wait(sdtTimeout: attempt == 0 ? 3.0 : 5.0, needNIT: terrestrial, nitTimeout: 6.0)
                    setTap(nil)
                    if terrestrial { break }
                    if let e = ev, !(satTsids[spaceKey]?.contains(e.tsid) ?? false) { break }
                    ev = nil
                }
                guard let ev else { continue }
                if !terrestrial { satTsids[spaceKey, default: []].insert(ev.tsid) }
                for s in ev.services {
                    let key = terrestrial ? ev.remote_key : (bs ? bsRemoteKey(sid: s.sid) : 0)
                    var c = Channel(group: item.group, space: item.space, channel: item.ch,
                                    spaceName: item.spaceName, channelName: item.chName, sid: s.sid,
                                    name: s.name, serviceType: s.type, remoteKey: key,
                                    tsName: ev.tsname, onid: ev.onid, tsid: ev.tsid)
                    c.signal = Double(tv_session_signal_level(session))
                    all.append(c)
                }
            }
            DispatchQueue.main.async { done(Player.dedupe(all)) }
        }
    }

    /// The same service can be received on several physical channels (relay stations, or a
    /// satellite transponder that failed to tune and still carried the previous TS):
    /// keep the strongest one, in scan order.
    static func dedupe(_ list: [Channel]) -> [Channel] {
        var best: [String: Channel] = [:]
        for c in list {
            // (ISDB-T: tsid == onid; older scans may lack the tsid)
            let k = "\(c.group)/\(c.onid)/\(c.tsid >= 0 ? c.tsid : c.onid)/\(c.sid)"
            if let b = best[k], (b.signal ?? 0) >= (c.signal ?? 0), b.remoteKey != 0 || c.remoteKey == 0 { continue }
            best[k] = c
        }
        let keep = Set(best.values.map(\.id))
        var seen = Set<String>()
        return list.filter { keep.contains($0.id) && seen.insert($0.id).inserted }
    }

    private func setTap(_ f: ((Int32, String) -> Void)?) {
        tapLock.lock()
        eventTap = f
        tapLock.unlock()
    }

    private func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { tv_free(p) }
        return String(cString: p)
    }

    // MARK: - Callbacks (TVCore threads)

    private func event(_ type: Int32, _ json: String) {
        if type == Int32(TV_EV_EIT.rawValue) {
            // hundreds of sections per second on satellites: keep them off the main thread
            EPGStore.shared.ingest(json)
            return
        }
        // With an output delay the new channel's first data arrives late: clear the old picture now.
        if type == Int32(TV_EV_TUNED.rawValue), outputDelay > 0, let t = decode(TunedEvent.self, json), t.ok {
            media.async { _ = self.accept(UInt32(t.gen)) }
        }
        if debug, type == Int32(TV_EV_TUNED.rawValue) || type == Int32(TV_EV_STREAM.rawValue) || type == Int32(TV_EV_FORMAT.rawValue) {
            let t = Date()
            media.async { self.log(String(format: "+%.0f ms ev%d %@", t.timeIntervalSince(self.dbgTuneStart) * 1000, type, json)) }
        }
        tapLock.lock()
        let tap = eventTap
        tapLock.unlock()
        tap?(type, json)
        DispatchQueue.main.async { self.onEvent?(type, json) }
    }

    /// Samples far away from the running clock belong to another timeline (e.g. stale data
    /// around a retune); enqueueing them would stall or flush the renderers.
    private func onTimeline(_ sb: CMSampleBuffer) -> Bool {
        guard clockStarted else { return true }
        let d = CMSampleBufferGetPresentationTimeStamp(sb).seconds - synchronizer.currentTime().seconds
        if abs(d) < 10 { return true }
        if debug { log(String(format: "drop off-timeline sample (%.3f s)", d)) }
        return false
    }

    private func video(_ sb: CMSampleBuffer, _ g: UInt32) {
        media.async { [self] in
            guard accept(g), onTimeline(sb) else { return }
            if firstVideo {
                firstVideo = false
                // Show the first picture right away; the rest follows the clock.
                if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
                   CFArrayGetCount(arr) > 0 {
                    let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
                    CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                         Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                }
            }
            if debug { noteLead(sb, video: true) }
            if videoRenderer.status == .failed || videoRenderer.requiresFlushToResumeDecoding {
                videoRenderer.flush()
            }
            videoRenderer.enqueue(sb)
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                recentFrames.append((CMSampleBufferGetPresentationTimeStamp(sb).seconds, pb))
                if recentFrames.count > 48 { recentFrames.removeFirst(recentFrames.count - 48) }
            }
        }
    }

    private func audio(_ sb: CMSampleBuffer, _ g: UInt32) {
        media.async { [self] in
            guard accept(g), onTimeline(sb) else { return }
            if debug { noteLead(sb, video: false) }
            if audioRenderer.status == .failed { audioRenderer.flush() }
            audioRenderer.enqueue(sb)
        }
    }

    /// Anchor once to the PCR, then free-run on the audio device clock: moving the running
    /// clock interrupts otherwise continuous audio (so does changing its rate). The audio
    /// device and the broadcast clocks still differ by tens of ppm, which over a day eats the
    /// whole delay (late audio is dropped, late frames stutter), so TVCore resamples the audio
    /// slightly and shifts every timestamp with it to hold the delay instead.
    private func clock(_ pcr: Int64, _ g: UInt32) {
        media.async { [self] in
            guard accept(g) else { return }
            var pcr = pcr
            if driftTestPPM != 0 && clockStarted {
                pcr += Int64((CACurrentMediaTime() - anchorHostTime) * 90000 * driftTestPPM / 1e6)
            }
            dbgLastPCR = Double(pcr) / 90000
            let latency = Settings.shared.latency
            let target = CMTime(value: pcr - Int64(latency * 90000), timescale: 90000)
            if !clockStarted {
                if debug { log(String(format: "clock start gen %u pcr %.3f latency %.2f", g, Double(pcr) / 90000, latency)) }
                clockStarted = true
                anchorHostTime = CACurrentMediaTime()
                synchronizer.setRate(1, time: target)
                return
            }
            // The timebase starts only after the audio renderer has synced to the new time;
            // until then currentTime is stale, and acting on it re-anchors on every PCR.
            let sinceAnchor = CACurrentMediaTime() - anchorHostTime
            guard sinceAnchor > 2 else { return }
            let diff = target.seconds - synchronizer.currentTime().seconds
            if abs(diff) > 3 {
                // The broadcast timeline jumped, or the TS stalled: start over as after a tune.
                if debug { log(String(format: "PCR discontinuity gen %u diff %.3f: restart clock", g, diff)) }
                logger.notice("PCR discontinuity diff \(diff, format: .fixed(precision: 3)) s: restart clock")
                resetPlayback()
                return
            }
            let smoothed = smoothedDiff.map { $0 + (diff - $0) * 0.01 } ?? diff
            smoothedDiff = smoothed
            guard let ref = driftRef else {
                if sinceAnchor > 30 { driftRef = smoothed }
                return
            }
            // err < 0: the clock runs ahead of the broadcast and the delay is shrinking.
            let err = smoothed - ref
            var ppm = driftPPM
            if abs(err) < 0.02 {
                ppm = 0
            } else if abs(err) > 0.5 {
                ppm = err < 0 ? 5000 : -5000
            } else if abs(err) > 0.1 {
                ppm = err < 0 ? 1000 : -1000
            }
            if ppm != driftPPM {
                if debug { log(String(format: "drift %+.3f s: correction %d ppm", err, ppm)) }
                logger.notice("drift \(err, format: .fixed(precision: 3)) s: correction \(ppm) ppm")
                driftPPM = ppm
                tv_session_set_drift_correction(session, g, ppm)
            }
            let now = CACurrentMediaTime()
            if now - lastStatusLog >= 600 {
                lastStatusLog = now
                logger.notice("drift \(err, format: .fixed(precision: 3)) s correction \(ppm) ppm")
            }
        }
    }

    private func noteLead(_ sb: CMSampleBuffer, video: Bool) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if video { dbgVideo += 1 } else { dbgAudio += 1 }
        if dbgFirstPts == 0 || (video && !dbgFirstFrameLogged) {
            log(String(format: "gen %u first %@ pts %.3f clockStarted=%d now=%.3f", gen, video ? "video" : "audio", pts, clockStarted ? 1 : 0, synchronizer.currentTime().seconds))
            dbgFirstPts = pts
        }
        if video && !dbgFirstFrameLogged {
            dbgFirstFrameLogged = true
            log(String(format: "first video frame %.0f ms after tune", Date().timeIntervalSince(dbgTuneStart) * 1000))
        }
        if video {
            if dbgPrevV > 0 { dbgVDelta[Int(((pts - dbgPrevV) * 1000).rounded()), default: 0] += 1 }
            dbgPrevV = pts
        } else {
            let dur = CMSampleBufferGetDuration(sb).seconds
            if dbgPrevAEnd > 0 {
                let gap = pts - dbgPrevAEnd
                if abs(gap) > 0.002 { dbgAGaps.append(String(format: "%+.1fms", gap * 1000)) }
            }
            dbgPrevAEnd = pts + (dur.isFinite ? dur : 0)
        }
        guard clockStarted else { return }
        let lead = pts - synchronizer.currentTime().seconds
        if video {
            dbgMinLeadV = min(dbgMinLeadV, lead)
            if lead < 0 { dbgLateV += 1 }
        } else {
            dbgMinLeadA = min(dbgMinLeadA, lead)
            if lead < 0 { dbgLateA += 1 }
        }
        if Date().timeIntervalSince(dbgLastPrint) >= 2 {
            dbgLastPrint = Date()
            let w = CACurrentMediaTime(), c = synchronizer.currentTime().seconds
            if dbgClk.0 > 0 {
                log(String(format: "  clock rate %.4f (sync %.3fs / wall %.3fs)  pcr-sync %.3f", (c - dbgClk.1) / (w - dbgClk.0), c - dbgClk.1, w - dbgClk.0, dbgLastPCR - c))
            }
            dbgClk = (w, c)
            log(String(format: "v=%d a=%d late v/a=%d/%d minLead v=%.3f a=%.3f ppm=%d diff=%.3f vstat=%d astat=%d",
                       dbgVideo, dbgAudio, dbgLateV, dbgLateA, dbgMinLeadV, dbgMinLeadA, driftPPM, smoothedDiff ?? 0,
                       videoRenderer.status.rawValue, audioRenderer.status.rawValue))
            let hist = dbgVDelta.sorted { $0.key < $1.key }.map { "\($0.key)ms:\($0.value)" }.joined(separator: " ")
            log("  vdelta " + hist + (dbgAGaps.isEmpty ? "" : "  agaps " + dbgAGaps.prefix(12).joined(separator: " ")))
            dbgVDelta.removeAll(); dbgAGaps.removeAll()
            dbgVideo = 0; dbgAudio = 0; dbgLateV = 0; dbgLateA = 0
            dbgMinLeadV = .infinity; dbgMinLeadA = .infinity
        }
    }

    private func log(_ s: String) {
        debugLog("player", s)
    }

    /// Generation handling: newer generation => flush everything; older => drop.
    private func accept(_ g: UInt32) -> Bool {
        if g == gen { return true }
        if Int32(bitPattern: g &- gen) < 0 { return false }
        gen = g
        dbgFirstFrameLogged = false
        dbgFirstPts = 0
        dbgPrevV = 0; dbgPrevAEnd = 0
        resetPlayback()
        return true
    }

    /// Stops the clock and empties the renderers; the next PCR starts the clock again.
    private func resetPlayback() {
        clockStarted = false
        firstVideo = true
        smoothedDiff = nil
        driftRef = nil
        if driftPPM != 0 {
            driftPPM = 0
            tv_session_set_drift_correction(session, gen, 0)
        }
        recentFrames.removeAll()
        synchronizer.setRate(0, time: synchronizer.currentTime())
        videoRenderer.flush()
        audioRenderer.flush()
    }
}

/// Collects SDT/NIT information during a scan.
private final class ServicesWaiter {
    private let cond = NSCondition()
    private var latest: ServicesEvent?

    func put(_ ev: ServicesEvent) {
        cond.lock()
        if ev.complete { latest = ev }
        cond.broadcast()
        cond.unlock()
    }

    func wait(sdtTimeout: TimeInterval, needNIT: Bool, nitTimeout: TimeInterval) -> ServicesEvent? {
        cond.lock()
        defer { cond.unlock() }
        let sdtDeadline = Date().addingTimeInterval(sdtTimeout)
        while latest == nil {
            if !cond.wait(until: sdtDeadline) { break }
        }
        guard latest != nil else { return nil }
        if needNIT {
            let nitDeadline = Date().addingTimeInterval(nitTimeout)
            while let l = latest, l.nid < 0 || l.remote_key == 0 {
                if !cond.wait(until: nitDeadline) { break }
            }
        }
        return latest
    }
}
