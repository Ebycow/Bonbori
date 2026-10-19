// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import AVFoundation
import TVCore

final class MainController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    let player = Player()
    let window: NSWindow
    let videoView: VideoView
    private let store = ChannelStore.shared
    private lazy var listPanel = ChannelListPanel(controller: self)
    private var guideWindow: ProgramGuideWindowController?
    private(set) lazy var epgCapture: EPGCapture = {
        let c = EPGCapture(tune: { [weak self] ch in self?.select(ch, remember: false) },
                           finished: { [weak self] in self?.endEPGCapture(completed: true) })
        c.onChange = { [weak self] in self?.epgCaptureProgressed() }
        return c
    }()
    /// Channel to return to after 番組表の取得.
    private var captureReturn: Channel?
    private lazy var subtitles: SubtitleController = {
        let c = SubtitleController(player: player, view: videoView.subtitles)
        c.onStatus = { [weak self] msg in self?.videoView.showHUD(msg, nil, duration: 6) }
        return c
    }()

    private var current: Channel?
    private var program: ProgramEvent?
    private var status: StatusEvent?
    private var stream: StreamEvent?
    private var videoFormat: FormatEvent?
    private var audioFormat: FormatEvent?
    private var showInfo = false
    private var dualMono = 0
    private var audioIndex = 0
    private var lastByKind: [SpaceKind: String] = [:]
    private var scrambleWarned = false
    private var scanning = false
    private var lastTuneAt = Date()
    private var errorTimer: Timer?
    /// Power assertion held while watching / recording (see updateSleepActivity).
    private var sleepActivity: NSObjectProtocol?
    private var sleepActivityOptions: ProcessInfo.ActivityOptions = []

    override init() {
        videoView = VideoView(layer: player.displayLayer)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = appName
        window.contentView = videoView
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.makeFirstResponder(videoView)

        videoView.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        videoView.onDoubleClick = { [weak self] in self?.window.toggleFullScreen(nil) }
        videoView.onContextMenu = { [weak self] in self?.makeContextMenu() }
        videoView.onScroll = { [weak self] dy in
            guard let self, dy != 0 else { return }
            self.changeVolume(Float(dy) * 0.01)
        }
        player.onEvent = { [weak self] t, j in self?.handleEvent(t, j) }
    }

    func start() {
        window.makeKeyAndOrderFront(nil)
        buildMenus()
        applySubtitleSettings()
        if Settings.shared.host.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.showSettings(nil) }
            return
        }
        if let iv = envVar("ZAP_TEST").flatMap(Double.init) {
            Timer.scheduledTimer(withTimeInterval: iv, repeats: true) { [weak self] _ in self?.zap(1) }
        }
        if envVar("SELFTEST") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                capture(nil)
                toggleRecording(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                    toggleRecording(nil)
                    FileHandle.standardError.write("[selftest] done\n".data(using: .utf8)!)
                }
            }
        }
        if envVar("GUIDE") != nil {
            DispatchQueue.main.async { [weak self] in self?.toggleProgramGuide(nil) }
        }
        if CommandLine.arguments.contains("--scan") {
            runScan()
            return
        }
        if store.tvChannels.isEmpty {
            videoView.setCenterMessage("チャンネルが未登録です。\nメニュー「チャンネル」→「チャンネルスキャン…」を実行してください。")
        } else if let id = Settings.shared.lastChannelID, let ch = store.find(id: id) {
            tune(ch)
        } else if let ch = store.tvChannels.first {
            tune(ch)
        }
    }

    // MARK: - Tuning

    /// Tunes on the user's request (this ends 番組表の取得).
    func tune(_ ch: Channel) {
        if epgCapture.isRunning {
            captureReturn = nil
            epgCapture.cancel()
        }
        select(ch, remember: true)
    }

    private func select(_ ch: Channel, remember: Bool) {
        current = ch
        program = nil
        stream = nil
        scrambleWarned = false
        lastTuneAt = Date()
        if remember {
            lastByKind[ch.kind] = ch.id
            Settings.shared.lastChannelID = ch.id
        }
        videoView.setCenterMessage(nil)
        subtitles.reset()
        player.tune(ch)
        updateSubtitleSource()
        showChannelHUD()
        updateTitle()
        listPanel.reload()
        guideWindow?.currentChannelChanged()
        updateSleepActivity()
    }

    /// While watching, keeps the display awake if 「視聴中はスリープしない」 is on. While recording or
    /// capturing the EPG, keeps the system awake regardless (the display may still turn off).
    private func updateSleepActivity() {
        var opts: ProcessInfo.ActivityOptions = []
        if current != nil && Settings.shared.preventSleep { opts.insert(.idleDisplaySleepDisabled) }
        if player.isRecording || epgCapture.isRunning { opts.insert(.idleSystemSleepDisabled) }
        guard opts != sleepActivityOptions else { return }
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a) }
        sleepActivity = opts.isEmpty ? nil
            : ProcessInfo.processInfo.beginActivity(options: opts, reason: "テレビの視聴・録画")
        sleepActivityOptions = opts
    }

    private func zap(_ delta: Int) {
        let list = store.channels(of: current?.kind ?? .terrestrial)
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == current?.id } ?? -delta
        let next = list[((idx + delta) % list.count + list.count) % list.count]
        tune(next)
    }

    private func tuneKey(_ key: Int) {
        let kind = current?.kind ?? .terrestrial
        if let ch = store.channels(of: kind).first(where: { $0.remoteKey == key }) { tune(ch) }
    }

    func switchKind(_ kind: SpaceKind) {
        let list = store.channels(of: kind)
        if let id = lastByKind[kind], let ch = list.first(where: { $0.id == id }) {
            tune(ch)
        } else if let ch = list.first {
            tune(ch)
        }
    }

    // MARK: - Events

    private func handleEvent(_ type: Int32, _ json: String) {
        switch UInt32(type) {
        case TV_EV_PROGRAM.rawValue:
            guard let p = decode(ProgramEvent.self, json), p.sid == current?.sid else { return }
            let changed = program?.present?.event_id != p.present?.event_id
            program = p
            updateTitle()
            if changed { updateSubtitleSource() }
            if changed && Date().timeIntervalSince(lastTuneAt) < 5 { showChannelHUD() }
        case TV_EV_STATUS.rawValue:
            status = decode(StatusEvent.self, json)
            if let s = status, !scrambleWarned, s.packets > 0, Double(s.scrambled) / Double(s.packets) > 0.5,
               Date().timeIntervalSince(lastTuneAt) > 2 {
                scrambleWarned = true
                videoView.setCenterMessage("スクランブルが解除されていません\n受信状態とサーバーの設定を確認してください")
            } else if let s = status, scrambleWarned, s.scrambled == 0 {
                scrambleWarned = false
                videoView.setCenterMessage(nil)
            }
            updateInfo()
        case TV_EV_STREAM.rawValue:
            stream = decode(StreamEvent.self, json)
            updateInfo()
        case TV_EV_FORMAT.rawValue:
            guard let f = decode(FormatEvent.self, json) else { return }
            if f.kind == "video" {
                videoFormat = f
                if let w = f.width, let h = f.height, h > 0 {
                    let sar = Double(f.sar_num ?? 1) / Double(max(f.sar_den ?? 1, 1))
                    videoView.displayAspect = CGFloat(Double(w) * sar / Double(h))
                }
            } else {
                audioFormat = f
            }
            updateInfo()
        case TV_EV_TUNED.rawValue:
            if epgCapture.isRunning, let t = decode(TunedEvent.self, json), !t.ok { epgCapture.skip() }
        case TV_EV_ERROR.rawValue:
            if let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let m = d["msg"] as? String {
                videoView.setCenterMessage(m)
                errorTimer?.invalidate()
                errorTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                    self?.videoView.setCenterMessage(nil)
                }
            }
        case TV_EV_CLOSED.rawValue:
            if !scanning {
                videoView.setCenterMessage("サーバーとの接続が切れました。再接続します…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !self.scanning, let ch = self.current else { return }
                    self.select(ch, remember: false)
                }
            }
        default:
            break
        }
    }

    private func timeRange(_ e: ProgramEvent.Event) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let s = Date(timeIntervalSince1970: TimeInterval(e.start))
        if e.duration > 0 {
            return "\(f.string(from: s))〜\(f.string(from: s.addingTimeInterval(TimeInterval(e.duration))))"
        }
        return "\(f.string(from: s))〜"
    }

    private func showChannelHUD() {
        guard let ch = current else { return }
        let key = ch.remoteKey > 0 ? "\(ch.remoteKey)  " : ""
        var sub: String?
        if let p = program?.present {
            sub = "\(timeRange(p))  \(p.title)"
            if let n = program?.following { sub! += "\n次: \(timeRange(n))  \(n.title)" }
        }
        videoView.showHUD("\(key)\(ch.name)", sub)
    }

    private func updateTitle() {
        guard let ch = current else { window.title = appName; return }
        let rec = player.isRecording ? "● " : ""
        if let t = program?.present?.title, !t.isEmpty {
            window.title = "\(rec)\(ch.name) — \(t)"
        } else {
            window.title = rec + ch.name
        }
    }

    private func updateInfo() {
        guard showInfo else { videoView.setInfo(nil); return }
        var parts: [String] = []
        if let ch = current { parts.append("\(ch.spaceName) \(ch.channelName)  SID \(ch.sid)") }
        if let s = status {
            parts.append(String(format: "信号 %.2f dB  %.2f Mbps", s.signal, s.bitrate))
            parts.append("Drop \(s.drops)  Err \(s.errors)  Scr \(s.scrambled)  Q \(s.vqueue)/\(s.aqueue)")
        }
        var fmt: [String] = []
        if let v = videoFormat, let w = v.width, let h = v.height {
            fmt.append("\(v.codec) \(w)x\(h)\(v.interlaced == true ? "i" : "p")")
        }
        if let a = audioFormat {
            var s = "\(a.codec) \(a.layout ?? "") \(a.rate ?? 0)Hz"
            if let st = stream, st.audio_count > 1 { s += " [音声\(audioIndex + 1)/\(st.audio_count)]" }
            if dualMono != 0 { s += dualMono == 1 ? " 主" : " 副" }
            fmt.append(s)
        }
        if !fmt.isEmpty { parts.append(fmt.joined(separator: " / ")) }
        videoView.setInfo(parts.joined(separator: "\n"))
    }

    // MARK: - Input

    private func changeVolume(_ delta: Float) {
        player.volume += delta
        videoView.showHUD("音量 \(Int((player.volume * 100).rounded()))%", nil, duration: 1.5)
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        if e.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return false }
        switch e.keyCode {
        case 126: zap(-1); return true    // up
        case 125: zap(1); return true     // down
        case 123: changeVolume(-0.05); return true  // left
        case 124: changeVolume(0.05); return true   // right
        case 53:  // esc
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            return true
        case 36: window.toggleFullScreen(nil); return true  // return
        default: break
        }
        guard let c = e.charactersIgnoringModifiers?.lowercased() else { return false }
        switch c {
        case "1", "2", "3", "4", "5", "6", "7", "8", "9": tuneKey(Int(c)!)
        case "0": tuneKey(10)
        case "-": tuneKey(11)
        case "^", "=": tuneKey(12)
        case "t": switchKind(.terrestrial)
        case "b": switchKind(.bs)
        case "c": switchKind(.cs)
        case "f": window.toggleFullScreen(nil)
        case "m": toggleMute(nil)
        case "i": toggleInfo(nil)
        case "l": toggleChannelList(nil)
        case "e": toggleProgramGuide(nil)
        case "d": cycleDualMono(nil)
        case "a": cycleAudio(nil)
        case " ": showChannelHUD()
        case "r": toggleRecording(nil)
        case "p": capture(nil)
        case "s": toggleSubtitles(nil)
        default: return false
        }
        return true
    }

    // MARK: - Actions

    private func fileStem() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        var stem = f.string(from: Date())
        if let ch = current { stem += "_" + ch.name }
        if let t = program?.present?.title, !t.isEmpty { stem += "_" + t }
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return String(stem.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) }).prefix(150).description
    }

    private func outputDir(_ base: FileManager.SearchPathDirectory) -> URL {
        let dir = FileManager.default.urls(for: base, in: .userDomainMask)[0].appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @objc func toggleRecording(_ sender: Any?) {
        if epgCapture.isRunning && !player.isRecording {
            videoView.showHUD("番組表の取得中は録画できません", nil, duration: 3)
            return
        }
        if player.isRecording {
            let bytes = player.stopRecording()
            videoView.showHUD("録画停止", String(format: "%.1f MB", Double(bytes) / 1e6), duration: 3)
            updateTitle()
            updateSleepActivity()
            return
        }
        let url = outputDir(.moviesDirectory).appendingPathComponent(fileStem() + ".ts")
        if player.startRecording(to: url) {
            videoView.showHUD("● 録画開始", url.lastPathComponent, duration: 3)
        } else {
            videoView.showHUD("録画を開始できませんでした", url.path, duration: 4)
        }
        updateTitle()
        updateSleepActivity()
    }

    @objc func capture(_ sender: Any?) {
        player.snapshot(aspect: videoView.displayAspect) { [weak self] img in
            guard let self, let img else { return }
            let url = self.outputDir(.picturesDirectory).appendingPathComponent(self.fileStem() + ".png")
            let rep = NSBitmapImageRep(cgImage: img)
            if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
                self.videoView.showHUD("キャプチャ保存", url.lastPathComponent, duration: 2)
            }
        }
    }

    @objc func toggleMute(_ sender: Any?) {
        player.isMuted.toggle()
        videoView.showHUD(player.isMuted ? "ミュート" : "ミュート解除", nil, duration: 1.5)
    }

    @objc func toggleInfo(_ sender: Any?) {
        showInfo.toggle()
        updateInfo()
    }

    @objc func toggleChannelList(_ sender: Any?) {
        if listPanel.isVisible { listPanel.orderOut(nil) } else { listPanel.show(relativeTo: window) }
    }

    @objc func toggleProgramGuide(_ sender: Any?) {
        if let g = guideWindow, g.isVisible, g.window?.isKeyWindow == true {
            g.close()
            return
        }
        if guideWindow == nil { guideWindow = ProgramGuideWindowController(controller: self) }
        guideWindow?.show()
    }

    // MARK: - 番組表の取得

    @objc func menuEPGCapture(_ sender: NSMenuItem) {
        if sender.tag == -2 {
            stopEPGCapture()
        } else {
            startEPGCapture(kinds: sender.tag < 0 ? SpaceKind.allCases : [SpaceKind(rawValue: sender.tag)!])
        }
    }

    func startEPGCapture(kinds: [SpaceKind]) {
        guard !scanning, !epgCapture.isRunning else { return }
        if player.isRecording {
            let a = NSAlert()
            a.messageText = "録画中は番組表の取得を行えません。"
            a.runModal()
            return
        }
        captureReturn = current
        if !epgCapture.start(kinds: kinds) {
            captureReturn = nil
            videoView.showHUD("番組表を取得するチャンネルがありません", nil, duration: 3)
        }
        updateSleepActivity()
    }

    /// Stops 番組表の取得 and returns to the channel that was being watched.
    func stopEPGCapture() {
        guard epgCapture.isRunning else { return }
        epgCapture.cancel()
        endEPGCapture(completed: false)
    }

    private func endEPGCapture(completed: Bool) {
        if let ch = captureReturn {
            captureReturn = nil
            select(ch, remember: true)
        }
        videoView.showHUD(completed ? "番組表の取得が完了しました" : "番組表の取得を中止しました", nil, duration: 3)
        guideWindow?.captureStateChanged()
        updateSleepActivity()
    }

    private func epgCaptureProgressed() {
        guideWindow?.captureStateChanged()
        if let stop = epgCapture.current {
            videoView.showHUD("番組表を取得中 \(epgCapture.index + 1)/\(epgCapture.stops.count)", stop.title, duration: 6)
        }
    }

    @objc func cycleDualMono(_ sender: Any?) {
        dualMono = (dualMono + 1) % 3
        player.setAudio(index: -1, dualMono: dualMono)
        videoView.showHUD(["音声: 主+副 (ステレオ)", "音声: 主 (左)", "音声: 副 (右)"][dualMono], nil, duration: 1.5)
        updateInfo()
    }

    @objc func cycleAudio(_ sender: Any?) {
        let n = max(stream?.audio_count ?? 1, 1)
        audioIndex = (audioIndex + 1) % n
        player.setAudio(index: audioIndex, dualMono: dualMono)
        videoView.showHUD("音声 \(audioIndex + 1)/\(n)", nil, duration: 1.5)
    }

    @objc func toggleDeinterlace(_ sender: NSMenuItem) {
        let on = !Settings.shared.deinterlace
        player.setDeinterlace(on)
    }

    @objc func togglePreventSleep(_ sender: NSMenuItem) {
        Settings.shared.preventSleep.toggle()
        updateSleepActivity()
        videoView.showHUD(Settings.shared.preventSleep ? "視聴中はスリープしない" : "視聴中もスリープする", nil, duration: 1.5)
    }

    // MARK: - 翻訳字幕

    /// Starts or stops the subtitle engine and sets the output delay to match the settings.
    private func applySubtitleSettings() {
        let s = Settings.shared
        if s.subtitles && SubtitleController.isSupported {
            subtitles.start()
            updateSubtitleSource()
            player.setOutputDelay(s.subtitleSync ? s.subtitleDelay : 0)
        } else {
            subtitles.stop()
            player.setOutputDelay(0)
        }
    }

    /// 自動: the 副音声 (right) of a dual-mono program, which is where the original-language
    /// commentary usually is; otherwise both channels.
    private func updateSubtitleSource() {
        var ch = Settings.shared.subtitleSource
        if ch == 0 {
            ch = 3
            if let cur = current,
               let ev = EPGStore.shared.schedules(for: [cur], from: Date()).first?.first(where: { $0.isOnAir() }),
               ev.audio.contains(0x02) {
                ch = 2
            }
        }
        subtitles.channel = ch
    }

    @objc func toggleSubtitles(_ sender: Any?) {
        guard SubtitleController.isSupported else {
            videoView.showHUD("翻訳字幕には macOS 26 以降が必要です", nil, duration: 3)
            return
        }
        Settings.shared.subtitles.toggle()
        applySubtitleSettings()
        let s = Settings.shared
        if s.subtitles {
            videoView.showHUD("翻訳字幕 オン", s.subtitleSync ? "映像を \(Int(s.subtitleDelay)) 秒遅らせて字幕に合わせます" : "字幕はできしだい表示します（数秒遅れます）", duration: 3)
        } else {
            videoView.showHUD("翻訳字幕 オフ", nil, duration: 1.5)
        }
    }

    @objc func setSubtitleSync(_ sender: NSMenuItem) {
        Settings.shared.subtitleSync = sender.tag == 1
        if Settings.shared.subtitles { applySubtitleSettings() }
    }

    @objc func setSubtitleDelay(_ sender: NSMenuItem) {
        Settings.shared.subtitleDelay = Double(sender.tag)
        if Settings.shared.subtitles { applySubtitleSettings() }
    }

    @objc func setSubtitleSource(_ sender: NSMenuItem) {
        Settings.shared.subtitleSource = sender.tag
        updateSubtitleSource()
    }

    @objc func toggleSubtitleOriginal(_ sender: NSMenuItem) {
        Settings.shared.subtitleShowOriginal.toggle()
    }

    @objc func toggleFloat(_ sender: NSMenuItem) {
        window.level = window.level == .floating ? .normal : .floating
    }

    @objc func volumeUp(_ sender: Any?) { changeVolume(0.05) }
    @objc func volumeDown(_ sender: Any?) { changeVolume(-0.05) }
    @objc func nextChannel(_ sender: Any?) { zap(1) }
    @objc func prevChannel(_ sender: Any?) { zap(-1) }
    @objc func menuTune(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let ch = store.find(id: id) { tune(ch) }
    }
    @objc func menuKind(_ sender: NSMenuItem) {
        if let k = SpaceKind(rawValue: sender.tag) { switchKind(k) }
    }
    @objc func setSize(_ sender: NSMenuItem) {
        let w = CGFloat(sender.tag)
        var f = window.frame
        let content = NSRect(x: 0, y: 0, width: w, height: w * 9 / 16)
        let nf = window.frameRect(forContentRect: content)
        f.origin.y += f.height - nf.height
        f.size = nf.size
        window.setFrame(f, display: true, animate: true)
    }

    @objc func startScan(_ sender: Any?) {
        guard !scanning else { return }
        stopEPGCapture()
        let a = NSAlert()
        a.messageText = "チャンネルスキャン"
        a.informativeText = "\(Settings.shared.groups.joined(separator: ", ")) をスキャンします。\n地デジは電波の無いチャンネルで1ch当たり約5秒かかるため、数分かかります。\nスキャン中は視聴中のチューナーを使用します。"
        a.addButton(withTitle: "開始")
        a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        runScan()
    }

    private func runScan() {
        scanning = true
        let groups = Settings.shared.groups
        player.scan(groups: groups, progress: { [weak self] p in
            self?.videoView.setCenterMessage(String(format: "スキャン中 %d%%  %@\n検出: %d サービス", Int(p.fraction * 100), p.message, p.found))
        }, done: { [weak self] list in
            guard let self else { return }
            self.scanning = false
            for g in groups {
                let found = list.filter { $0.group == g }
                if !found.isEmpty { self.store.replace(group: g, with: found) }
            }
            self.videoView.setCenterMessage(nil)
            self.buildMenus()
            self.listPanel.reload()
            self.guideWindow?.reload()
            let tv = list.filter { [0x01, 0xA5, 0xAD].contains($0.serviceType) }.count
            self.videoView.showHUD("スキャン完了: \(tv) チャンネル", nil)
            if let ch = self.current.flatMap({ self.store.find(id: $0.id) }) ?? self.store.tvChannels.first {
                self.tune(ch)
            }
        })
    }

    @objc func showSettings(_ sender: Any?) {
        let s = Settings.shared
        let a = NSAlert()
        a.messageText = "設定"
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "キャンセル")
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        let host = NSTextField(string: s.host)
        let port = NSTextField(string: String(s.port))
        let groups = NSTextField(string: s.groups.joined(separator: ","))
        let latency = NSTextField(string: String(format: "%.2f", s.latency))
        let b25 = NSButton(checkboxWithTitle: "サーバー側でスクランブル解除を要求する (eDesireToUseB25)", target: nil, action: nil)
        b25.state = s.serverB25 ? .on : .off
        let subch = NSButton(checkboxWithTitle: "サブチャンネル（NHK総合2 等）も選局対象にする", target: nil, action: nil)
        subch.state = s.showSubChannels ? .on : .off
        for f in [host, port, groups, latency] { f.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        grid.addRow(with: [NSTextField(labelWithString: "サーバー"), host])
        grid.addRow(with: [NSTextField(labelWithString: "ポート"), port])
        grid.addRow(with: [NSTextField(labelWithString: "グループ"), groups])
        grid.addRow(with: [NSTextField(labelWithString: "遅延 (秒)"), latency])
        grid.addRow(with: [NSView(), b25])
        grid.addRow(with: [NSView(), subch])
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 175)
        a.accessoryView = grid
        guard a.runModal() == .alertFirstButtonReturn else { return }
        s.host = host.stringValue.trimmingCharacters(in: .whitespaces)
        s.port = Int(port.stringValue) ?? 1192
        s.groups = groups.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        s.latency = max(0.05, min(3.0, Double(latency.stringValue) ?? 0.3))
        s.serverB25 = b25.state == .on
        s.showSubChannels = subch.state == .on
        buildMenus()
        listPanel.reload()
        guideWindow?.reload()
        player.stop()
        if let ch = current { tune(ch) }
    }

    // MARK: - Menus

    func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "\(appName) について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "設定…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "\(appName) を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "\(appName) を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let chItem = NSMenuItem()
        let chMenu = NSMenu(title: "チャンネル")
        addZapItems(to: chMenu)
        chMenu.addItem(.separator())
        for kind in SpaceKind.allCases { chMenu.addItem(kindMenuItem(kind)) }
        chMenu.addItem(.separator())
        chMenu.addItem(withTitle: "チャンネル一覧", action: #selector(toggleChannelList(_:)), keyEquivalent: "l").target = self
        chMenu.addItem(withTitle: "番組表", action: #selector(toggleProgramGuide(_:)), keyEquivalent: "e").target = self
        chMenu.addItem(epgCaptureMenuItem())
        chMenu.addItem(.separator())
        chMenu.addItem(withTitle: "チャンネルスキャン…", action: #selector(startScan(_:)), keyEquivalent: "").target = self
        chItem.submenu = chMenu
        main.addItem(chItem)

        main.addItem(makeEditMenuItem())

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "表示")
        view.addItem(withTitle: "フルスクリーン", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        addDisplayOptionItems(to: view)
        view.addItem(.separator())
        addRecordItems(to: view)
        view.addItem(.separator())
        addSizeItems(to: view)
        view.addItem(.separator())
        // handled by the program guide window (responder chain)
        view.addItem(withTitle: "番組表を拡大", action: #selector(ProgramGuideWindowController.zoomInGuide(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "番組表を縮小", action: #selector(ProgramGuideWindowController.zoomOutGuide(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "番組表で現在時刻へ移動", action: #selector(ProgramGuideWindowController.goToNow(_:)), keyEquivalent: "")
        viewItem.submenu = view
        main.addItem(viewItem)

        let audioItem = NSMenuItem()
        audioItem.submenu = makeAudioMenu()
        main.addItem(audioItem)

        let subItem = NSMenuItem()
        subItem.submenu = makeSubtitleMenu()
        main.addItem(subItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "ウインドウ")
        win.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    /// Right-click menu on the video: the frequently used items at the top level, the rest in submenus.
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        if let ch = current {
            let key = ch.remoteKey > 0 ? "\(ch.remoteKey)  " : ""
            let title = menu.addItem(withTitle: "\(key)\(ch.name)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            if let p = program?.present?.title {
                let sub = menu.addItem(withTitle: p, action: nil, keyEquivalent: "")
                sub.isEnabled = false
                sub.indentationLevel = 1
            }
            menu.addItem(.separator())
        }
        for kind in SpaceKind.allCases { menu.addItem(kindMenuItem(kind)) }
        addZapItems(to: menu)
        menu.addItem(withTitle: "チャンネル一覧 (L)", action: #selector(toggleChannelList(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "番組表 (E)", action: #selector(toggleProgramGuide(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        addRecordItems(to: menu)
        menu.addItem(withTitle: "フルスクリーン (F)", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        let audioItem = NSMenuItem(title: "音声", action: nil, keyEquivalent: "")
        audioItem.submenu = makeAudioMenu()
        menu.addItem(audioItem)
        let subItem = NSMenuItem(title: "字幕", action: nil, keyEquivalent: "")
        subItem.submenu = makeSubtitleMenu()
        menu.addItem(subItem)
        let viewItem = NSMenuItem(title: "表示", action: nil, keyEquivalent: "")
        let view = NSMenu(title: "表示")
        addDisplayOptionItems(to: view)
        view.addItem(.separator())
        addSizeItems(to: view)
        viewItem.submenu = view
        menu.addItem(viewItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "チャンネルスキャン…", action: #selector(startScan(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "設定…", action: #selector(showSettings(_:)), keyEquivalent: "").target = self
        return menu
    }

    private func epgCaptureMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "番組表の取得", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for k in SpaceKind.allCases {
            let mi = sub.addItem(withTitle: k.title, action: #selector(menuEPGCapture(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = k.rawValue
        }
        let all = sub.addItem(withTitle: "すべて", action: #selector(menuEPGCapture(_:)), keyEquivalent: "")
        all.target = self
        all.tag = -1
        sub.addItem(.separator())
        let stop = sub.addItem(withTitle: "取得を中止", action: #selector(menuEPGCapture(_:)), keyEquivalent: "")
        stop.target = self
        stop.tag = -2
        item.submenu = sub
        return item
    }

    /// Standard editing commands, so that text fields (search, settings) get copy & paste.
    private func makeEditMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "検索", action: #selector(ProgramGuideWindowController.performFindPanelAction(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .option]
        item.submenu = edit
        return item
    }

    private func addZapItems(to menu: NSMenu) {
        menu.addItem(withTitle: "次のチャンネル (↓)", action: #selector(nextChannel(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "前のチャンネル (↑)", action: #selector(prevChannel(_:)), keyEquivalent: "").target = self
    }

    private func kindMenuItem(_ kind: SpaceKind) -> NSMenuItem {
        let list = store.channels(of: kind)
        let item = NSMenuItem(title: kind.title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let sw = sub.addItem(withTitle: "\(kind.title)に切替 (\(["T", "B", "C"][kind.rawValue]))", action: #selector(menuKind(_:)), keyEquivalent: "")
        sw.target = self
        sw.tag = kind.rawValue
        sub.addItem(.separator())
        for ch in list {
            let key = ch.remoteKey > 0 ? String(format: "%2d  ", ch.remoteKey) : "     "
            let mi = sub.addItem(withTitle: "\(key)\(ch.name)", action: #selector(menuTune(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ch.id
        }
        item.submenu = sub
        item.isEnabled = !list.isEmpty
        return item
    }

    private func addDisplayOptionItems(to menu: NSMenu) {
        menu.addItem(withTitle: "情報表示", action: #selector(toggleInfo(_:)), keyEquivalent: "i").target = self
        menu.addItem(withTitle: "インタレース解除 (bwdif)", action: #selector(toggleDeinterlace(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "常に手前に表示", action: #selector(toggleFloat(_:)), keyEquivalent: "t").target = self
        menu.addItem(withTitle: "視聴中はスリープしない", action: #selector(togglePreventSleep(_:)), keyEquivalent: "").target = self
    }

    private func addRecordItems(to menu: NSMenu) {
        menu.addItem(withTitle: "録画開始 (R)", action: #selector(toggleRecording(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "キャプチャ (P)", action: #selector(capture(_:)), keyEquivalent: "").target = self
    }

    private func addSizeItems(to menu: NSMenu) {
        for (title, w) in [("640x360", 640), ("960x540", 960), ("1280x720", 1280), ("1920x1080", 1920)] {
            let it = menu.addItem(withTitle: title, action: #selector(setSize(_:)), keyEquivalent: "")
            it.target = self
            it.tag = w
        }
    }

    private func makeAudioMenu() -> NSMenu {
        let audio = NSMenu(title: "音声")
        audio.addItem(withTitle: "音量を上げる (→)", action: #selector(volumeUp(_:)), keyEquivalent: "").target = self
        audio.addItem(withTitle: "音量を下げる (←)", action: #selector(volumeDown(_:)), keyEquivalent: "").target = self
        audio.addItem(withTitle: "ミュート (M)", action: #selector(toggleMute(_:)), keyEquivalent: "").target = self
        audio.addItem(.separator())
        audio.addItem(withTitle: "二重音声切替 (D)", action: #selector(cycleDualMono(_:)), keyEquivalent: "").target = self
        audio.addItem(withTitle: "音声ストリーム切替 (A)", action: #selector(cycleAudio(_:)), keyEquivalent: "").target = self
        return audio
    }

    private func makeSubtitleMenu() -> NSMenu {
        let menu = NSMenu(title: "字幕")
        menu.addItem(withTitle: "翻訳字幕（英語→日本語） (S)", action: #selector(toggleSubtitles(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for (title, tag) in [("字幕をできしだい表示（映像は遅らせない）", 0), ("映像を遅らせて字幕に合わせる", 1)] {
            let it = menu.addItem(withTitle: title, action: #selector(setSubtitleSync(_:)), keyEquivalent: "")
            it.target = self
            it.tag = tag
        }
        let delayItem = NSMenuItem(title: "映像を遅らせる時間", action: nil, keyEquivalent: "")
        let delay = NSMenu()
        for sec in [6, 8, 10, 12] {
            let it = delay.addItem(withTitle: "\(sec) 秒", action: #selector(setSubtitleDelay(_:)), keyEquivalent: "")
            it.target = self
            it.tag = sec
        }
        delayItem.submenu = delay
        menu.addItem(delayItem)
        menu.addItem(.separator())
        let srcItem = NSMenuItem(title: "認識する音声", action: nil, keyEquivalent: "")
        let src = NSMenu()
        for (title, tag) in [("自動（二重音声なら副音声）", 0), ("主音声（左）", 1), ("副音声（右）", 2), ("左右を混ぜる", 3)] {
            let it = src.addItem(withTitle: title, action: #selector(setSubtitleSource(_:)), keyEquivalent: "")
            it.target = self
            it.tag = tag
        }
        srcItem.submenu = src
        menu.addItem(srcItem)
        menu.addItem(withTitle: "英語の原文も表示", action: #selector(toggleSubtitleOriginal(_:)), keyEquivalent: "").target = self
        return menu
    }

    /// Keeps check marks and titles current in both the menu bar and the right-click menu.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(menuTune(_:)):
            item.state = (item.representedObject as? String) == current?.id ? .on : .off
        case #selector(toggleRecording(_:)):
            item.title = player.isRecording ? "録画停止 (R)" : "録画開始 (R)"
        case #selector(toggleMute(_:)):
            item.state = player.isMuted ? .on : .off
        case #selector(toggleInfo(_:)):
            item.state = showInfo ? .on : .off
        case #selector(toggleDeinterlace(_:)):
            item.state = Settings.shared.deinterlace ? .on : .off
        case #selector(toggleFloat(_:)):
            item.state = window.level == .floating ? .on : .off
        case #selector(togglePreventSleep(_:)):
            item.state = Settings.shared.preventSleep ? .on : .off
        case #selector(toggleSubtitles(_:)):
            item.state = Settings.shared.subtitles ? .on : .off
            return SubtitleController.isSupported
        case #selector(setSubtitleSync(_:)):
            item.state = (Settings.shared.subtitleSync ? 1 : 0) == item.tag ? .on : .off
        case #selector(setSubtitleDelay(_:)):
            item.state = Int(Settings.shared.subtitleDelay) == item.tag ? .on : .off
            return Settings.shared.subtitleSync
        case #selector(setSubtitleSource(_:)):
            item.state = Settings.shared.subtitleSource == item.tag ? .on : .off
        case #selector(toggleSubtitleOriginal(_:)):
            item.state = Settings.shared.subtitleShowOriginal ? .on : .off
        case #selector(startScan(_:)):
            return !scanning
        case #selector(menuEPGCapture(_:)):
            return item.tag == -2 ? epgCapture.isRunning : !epgCapture.isRunning && !scanning
        case #selector(toggleProgramGuide(_:)):
            item.state = guideWindow?.isVisible == true ? .on : .off
        default:
            break
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    var currentChannel: Channel? { current }
    var currentProgramTitle: String? { program?.present?.title }
}
