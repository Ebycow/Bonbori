// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import AVFoundation
import CoreMedia
import Speech
import Translation

/// One recognized utterance, timed on the broadcast (PTS) timeline.
struct SubtitleCue {
    let id: Int
    let start: Double
    let end: Double
    var original: String
    var translation: String?
}

/// 翻訳字幕: shows the English speech of the broadcast, translated into Japanese.
///
/// Recognition runs on the player's audio tap, which is decoded as soon as it arrives. Cues
/// carry the PTS of their speech and are shown when the presentation clock reaches it, or at
/// once if they come later than that. So the only difference between showing subtitles
/// "as soon as possible" and "in sync" is the player's output delay.
final class SubtitleController {
    private let player: Player
    private let view: SubtitleOverlay
    private var engine: AnyObject?  // SubtitleEngine (macOS 26)
    private var cues: [SubtitleCue] = []
    private var shown: (id: Int, at: Double)?
    private var timer: Timer?
    private let debug = envVar("DEBUG") != nil
    var onStatus: ((String) -> Void)?

    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    init(player: Player, view: SubtitleOverlay) {
        self.player = player
        self.view = view
    }

    var isRunning: Bool { engine != nil }

    /// 1 = left (主音声), 2 = right (副音声), 3 = both channels mixed.
    var channel = 3 {
        didSet {
            if #available(macOS 26.0, *) { (engine as? SubtitleEngine)?.channel = channel }
        }
    }

    func start() {
        guard engine == nil, #available(macOS 26.0, *) else { return }
        let e = SubtitleEngine()
        e.channel = channel
        e.onCue = { [weak self] cue in self?.received(cue) }
        e.onStatus = { [weak self] msg in self?.onStatus?(msg) }
        player.onTapAudio = { [weak e] sb, gen in e?.feed(sb, gen: gen) }
        engine = e
        e.start()
        player.setAudioTap(true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        guard engine != nil else { return }
        player.setAudioTap(false)
        if #available(macOS 26.0, *) { (engine as? SubtitleEngine)?.stop() }
        engine = nil
        timer?.invalidate()
        timer = nil
        reset()
    }

    /// Forget the cues (on a channel change).
    func reset() {
        cues.removeAll()
        shown = nil
        view.show(nil, showOriginal: true)
    }

    private func received(_ cue: SubtitleCue) {
        if debug {
            // lead > 0: arrived before its speech is played (in time); < 0: late by that much
            let lead = player.isClockRunning ? String(format: "%+.2f", cue.start - player.presentationTime) : "-"
            debugLog("subtitle", "#\(cue.id) \(cue.translation == nil ? "EN" : "JA") lead \(lead)s  \(cue.translation ?? cue.original)")
        }
        if let i = cues.firstIndex(where: { $0.id == cue.id }) {
            cues[i] = cue
        } else {
            cues.append(cue)
            cues.sort { $0.start < $1.start }
        }
        tick()
    }

    private func tick() {
        guard player.isClockRunning else { return }
        let now = player.presentationTime
        // Older than a minute, or from another timeline.
        cues.removeAll { $0.end < now - 60 || $0.start > now + 60 }
        guard let cue = cues.last(where: { $0.start <= now }) else {
            view.show(nil, showOriginal: true)
            return
        }
        if shown?.id != cue.id { shown = (cue.id, now) }
        let hold = min(max(cue.end - cue.start + 1.5, 3), 8)
        view.show(now - shown!.at > hold ? nil : cue, showOriginal: Settings.shared.subtitleShowOriginal)
    }
}

/// Speech recognition (English) and translation (Japanese) of the audio tap.
@available(macOS 26.0, *)
final class SubtitleEngine: @unchecked Sendable {
    /// Main thread: a new cue, or a known cue whose translation arrived.
    var onCue: ((SubtitleCue) -> Void)?
    /// Main thread: model download state and problems, for the HUD.
    var onStatus: ((String) -> Void)?

    private let lock = NSLock()
    private var _channel = 3
    var channel: Int {
        get { lock.withLock { _channel } }
        set { lock.withLock { _channel = newValue } }
    }

    private let locale = Locale(identifier: "en-US")
    private let source = Locale.Language(identifier: "en"), target = Locale.Language(identifier: "ja")

    // tap queue state
    private let q = DispatchQueue(label: "tv.subtitle", qos: .userInitiated)
    private var ready = false
    private var stopped = false
    private var format: AVAudioFormat?
    private var gen: UInt32?
    private var run: Run?
    private var nextID = 0

    private var translations: AsyncStream<SubtitleCue>.Continuation?
    private var translatorTask: Task<Void, Never>?

    /// One analyzer session; a new one starts on every generation (channel change).
    private final class Run: @unchecked Sendable {
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
        let input: AsyncStream<AnalyzerInput>.Continuation
        var converter: AVAudioConverter?
        var monoFormat: AVAudioFormat?
        var fed = 0.0  // seconds of audio given to the analyzer
        var expectedPTS: Double?
        private let lock = NSLock()
        private var anchors: [(t: Double, pts: Double)] = []  // analyzer time -> PTS, at discontinuities
        var tasks: [Task<Void, Never>] = []

        init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, input: AsyncStream<AnalyzerInput>.Continuation) {
            self.analyzer = analyzer
            self.transcriber = transcriber
            self.input = input
        }

        func addAnchor(t: Double, pts: Double) { lock.withLock { anchors.append((t, pts)) } }

        func pts(at t: Double) -> Double? {
            lock.withLock {
                guard let a = anchors.last(where: { $0.t <= t }) ?? anchors.first else { return nil }
                return a.pts + (t - a.t)
            }
        }
    }

    func start() {
        Task { await prepare() }
    }

    func stop() {
        q.async { [self] in
            stopped = true
            endRun()
            translations?.finish()
        }
    }

    private func status(_ msg: String) {
        if envVar("DEBUG") != nil { debugLog("subtitle", msg) }
        DispatchQueue.main.async { self.onStatus?(msg) }
    }

    private func prepare() async {
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                status("翻訳字幕: 音声認識モデルをダウンロードしています…")
                try await req.downloadAndInstall()
            }
        } catch {
            status("翻訳字幕: 音声認識モデルを用意できませんでした (\(error.localizedDescription))")
            return
        }
        let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
        // An app process seems to default to the low-latency strategy, whose model is often not
        // installed when the high-fidelity one is (macOS 27): ask for the latter and try it.
        var session: TranslationSession?
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .highFidelity)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
        do {
            _ = try await session?.translate("Hello.")
        } catch {
            if envVar("DEBUG") != nil { debugLog("subtitle", "translation unavailable: \(error)") }
            session = nil
            status("翻訳字幕: 英語→日本語の翻訳モデルがありません。英語のみ表示します\n（システム設定 › 一般 › 言語と地域 › 翻訳言語 から追加できます）")
        }
        if let session {
            let (stream, cont) = AsyncStream<SubtitleCue>.makeStream()
            translatorTask = Task { [weak self] in
                for await cue in stream {
                    let ja: String
                    do {
                        ja = try await session.translate(cue.original).targetText
                    } catch {
                        if envVar("DEBUG") != nil { debugLog("subtitle", "translation failed: \(error)") }
                        continue
                    }
                    let done = SubtitleCue(id: cue.id, start: cue.start, end: cue.end, original: cue.original, translation: ja)
                    DispatchQueue.main.async { self?.onCue?(done) }
                }
            }
            translations = cont
        }
        q.async { [self] in
            format = fmt
            ready = fmt != nil && !stopped
        }
    }

    /// Decoder thread.
    func feed(_ sb: CMSampleBuffer, gen g: UInt32) {
        q.async { [self] in
            guard ready, !stopped, let format else { return }
            if gen != g {
                endRun()
                gen = g
            }
            if run == nil { run = startRun(format: format, gen: g) }
            guard let run, let buf = convert(sb, run: run, to: format) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            let dur = Double(CMSampleBufferGetNumSamples(sb)) / (run.monoFormat?.sampleRate ?? 48000)
            if let e = run.expectedPTS, abs(pts - e) < 0.05 {} else { run.addAnchor(t: run.fed, pts: pts) }
            run.expectedPTS = pts + dur
            run.fed += dur
            run.input.yield(AnalyzerInput(buffer: buf))
        }
    }

    private func startRun(format: AVAudioFormat, gen g: UInt32) -> Run {
        // Volatile results are not shown, but asking for them makes final results come sooner.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let run = Run(analyzer: analyzer, transcriber: transcriber, input: cont)
        run.tasks.append(Task {
            try? await analyzer.start(inputSequence: stream)
        })
        run.tasks.append(Task { [weak self, weak run] in
            do {
                for try await r in transcriber.results where r.isFinal {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, let run, let s = run.pts(at: r.range.start.seconds),
                          let e = run.pts(at: r.range.end.seconds) else { continue }
                    self?.emit(text, start: s, end: e, gen: g)
                }
            } catch {}
        })
        return run
    }

    private func endRun() {
        guard let run else { return }
        self.run = nil
        run.input.finish()
        let analyzer = run.analyzer
        Task { await analyzer.cancelAndFinishNow() }
        run.tasks.forEach { $0.cancel() }
    }

    private func emit(_ text: String, start: Double, end: Double, gen g: UInt32) {
        q.async { [self] in
            guard g == gen, !stopped else { return }
            nextID += 1
            let cue = SubtitleCue(id: nextID, start: start, end: end, original: text)
            DispatchQueue.main.async { self.onCue?(cue) }
            translations?.yield(cue)
        }
    }

    /// Stereo float32 48 kHz sample buffer -> one channel (or both mixed) in the analyzer's format.
    private func convert(_ sb: CMSampleBuffer, run: Run, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mChannelsPerFrame == 2, let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0 else { return nil }
        if run.monoFormat?.sampleRate != asbd.mSampleRate {
            run.monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: 1, interleaved: false)
            run.converter = run.monoFormat.flatMap { AVAudioConverter(from: $0, to: format) }
        }
        guard let mono = run.monoFormat, let conv = run.converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        var stereo = [Float](repeating: 0, count: n * 2)
        guard stereo.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 8, destination: $0.baseAddress!) }) == noErr else { return nil }
        let dst = inBuf.floatChannelData![0]
        switch channel {
        case 1: for i in 0..<n { dst[i] = stereo[i * 2] }
        case 2: for i in 0..<n { dst[i] = stereo[i * 2 + 1] }
        default: for i in 0..<n { dst[i] = (stereo[i * 2] + stereo[i * 2 + 1]) * 0.5 }
        }
        inBuf.frameLength = AVAudioFrameCount(n)
        let cap = AVAudioFrameCount(Double(n) * format.sampleRate / mono.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var given = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if given { st.pointee = .noDataNow; return nil }
            given = true
            st.pointee = .haveData
            return inBuf
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }
}

/// Subtitle box at the bottom of the picture: the translation, and the original below it.
final class SubtitleOverlay: NSView {
    private let main = NSTextField(wrappingLabelWithString: "")
    private let sub = NSTextField(wrappingLabelWithString: "")
    private var current: (id: Int, ja: String?, en: String, orig: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 6
        for f in [main, sub] {
            f.textColor = .white
            f.alignment = .center
            f.isSelectable = false
            f.maximumNumberOfLines = 3
            addSubview(f)
        }
        sub.textColor = NSColor.white.withAlphaComponent(0.8)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func show(_ cue: SubtitleCue?, showOriginal: Bool) {
        guard let cue else {
            if !isHidden { isHidden = true; current = nil }
            return
        }
        if let c = current, c.id == cue.id, c.ja == cue.translation, c.orig == showOriginal, !isHidden { return }
        current = (cue.id, cue.translation, cue.original, showOriginal)
        if let ja = cue.translation {
            main.stringValue = ja
            sub.stringValue = showOriginal ? cue.original : ""
        } else {
            // translation pending (or unavailable): the original stands in
            main.stringValue = cue.original
            sub.stringValue = ""
        }
        isHidden = false
        superview?.needsLayout = true
    }

    /// Places the box at the bottom of `video` (the picture rect in the superview).
    func place(in video: CGRect) {
        guard !isHidden else { return }
        let size = max(14, min(36, video.height * 0.048))
        main.font = .systemFont(ofSize: size, weight: .semibold)
        sub.font = .systemFont(ofSize: size * 0.62, weight: .regular)
        let maxW = video.width * 0.86
        let inset: CGFloat = size * 0.5
        let m = main.sizeThatFits(NSSize(width: maxW - inset * 2, height: 1000))
        let hasSub = !sub.stringValue.isEmpty
        let s = hasSub ? sub.sizeThatFits(NSSize(width: maxW - inset * 2, height: 1000)) : .zero
        let w = min(max(m.width, s.width), maxW - inset * 2)
        let gap: CGFloat = hasSub ? size * 0.2 : 0
        let h = m.height + gap + s.height
        main.frame = NSRect(x: inset, y: inset * 0.5, width: w, height: m.height)
        sub.frame = NSRect(x: inset, y: main.frame.maxY + gap, width: w, height: s.height)
        sub.isHidden = !hasSub
        let boxW = w + inset * 2, boxH = h + inset
        frame = NSRect(x: video.midX - boxW / 2, y: video.maxY - boxH - video.height * 0.05, width: boxW, height: boxH)
    }
}
