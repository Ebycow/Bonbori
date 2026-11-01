// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import CoreText
import QuartzCore

/// Flows comments over the picture.
///
/// Each comment is drawn once into a bitmap off the main thread; after that Core Animation moves
/// it, so a comment costs the app nothing while it is on screen. Comments live on a stage of a
/// fixed height that is scaled to the view, so that resizing the window leaves them in place.
final class CommentOverlay: NSView {
    /// Lines on the picture; the text size follows from it.
    var lineCount = 14 {
        didSet { clear() }
    }
    var commentOpacity: Float = 1 {
        didSet { stage.opacity = commentOpacity }
    }

    private static let stageHeight: CGFloat = 1080
    private static let duration: CFTimeInterval = 4
    /// Past these many, comments are dropped rather than falling behind.
    private static let maxOnStage = 400
    private static let maxBeingDrawn = 30

    private let stage = CALayer()
    private let drawing = DispatchQueue(label: "tv.jikkyo.draw", qos: .userInitiated)
    private var beingDrawn = 0
    /// Comments of an earlier generation were cleared while being drawn or delayed.
    private var generation = 0

    private struct Scrolling {
        let start: CFTimeInterval
        let width: CGFloat
    }
    private var scrollLines: [Scrolling?] = []
    /// Until when each line is taken by a fixed comment.
    private var topLines: [CFTimeInterval] = []
    private var bottomLines: [CFTimeInterval] = []

    private var lineHeight: CGFloat { CommentOverlay.stageHeight / CGFloat(lineCount) }
    private var stageWidth: CGFloat { stage.bounds.width }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        stage.anchorPoint = .zero
        stage.position = .zero
        layer?.addSublayer(stage)
        clear()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.height > 0 else { return }
        let scale = bounds.height / CommentOverlay.stageHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.bounds = CGRect(x: 0, y: 0, width: bounds.width / scale, height: CommentOverlay.stageHeight)
        stage.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    func clear() {
        generation += 1
        stage.sublayers?.forEach { $0.removeFromSuperlayer() }
        scrollLines = Array(repeating: nil, count: lineCount)
        topLines = Array(repeating: 0, count: lineCount)
        bottomLines = Array(repeating: 0, count: lineCount)
    }

    /// Shows `comment` after `delay` seconds.
    func add(_ comment: Comment, delay: TimeInterval) {
        guard (stage.sublayers?.count ?? 0) < CommentOverlay.maxOnStage, beingDrawn < CommentOverlay.maxBeingDrawn,
              bounds.height > 0 else { return }
        beingDrawn += 1
        let generation = generation
        let fontSize = lineHeight * 0.8
        let pixels = bounds.height / CommentOverlay.stageHeight * (window?.backingScaleFactor ?? 2)
        let due = DispatchTime.now() + delay
        drawing.async { [weak self] in
            let sprite = Sprite(comment, fontSize: fontSize, pixelsPerUnit: pixels)
            DispatchQueue.main.async {
                self?.beingDrawn -= 1
                DispatchQueue.main.asyncAfter(deadline: due) {
                    guard let self, generation == self.generation, let sprite else { return }
                    self.show(sprite, comment.position)
                }
            }
        }
    }

    private func show(_ sprite: Sprite, _ position: Comment.Position) {
        let now = CACurrentMediaTime()
        let sprite = sprite.fitted(toLines: lineCount, lineHeight: lineHeight)
        let span = max(1, Int((sprite.size.height / lineHeight - 0.01).rounded(.up)))
        let layer = CALayer()
        layer.contents = sprite.image
        layer.bounds = CGRect(origin: .zero, size: sprite.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let animation: CABasicAnimation
        switch position {
        case .scroll:
            let line = scrollLine(span: span, width: sprite.size.width, now: now)
            for i in line..<(line + span) { scrollLines[i] = Scrolling(start: now, width: sprite.size.width) }
            let y = y(ofLine: line, span: span, height: sprite.size.height)
            let from = stageWidth + sprite.size.width / 2, to = -sprite.size.width / 2
            layer.position = CGPoint(x: to, y: y)
            animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = from
            animation.toValue = to
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
        case .top, .bottom:
            let line = position == .top
                ? fixedLine(&topLines, span: span, now: now)
                : lineCount - span - fixedLine(&bottomLines, span: span, now: now)
            layer.position = CGPoint(x: stageWidth / 2, y: y(ofLine: line, span: span, height: sprite.size.height))
            // does nothing but lasting as long as the comment should
            animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 1
        }
        animation.duration = CommentOverlay.duration
        layer.add(animation, forKey: "life")
        stage.addSublayer(layer)
        CATransaction.commit()
    }

    /// Lines count from the top; the stage's origin is at the bottom.
    private func y(ofLine line: Int, span: Int, height: CGFloat) -> CGFloat {
        CommentOverlay.stageHeight - (CGFloat(line) + CGFloat(span) / 2) * lineHeight
    }

    /// The first `span` lines from the top where a comment of `width` can start now without
    /// overlapping the one before it, or else those that were last used longest ago.
    private func scrollLine(span: Int, width: CGFloat, now: CFTimeInterval) -> Int {
        let last = lineCount - span
        for line in 0...last where (line..<(line + span)).allSatisfy({ isFree($0, width: width, now: now) }) {
            return line
        }
        let oldest = (0...last).min { (scrollLines[$0]?.start ?? 0) < (scrollLines[$1]?.start ?? 0) }
        return oldest ?? 0
    }

    private func isFree(_ line: Int, width: CGFloat, now: CFTimeInterval) -> Bool {
        guard let prev = scrollLines[line] else { return true }
        let d = CommentOverlay.duration, w = stageWidth
        let elapsed = now - prev.start
        // its tail has come onto the picture
        guard elapsed * (w + prev.width) / d >= prev.width else { return false }
        // and it leaves before the new one, which may be faster, reaches the left edge
        return prev.start + d <= now + d * w / (w + width)
    }

    /// Takes the first free lines of `lines` (or the first ones) and returns where they start.
    private func fixedLine(_ lines: inout [CFTimeInterval], span: Int, now: CFTimeInterval) -> Int {
        let free = (0...(lineCount - span)).first { line in (line..<(line + span)).allSatisfy { lines[$0] <= now } } ?? 0
        for i in free..<(free + span) { lines[i] = now + CommentOverlay.duration }
        return free
    }
}

/// A comment drawn into a bitmap, outlined so that it can be read on any picture.
private struct Sprite {
    let image: CGImage
    /// In stage units.
    let size: CGSize

    /// Limits a bitmap to something the window server can handle comfortably.
    private static let maxPixels: CGFloat = 4096

    private init(image: CGImage, size: CGSize) {
        self.image = image
        self.size = size
    }

    init?(_ comment: Comment, fontSize: CGFloat, pixelsPerUnit: CGFloat) {
        let ratio: CGFloat
        switch comment.size {
        case .small: ratio = 0.75
        case .medium: ratio = 1
        case .big: ratio = 1.3
        }
        let size = fontSize * ratio
        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let lines = comment.text.split(omittingEmptySubsequences: false) { $0.isNewline }.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: String($0), attributes: attributes))
        }
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let outline = size * 0.09
        let pad = outline + 1
        let lineHeight = size * 1.25
        let width = (widths.max() ?? 0) + pad * 2
        let height = lineHeight * CGFloat(lines.count)
        guard width > pad * 2 else { return nil }

        let scale = min(pixelsPerUnit, Sprite.maxPixels / max(width, height))
        guard let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(outline * 2)
        let c = comment.color
        let edge: CGFloat = c.brightness < 0.25 ? 1 : 0  // dark comments get a light edge
        ctx.setStrokeColor(red: edge, green: edge, blue: edge, alpha: 0.9)
        ctx.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        for mode in [CGTextDrawingMode.stroke, .fill] {
            ctx.setTextDrawingMode(mode)
            for (i, line) in lines.enumerated() {
                let centered = comment.position != .scroll
                let x = pad + (centered ? (width - pad * 2 - widths[i]) / 2 : 0)
                ctx.textPosition = CGPoint(x: x, y: height - lineHeight * CGFloat(i + 1) + size * 0.32)
                CTLineDraw(line, ctx)
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        self.image = image
        self.size = CGSize(width: width, height: height)
    }

    /// Fits the comment to the height of the picture.
    func fitted(toLines lineCount: Int, lineHeight: CGFloat) -> Sprite {
        let limit = CGFloat(lineCount) * lineHeight
        guard size.height > limit else { return self }
        let shrink = limit / size.height
        return Sprite(image: image, size: CGSize(width: size.width * shrink, height: limit))
    }
}
