// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import QuartzCore

/// The caption plane over the picture. Rows are drawn once, for the size of the picture, and stay
/// in their layers until a clear or something written over them takes them away. Flashing is left
/// to Core Animation. While the window is being resized the layers simply scale, and the rows are
/// drawn again once it comes to rest.
final class CaptionOverlay: NSView {
    enum Plane: CaseIterable {
        case caption, superimpose
    }

    var options = CaptionRenderOptions() {
        didSet { redraw() }
    }
    /// 中央に小さく表示: the plane takes up two thirds of the picture, at the top in the middle.
    var isCentered = false {
        didSet { redraw() }
    }

    private static let flashPeriod: CFTimeInterval = 1

    private final class Shown {
        let content: Content
        var layers: [(layer: CALayer, rect: CGRect)] = []
        var shift: CGFloat = 0

        init(_ content: Content) { self.content = content }
    }

    private enum Content {
        case row(CaptionRow)
        case bitmap(CaptionBitmap)
    }

    private var shown: [Plane: [Shown]] = [:]
    private var drawnScale = CGSize.zero
    private var redrawTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        place()
        // only once it stops changing: drawing on every step of a resize is wasted
        guard scale() != drawnScale else { return }
        redrawTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in self?.redraw() }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    func clear() {
        for plane in Plane.allCases { clear(plane) }
    }

    func clear(_ plane: Plane) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shown[plane]?.forEach { $0.layers.forEach { $0.layer.removeFromSuperlayer() } }
        CATransaction.commit()
        shown[plane] = []
    }

    /// Shows items that take effect at the same moment.
    func apply(_ items: [CaptionItem], to plane: Plane) {
        if let last = items.lastIndex(where: { if case .clear = $0 { return true } else { return false } }) {
            clear(plane)
            return apply(Array(items[(last + 1)...]), to: plane)
        }
        var added: [Shown] = []
        for item in items {
            switch item {
            case .row(let row): added.append(Shown(.row(row)))
            case .bitmap(let bitmap): added.append(Shown(.bitmap(bitmap)))
            case .clear: break
            }
        }
        guard !added.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeCovered(by: added, in: plane)
        shown[plane, default: []] += added
        for s in added { draw(s) }
        place()
        CATransaction.commit()
    }

    // MARK: - Layers

    /// What is written over a row replaces it, even when no clear came first.
    private func removeCovered(by added: [Shown], in plane: Plane) {
        let news = added.compactMap { footprint(of: $0) }
        shown[plane]?.removeAll { old in
            guard let rect = footprint(of: old), isCovered(rect, by: news) else { return false }
            old.layers.forEach { $0.layer.removeFromSuperlayer() }
            return true
        }
    }

    private func footprint(of shown: Shown) -> CGRect? {
        guard case .row(let row) = shown.content else { return nil }
        let height = CaptionRenderer.height(of: row)
        return CGRect(x: CGFloat(row.x), y: CGFloat(row.y + 1) - height, width: CaptionRenderer.width(of: row), height: height)
    }

    private func isCovered(_ rect: CGRect, by others: [CGRect]) -> Bool {
        guard !rect.isEmpty else { return false }
        var reached = rect.minX
        for other in others.filter({ $0.minY <= rect.minY && $0.maxY >= rect.maxY }).sorted(by: { $0.minX < $1.minX }) {
            if other.minX > reached { break }
            reached = max(reached, other.maxX)
        }
        return reached >= rect.maxX
    }

    /// What the rows have to be drawn again for.
    private func scale() -> CGSize {
        let shrink: CGFloat = isCentered ? 1.5 : 1
        return CGSize(width: bounds.width / shrink, height: bounds.height / shrink)
    }

    /// From the caption plane (y downwards) to the view (y upwards).
    private func transform(for area: CaptionPlaneArea) -> (scaleX: CGFloat, scaleY: CGFloat, offsetX: CGFloat) {
        let size = area.planeSize
        let shrink: CGFloat = isCentered ? 1.5 : 1
        return (bounds.width / size.width / shrink, bounds.height / size.height / shrink, isCentered ? bounds.width / 6 : 0)
    }

    private func draw(_ s: Shown) {
        s.layers.forEach { $0.layer.removeFromSuperlayer() }
        s.layers = []
        let backing = window?.backingScaleFactor ?? 2
        switch s.content {
        case .row(let row):
            let t = transform(for: row.area)
            for part in CaptionRenderer.render(row, options: options, scaleX: t.scaleX * backing, scaleY: t.scaleY * backing) {
                s.layers.append((makeLayer(part.image, flash: part.flash), part.rect))
            }
        case .bitmap(let bitmap):
            let rect = CGRect(x: bitmap.area.x + bitmap.x, y: bitmap.area.y + bitmap.y, width: bitmap.image.width, height: bitmap.image.height)
            s.layers.append((makeLayer(bitmap.image, flash: .none), rect))
            if let flashing = bitmap.flashing {
                s.layers[0].layer.contents = flashing
                s.layers.append((makeLayer(bitmap.image, flash: .normal), rect))
            }
        }
    }

    private func makeLayer(_ image: CGImage, flash: CaptionFlash) -> CALayer {
        let sublayer = CALayer()
        sublayer.contents = image
        sublayer.anchorPoint = .zero
        layer?.addSublayer(sublayer)
        if flash != .none, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = flash == .normal ? [1, 0] : [0, 1]
            animation.keyTimes = [0, 0.5]
            animation.calculationMode = .discrete
            animation.duration = CaptionOverlay.flashPeriod
            animation.repeatCount = .infinity
            // all on the same beat, whenever they appeared
            animation.beginTime = floor(CACurrentMediaTime())
            sublayer.add(animation, forKey: "flash")
        }
        return sublayer
    }

    /// Puts the layers where they belong for the present size of the view.
    private func place() {
        for plane in Plane.allCases { closeGaps(in: plane) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in shown.values.joined() {
            let area: CaptionPlaneArea
            switch s.content {
            case .row(let row): area = row.area
            case .bitmap(let bitmap): area = bitmap.area
            }
            let t = transform(for: area)
            for (sublayer, rect) in s.layers {
                let moved = rect.offsetBy(dx: 0, dy: s.shift)
                sublayer.bounds = CGRect(x: 0, y: 0, width: moved.width * t.scaleX, height: moved.height * t.scaleY)
                sublayer.position = CGPoint(x: t.offsetX + moved.minX * t.scaleX, y: bounds.height - moved.maxY * t.scaleY)
            }
        }
        CATransaction.commit()
    }

    /// With the 振り仮名 left out, the lines above them move down to take up the room.
    private func closeGaps(in plane: Plane) {
        let rows: [(Shown, CaptionRow)] = (shown[plane] ?? []).compactMap {
            if case .row(let row) = $0.content { return ($0, row) }
            return nil
        }
        let isRuby: (CaptionRow) -> Bool = { row in row.runs.allSatisfy { $0.cells.isEmpty || $0.style.size == .small } }
        var rubyLines: [Int: CGFloat] = [:]
        if options.hidesRuby {
            let kept = Set(rows.filter { !isRuby($0.1) }.map(\.1.y))
            for (_, row) in rows where isRuby(row) && !kept.contains(row.y) { rubyLines[row.y] = CaptionRenderer.height(of: row) }
        }
        for (s, row) in rows {
            s.shift = rubyLines.reduce(0) { $0 + ($1.key > row.y ? $1.value : 0) }
        }
    }

    private func redraw() {
        redrawTimer?.invalidate()
        drawnScale = scale()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in shown.values.joined() { draw(s) }
        place()
        CATransaction.commit()
    }
}
