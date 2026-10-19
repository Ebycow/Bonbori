// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import AVFoundation

/// Hosts the AVSampleBufferDisplayLayer with correct display aspect ratio, plus overlays.
final class VideoView: NSView {
    let displayLayer: AVSampleBufferDisplayLayer
    var displayAspect: CGFloat = 16.0 / 9.0 { didSet { needsLayout = true } }
    var onKey: ((NSEvent) -> Bool)?
    var onDoubleClick: (() -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onContextMenu: (() -> NSMenu?)?

    let hud = OverlayLabel(fontSize: 22, weight: .semibold)
    let subHud = OverlayLabel(fontSize: 15, weight: .regular)
    let infoBar = OverlayLabel(fontSize: 12, weight: .regular, mono: true)
    let centerMessage = OverlayLabel(fontSize: 16, weight: .medium)
    let subtitles = SubtitleOverlay(frame: .zero)
    private var hudTimer: Timer?

    init(layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        wantsLayer = true
        self.layer = CALayer()
        self.layer?.backgroundColor = NSColor.black.cgColor
        self.layer?.addSublayer(displayLayer)
        // Keep the video off a hardware overlay plane. When macOS scans the video layer out
        // directly (windowed mode on Apple Silicon), the picture can jitter horizontally by
        // about a pixel and the window edge flickers; it stops whenever the window server
        // composites the layer itself (e.g. during screen recording). A not-quite-opaque
        // layer is composited instead (seen on M1 + Pro Display XDR, macOS 27).
        displayLayer.opacity = 0.995
        addSubview(subtitles)
        for v in [hud, subHud, infoBar, centerMessage] {
            addSubview(v)
            v.isHidden = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        var w = b.width, h = b.width / displayAspect
        if h > b.height { h = b.height; w = h * displayAspect }
        displayLayer.frame = CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
        CATransaction.commit()
        subtitles.place(in: displayLayer.frame)

        let pad: CGFloat = 16
        let maxW = b.width - pad * 2
        hud.frame.origin = CGPoint(x: pad, y: pad)
        hud.fit(maxWidth: maxW)
        subHud.frame.origin = CGPoint(x: pad, y: hud.frame.maxY + 6)
        subHud.fit(maxWidth: maxW)
        infoBar.fit(maxWidth: maxW)
        infoBar.frame.origin = CGPoint(x: pad, y: b.height - infoBar.frame.height - pad)
        centerMessage.fit(maxWidth: maxW)
        centerMessage.frame.origin = CGPoint(x: (b.width - centerMessage.frame.width) / 2,
                                             y: (b.height - centerMessage.frame.height) / 2)
    }

    func showHUD(_ title: String, _ sub: String?, duration: TimeInterval = 4) {
        hud.text = title
        hud.isHidden = false
        subHud.text = sub ?? ""
        subHud.isHidden = (sub ?? "").isEmpty
        needsLayout = true
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.hud.isHidden = true
            self?.subHud.isHidden = true
        }
    }

    func setCenterMessage(_ text: String?) {
        centerMessage.text = text ?? ""
        centerMessage.isHidden = text == nil
        needsLayout = true
    }

    func setInfo(_ text: String?) {
        infoBar.text = text ?? ""
        infoBar.isHidden = text == nil
        needsLayout = true
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }

    /// Right-click / Control-click. Built on demand so it reflects the current channel list and state.
    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?() ?? super.menu(for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
}

/// Rounded translucent label used for HUD / info overlays.
final class OverlayLabel: NSView {
    private let field = NSTextField(labelWithString: "")
    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    init(fontSize: CGFloat, weight: NSFont.Weight, mono: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 8
        field.font = mono ? .monospacedSystemFont(ofSize: fontSize, weight: weight) : .systemFont(ofSize: fontSize, weight: weight)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 3
        field.cell?.truncatesLastVisibleLine = true
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func fit(maxWidth: CGFloat) {
        let inset: CGFloat = 10
        field.preferredMaxLayoutWidth = max(50, maxWidth - inset * 2)
        let size = field.sizeThatFits(NSSize(width: maxWidth - inset * 2, height: 200))
        let w = min(size.width, maxWidth - inset * 2)
        field.frame = NSRect(x: inset, y: 5, width: w, height: size.height)
        frame.size = NSSize(width: w + inset * 2, height: size.height + 10)
    }
}
