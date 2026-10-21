import AppKit
import ImageIO
import PicttyCore
import QuartzCore

@MainActor
protocol CanvasDelegate: AnyObject {
    func canvasRequestsStep(_ delta: Int, pane: Int)
    /// A gesture changed zoom or pan.
    func canvasViewportChanged(pane: Int)
    func canvasNeedsFull(_ url: URL)
    /// The picture is larger than a GPU texture and the zoom shows more than the capped decode.
    func canvasNeedsDetail(_ url: URL)
    func canvasToggleFullScreen()
    func canvasSmartZoom(pane: Int, at point: CGPoint)
    func canvasDidResize()
    func canvasRefined(pane: Int)
    func canvasContextMenu(pane: Int) -> NSMenu?
    func canvasWipeMoved()
    /// ⌥-click with the loupe up: the colour under the pointer.
    func canvasPickedColour(_ hex: String)
    /// A click while `picking`: the point in the picture's own 0…1 coordinates, top-left origin.
    func canvasPicked(_ point: CGPoint)
    /// A trackpad rotation went past 45°: quarter turns, clockwise positive.
    func canvasRotateGesture(_ quarterTurns: Int)
}

/// GPU-composited picture surface, one clipped pane per picture.
///
/// While anything moves, Core Animation filters the decode on the GPU: trilinear mipmaps
/// down, bilinear up. Whenever the screen-sized ImageIO preview has enough pixels it is shown
/// instead of the full decode. Every frame is placed on whole device pixels.
///
/// Once the view rests, the visible region (plus a margin) is re-rendered with Lanczos at
/// exactly one pixel per device pixel and laid over the GPU picture. Trilinear goes soft
/// between mip levels and bilinear goes soft above 100 %; the settled render is sharp in
/// both directions, and costs nothing while you pinch or pan.
final class CanvasView: NSView {
    weak var delegate: CanvasDelegate?

    /// An image on screen: the preview arrives first, the full decode joins it when needed.
    struct Shown {
        let url: URL
        /// Oriented size of the picture in pixels; a crop makes it the cropped size.
        var pixelSize: CGSize
        let frames: Int
        var isHDR = false
        var hasAlpha = false
        var preview: CGImage?
        var full: CGImage?
        /// Every pixel of a picture larger than a GPU texture; only the settled render uses it.
        var detail: CGImage?
        /// SVG: sharp renders are drawn from this instead of resampled.
        var vector: VectorImage?
    }

    struct Viewport: Equatable {
        /// Device pixels per oriented image pixel; 1 is pixel-exact.
        var scale: CGFloat = 1
        /// Point of the oriented picture at the pane centre, 0…1.
        var center = CGPoint(x: 0.5, y: 0.5)
        /// Quarter turns clockwise, on top of the file's own orientation.
        var rotation = 0
        var mirror = false
    }

    private final class StopFlag { var stop = false }

    private final class Pane {
        let container = CALayer()
        /// Carries the picture's size, placement, rotation and mirroring; draws nothing itself.
        let image = CALayer()
        /// Checkerboard behind transparent pictures.
        let backdrop = CALayer()
        /// The GPU-filtered decode.
        let base = CALayer()
        /// Cuts the settled render's rectangle out of `base`, so a transparent pixel is
        /// composited once, never twice.
        let baseMask = CAShapeLayer()
        /// The settled render, in `image`'s own (unrotated) coordinates.
        let sharp = CALayer()
        /// Clipping warnings: red where highlights are blown, blue where shadows are blocked.
        let clip = CALayer()

        var shown: Shown?
        var displayed: CGImage?
        var vp = Viewport()
        /// The whole picture at the current zoom, unrotated, in whole device pixels.
        var layerPx = CGSize.zero

        var sharpLayerPx = CGSize.zero
        var sharpRegion = CGRect.null
        var sharpAdequate = false
        var refineGen = 0
        var refineWork: DispatchWorkItem?
        /// When the oldest still-unserved refine request was made.
        var refinePendingSince: CFAbsoluteTime?
        var refineInfo = ""

        var animatedURL: URL?
        var animationStop: StopFlag?
        var edr = false
    }

    private var panes: [Pane] = []
    private(set) var paneCount = 1
    var compareLayout: CompareLayout = .sideBySide { didSet { if oldValue != compareLayout { layoutAll() } } }
    /// Wipe split, as a fraction of the width.
    var wipeFraction: CGFloat = 0.5 { didSet { layoutAll(); delegate?.canvasWipeMoved() } }
    /// Blink: which of the two pictures is on top.
    var blinkShowsSecond = false { didSet { layoutAll() } }
    var background: CanvasBackground = .black { didSet { if oldValue != background { applyBackground() } } }
    var showClipping = false { didSet { if oldValue != showClipping { layoutAll() } } }
    var syncPan = true
    /// The next click picks a point of the picture instead of panning (the white balance eyedropper).
    var picking = false { didSet { if oldValue != picking { window?.invalidateCursorRects(for: self) } } }
    private var rotationAccum: CGFloat = 0
    var syncZoom = true
    var animateTransitions = false

    private let wipeLine = CALayer()
    private let loupe = Loupe()
    private var lastPointer: CGPoint?
    /// The round grip in the middle of the wipe line.
    private let wipeHandle = CALayer()
    private let refineQueue = DispatchQueue(label: "pictty.refine", qos: .userInitiated)

    private var swipeAccum: CGFloat = 0
    private var swipeFired = false
    private var lastWheelStep: TimeInterval = 0
    private var dragFrom: CGPoint?
    private var dragPane = 0
    private var draggingWipe = false

    /// Settled-render margin around the visible region, as a fraction of it, so small pans stay sharp.
    private static let refineMargin: CGFloat = 0.25
    /// Settled renders larger than this many pixels are skipped (GPU picture stays).
    private static let refineMaxPixels: CGFloat = 48_000_000

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        wipeLine.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        wipeLine.shadowOpacity = 0.6
        wipeLine.shadowRadius = 3
        wipeLine.shadowOffset = .zero
        wipeLine.zPosition = 10
        wipeLine.actions = noActions
        layer?.addSublayer(wipeLine)
        wipeHandle.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        wipeHandle.cornerRadius = 17
        wipeHandle.backgroundColor = NSColor(white: 0.08, alpha: 0.78).cgColor
        wipeHandle.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        wipeHandle.borderWidth = 1.5
        wipeHandle.shadowOpacity = 0.5
        wipeHandle.shadowRadius = 6
        wipeHandle.shadowOffset = .zero
        wipeHandle.zPosition = 11
        wipeHandle.contentsGravity = .center
        wipeHandle.actions = noActions
        layer?.addSublayer(wipeHandle)
        layer?.addSublayer(loupe.root)
        setPaneCount(1, force: true)
        applyBackground()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var backing: CGFloat { window?.backingScaleFactor ?? 2 }
    private let noActions: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                                "transform": NSNull(), "hidden": NSNull(), "frame": NSNull(),
                                                "opacity": NSNull(), "mask": NSNull(), "backgroundColor": NSNull()]

    // MARK: - Panes

    func setPaneCount(_ count: Int, force: Bool = false) {
        let target = max(1, min(ViewerModel.maxPanes, count))
        guard force || target != paneCount else { return }
        paneCount = target
        while panes.count < target {
            let p = Pane()
            p.container.masksToBounds = true
            p.container.actions = noActions
            for l in [p.image, p.backdrop, p.base, p.sharp, p.baseMask, p.clip] { l.actions = noActions }
            p.clip.contentsGravity = .resize
            p.clip.magnificationFilter = .nearest
            p.clip.isHidden = true
            p.base.contentsGravity = .resize
            p.base.minificationFilter = .trilinear
            p.base.magnificationFilter = .linear
            p.sharp.contentsGravity = .resize
            p.sharp.minificationFilter = .trilinear
            p.sharp.magnificationFilter = .linear
            p.sharp.isHidden = true
            p.baseMask.fillRule = .evenOdd
            p.backdrop.isHidden = true
            p.image.addSublayer(p.backdrop)
            p.image.addSublayer(p.base)
            p.image.addSublayer(p.sharp)
            p.image.addSublayer(p.clip)
            p.container.addSublayer(p.image)
            layer?.insertSublayer(p.container, below: wipeLine)
            panes.append(p)
        }
        while panes.count > target {
            let p = panes.removeLast()
            stopAnimation(p)
            p.refineWork?.cancel()
            p.container.removeFromSuperlayer()
        }
        layoutAll()
    }

    /// Pane rectangles in points, top-left origin.
    func paneRects(in size: CGSize) -> [CGRect] {
        Self.paneRects(count: paneCount, layout: compareLayout, size: size)
    }

    static func paneRects(count raw: Int, layout: CompareLayout, size: CGSize) -> [CGRect] {
        let count = max(1, min(raw, ViewerModel.maxPanes))
        guard count > 1 else { return [CGRect(origin: .zero, size: size)] }
        switch layout {
        case .wipe, .blink:
            guard count == 2 else { return cells(columns: count, rows: 1, in: size) }
            return [CGRect(origin: .zero, size: size), CGRect(origin: .zero, size: size)]
        case .stacked: return cells(columns: 1, rows: count, in: size)
        case .sideBySide: return cells(columns: count, rows: 1, in: size)
        case .grid:
            let columns = count <= 2 ? count : 2
            let rows = (count + columns - 1) / columns
            let gutter: CGFloat = 2
            let h = (size.height - gutter * CGFloat(rows - 1)) / CGFloat(rows)
            var rects: [CGRect] = []
            var remaining = count
            for row in 0..<rows {
                let inRow = min(columns, remaining)
                let w = (size.width - gutter * CGFloat(inRow - 1)) / CGFloat(inRow)
                for c in 0..<inRow {
                    rects.append(CGRect(x: CGFloat(c) * (w + gutter), y: CGFloat(row) * (h + gutter), width: w, height: h))
                }
                remaining -= inRow
            }
            return rects
        }
    }

    private static func cells(columns: Int, rows: Int, in size: CGSize) -> [CGRect] {
        let gutter: CGFloat = 2
        let w = (size.width - gutter * CGFloat(columns - 1)) / CGFloat(columns)
        let h = (size.height - gutter * CGFloat(rows - 1)) / CGFloat(rows)
        return (0..<rows).flatMap { r in
            (0..<columns).map { c in CGRect(x: CGFloat(c) * (w + gutter), y: CGFloat(r) * (h + gutter), width: w, height: h) }
        }
    }

    /// A white SF Symbol as a bitmap, for layers.
    private static func symbolImage(_ name: String, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: symbol.size)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = rect.size
        guard let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        symbol.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private var isOverlay: Bool { paneCount == 2 && (compareLayout == .wipe || compareLayout == .blink) }

    func paneIndex(at point: CGPoint) -> Int {
        guard paneCount > 1 else { return 0 }
        if isOverlay { return 0 }
        return paneRects(in: bounds.size).firstIndex { $0.contains(point) } ?? 0
    }

    // MARK: - Content

    /// Hands a decode to a pane. A sharper decode of the same file swaps in silently; a
    /// different file crossfades.
    func deliver(_ d: DecodedImage, pane i: Int, animated: Bool) {
        guard panes.indices.contains(i) else { return }
        let p = panes[i]
        let isNew = p.shown?.url != d.url
        // A RAW's real develop replacing the camera's preview of the same picture.
        let developed = !isNew && !d.isFull && !d.isDetail && p.shown?.preview != nil && p.shown?.preview !== d.image
        var s = isNew ? Shown(url: d.url, pixelSize: d.pixelSize, frames: d.frameCount) : p.shown!
        if d.isDetail { s.detail = d.image } else if d.isFull { s.full = d.image } else { s.preview = d.image }
        s.isHDR = s.isHDR || d.isHDR
        s.hasAlpha = s.hasAlpha || d.hasAlpha
        if let v = d.vector { s.vector = v }
        p.shown = s
        if developed {
            dropSharp(p)
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            p.container.add(fade, forKey: "develop")
        }
        if isNew {
            stopAnimation(p)
            dropSharp(p)
            p.clip.contents = nil
            if animated, animateTransitions, p.displayed != nil {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.16
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.container.add(fade, forKey: "swap")
            }
        }
        layoutPane(i, animated: false)
    }

    /// The Light panel's result for the picture already in pane `i`, swapped in with no fade.
    /// A screen-sized edit drops the sharper decodes, which no longer match it; the canvas asks
    /// for them again (`canvasNeedsFull`) if the zoom needs them, and the edited full one comes
    /// back here with `full`.
    func showEdited(_ image: CGImage, full: Bool, pane i: Int, pixelSize: CGSize? = nil, hasAlpha: Bool? = nil) {
        guard panes.indices.contains(i), var s = panes[i].shown else { return }
        let p = panes[i]
        if let pixelSize { s.pixelSize = pixelSize }
        if let hasAlpha { s.hasAlpha = hasAlpha }
        if full {
            s.full = image
        } else {
            s.preview = image
            s.full = nil
        }
        s.detail = nil
        p.shown = s
        dropSharp(p)
        p.displayed = nil
        layoutPane(i, animated: false)
    }

    func clear(pane i: Int) {
        guard panes.indices.contains(i) else { return }
        let p = panes[i]
        stopAnimation(p)
        dropSharp(p)
        p.shown = nil
        p.displayed = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.base.contents = nil
        CATransaction.commit()
        layoutPane(i, animated: false)
    }

    /// True while some pane showing `url` is magnified past what its preview holds.
    func needsFull(_ url: URL) -> Bool {
        panes.contains { p in
            guard let s = p.shown, s.url == url, s.full == nil, let pv = s.preview else { return false }
            return CGFloat(pv.width) < s.pixelSize.width * p.vp.scale * 0.98
        }
    }

    /// True while some pane showing `url` is zoomed past what its GPU-sized decode holds.
    func needsDetail(_ url: URL) -> Bool {
        panes.contains { p in
            guard let s = p.shown, s.url == url, s.detail == nil, let f = s.full else { return false }
            return CGFloat(f.width) < s.pixelSize.width * p.vp.scale * 0.98 && ImageDecoder.needsDetail(s.pixelSize)
        }
    }

    /// The clipping mask measured for the picture showing in pane `i` (nil clears it).
    func setClipMask(_ mask: CGImage?, pane i: Int) {
        guard panes.indices.contains(i) else { return }
        let p = panes[i]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.clip.contents = mask
        p.clip.isHidden = !showClipping || mask == nil
        CATransaction.commit()
    }

    func shown(pane i: Int) -> Shown? { panes.indices.contains(i) ? panes[i].shown : nil }

    /// Where the picture in pane `i` is in this view, turned and mirrored as it shows.
    func pictureFrame(pane i: Int) -> CGRect? {
        guard panes.indices.contains(i), panes[i].shown != nil, !panes[i].image.isHidden, let root = layer else { return nil }
        return root.convert(panes[i].image.frame, from: panes[i].container)
    }
    func refineInfo(pane i: Int) -> String { panes.indices.contains(i) ? panes[i].refineInfo : "" }
    func displayedImage(pane i: Int) -> CGImage? { panes.indices.contains(i) ? panes[i].displayed : nil }

    // MARK: - Camera

    func viewport(pane i: Int) -> Viewport { panes.indices.contains(i) ? panes[i].vp : Viewport() }

    func setViewport(_ vp: Viewport, pane i: Int, animated: Bool) {
        guard panes.indices.contains(i) else { return }
        panes[i].vp = vp
        layoutPane(i, animated: animated)
    }

    /// Oriented size of the picture in a pane, original pixels.
    func orientedSize(pane i: Int) -> CGSize? {
        guard panes.indices.contains(i), let s = panes[i].shown else { return nil }
        return panes[i].vp.rotation % 2 == 0 ? s.pixelSize : CGSize(width: s.pixelSize.height, height: s.pixelSize.width)
    }

    /// Scale at which the pane shows its whole picture (may enlarge), at its current rotation
    /// or at `rotation` quarter turns.
    func fitScale(pane i: Int, rotation: Int? = nil) -> CGFloat? {
        guard var o = orientedSize(pane: i) else { return nil }
        if let rotation, rotation % 2 != panes[i].vp.rotation % 2 { o = CGSize(width: o.height, height: o.width) }
        let rects = paneRects(in: bounds.size)
        guard rects.indices.contains(i) else { return nil }
        return ZoomMath.fit(o, in: CGSize(width: rects[i].width * backing, height: rects[i].height * backing))
    }

    func isPannable(pane i: Int) -> Bool {
        guard let o = orientedSize(pane: i) else { return false }
        let rects = paneRects(in: bounds.size)
        guard rects.indices.contains(i) else { return false }
        let s = panes[i].vp.scale / backing
        return ZoomMath.isPannable(display: CGSize(width: o.width * s, height: o.height * s), view: rects[i].size)
    }

    /// Copies pane `i`'s camera onto the others. Zoom is matched by width, so two shots of the
    /// same scene at different resolutions stay the same size on screen; pan is normalised.
    func propagate(from i: Int, animated: Bool = false, force: Bool = false) {
        guard paneCount > 1, panes.indices.contains(i), let oi = orientedSize(pane: i) else { return }
        let zoom = syncZoom || force || isOverlay, pan = syncPan || force || isOverlay
        guard zoom || pan else { return }
        let src = panes[i].vp
        for j in panes.indices where j != i {
            var vp = panes[j].vp
            if zoom, let oj = orientedSize(pane: j), oj.width > 0 { vp.scale = src.scale * oi.width / oj.width }
            if pan { vp.center = src.center }
            panes[j].vp = vp
            layoutPane(j, animated: animated)
        }
    }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        layoutAll()
        delegate?.canvasDidResize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutAll()
    }

    func layoutAll(animated: Bool = false) {
        for i in panes.indices { layoutPane(i, animated: animated) }
        layoutWipeLine()
    }

    private func snap(_ v: CGFloat) -> CGFloat { (v * backing).rounded() / backing }

    private func snapRect(_ r: CGRect) -> CGRect {
        let x0 = snap(r.minX), y0 = snap(r.minY)
        return CGRect(x: x0, y: y0, width: snap(r.maxX) - x0, height: snap(r.maxY) - y0)
    }

    private func layoutWipeLine() {
        let show = isOverlay && compareLayout == .wipe && panes.count == 2 && panes[1].shown != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wipeLine.isHidden = !show
        wipeLine.frame = CGRect(x: snap(bounds.width * wipeFraction) - 0.5, y: 0, width: 1, height: bounds.height)
        wipeHandle.isHidden = !show
        wipeHandle.position = CGPoint(x: snap(bounds.width * wipeFraction), y: bounds.midY)
        if show, wipeHandle.contents == nil || wipeHandle.contentsScale != backing {
            wipeHandle.contentsScale = backing
            wipeHandle.contents = Self.symbolImage("arrow.left.and.right", pointSize: 13, scale: backing)
        }
        CATransaction.commit()
    }

    /// Turns the camera into layer geometry. The image layer's bounds are the unrotated picture
    /// at the current zoom, a whole number of device pixels; rotation and mirroring ride in its
    /// transform; its top-left lands on a device pixel. Core Animation interpolates all of it
    /// on the render server, so animated zooms cost nothing here.
    private func layoutPane(_ i: Int, animated: Bool) {
        guard panes.indices.contains(i) else { return }
        let p = panes[i]
        let rects = paneRects(in: bounds.size)
        guard rects.indices.contains(i) else { return }
        let rect = snapRect(rects[i])
        let b = backing

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.container.frame = rect
        if isOverlay, compareLayout == .wipe {
            // Each side shows only its own half, so neither shows through the other's
            // transparent pixels.
            let mask = (p.container.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.actions = noActions
            let x = snap(rect.width * wipeFraction)
            mask.path = CGPath(rect: i == 0 ? CGRect(x: 0, y: 0, width: x, height: rect.height)
                                            : CGRect(x: x, y: 0, width: rect.width - x, height: rect.height), transform: nil)
            p.container.mask = mask
            p.container.isHidden = false
        } else {
            p.container.mask = nil
            p.container.isHidden = isOverlay && compareLayout == .blink && (i == 1) != blinkShowsSecond
        }
        CATransaction.commit()

        guard let s = p.shown, rect.width > 0, rect.height > 0 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            p.image.isHidden = true
            CATransaction.commit()
            return
        }

        let quarter = ((p.vp.rotation % 4) + 4) % 4
        p.vp.rotation = quarter
        let oriented = quarter % 2 == 0 ? s.pixelSize : CGSize(width: s.pixelSize.height, height: s.pixelSize.width)
        let disp = CGSize(width: oriented.width * p.vp.scale / b, height: oriented.height * p.vp.scale / b)
        p.vp.center = ZoomMath.clampCenter(p.vp.center, display: disp, view: rect.size)

        let layerPx = CGSize(width: max(1, (s.pixelSize.width * p.vp.scale).rounded()),
                             height: max(1, (s.pixelSize.height * p.vp.scale).rounded()))
        p.layerPx = layerPx
        let orientedPx = quarter % 2 == 0 ? layerPx : CGSize(width: layerPx.height, height: layerPx.width)
        let orientedPt = CGSize(width: orientedPx.width / b, height: orientedPx.height / b)
        // When the picture is smaller than the pane it is centred; either way its top-left
        // sits on a device pixel, and because its size is a whole number of device pixels
        // so does every other corner, whatever the rotation.
        let topLeft = CGPoint(x: snap(rect.width / 2 - p.vp.center.x * orientedPt.width),
                              y: snap(rect.height / 2 - p.vp.center.y * orientedPt.height))

        var transform = CATransform3DIdentity
        if quarter != 0 { transform = CATransform3DMakeRotation(CGFloat(quarter) * .pi / 2, 0, 0, 1) }
        if p.vp.mirror { transform = CATransform3DConcat(transform, CATransform3DMakeScale(-1, 1, 1)) }

        // The rule: whenever the screen-sized preview has enough pixels it is shown
        // instead of the full decode; ImageIO's reduction is better than any mip level.
        let needed = s.pixelSize.width * p.vp.scale * 0.98
        var img = s.full ?? s.preview
        if let pv = s.preview, CGFloat(pv.width) >= needed || s.full == nil { img = pv }
        if s.full == nil, let pv = s.preview, CGFloat(pv.width) < needed { delegate?.canvasNeedsFull(s.url) }
        if s.detail == nil, let f = s.full, CGFloat(f.width) < needed, ImageDecoder.needsDetail(s.pixelSize) {
            delegate?.canvasNeedsDetail(s.url)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.26)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1))
        }
        let bounds = CGRect(x: 0, y: 0, width: layerPx.width / b, height: layerPx.height / b)
        p.image.isHidden = false
        p.image.bounds = bounds
        p.image.position = CGPoint(x: topLeft.x + orientedPt.width / 2, y: topLeft.y + orientedPt.height / 2)
        p.image.transform = transform
        p.base.frame = bounds
        p.backdrop.frame = bounds
        p.clip.frame = bounds
        CATransaction.setDisableActions(true)
        p.backdrop.isHidden = !(s.hasAlpha && background == .checkerboard)
        p.clip.isHidden = !showClipping || p.clip.contents == nil
        if let img, img !== p.displayed, p.animatedURL == nil {
            p.displayed = img
            p.base.contents = img
        }
        setEDR(p, s.isHDR)
        CATransaction.setDisableActions(!animated)
        layoutSharp(p)
        CATransaction.commit()

        if s.frames > 1 { startAnimation(p, url: s.url) } else { stopAnimation(p) }
        scheduleRefine(i, delay: animated ? 0.32 : 0.12)
        // The second picture arriving is what makes the wipe line appear.
        if i == 1 { layoutWipeLine() }
    }

    private func setEDR(_ p: Pane, _ on: Bool) {
        guard on != p.edr else { return }
        p.edr = on
        for l in [p.base, p.sharp] {
            if #available(macOS 26, *) { l.preferredDynamicRange = on ? .high : .standard }
            else { l.wantsExtendedDynamicRangeContent = on }
        }
    }

    // MARK: - Settled render

    /// Keeps the settled render glued to the picture. While zooming out it stays (it has more
    /// detail than needed and is filtered like the picture); zooming in past its resolution
    /// hides it until the next one is ready.
    private func layoutSharp(_ p: Pane) {
        let k = p.sharpLayerPx.width > 0 ? p.layerPx.width / p.sharpLayerPx.width : 0
        // While zooming in, the old render is magnified; it stays as long as it still has more
        // pixels than the GPU picture under it (always, for a vector's screen-sized raster).
        let baseDensity = CGFloat(p.displayed?.width ?? 0) / max(p.layerPx.width, 1)
        let usable = p.sharp.contents != nil && !p.sharpRegion.isNull && k > 0 && p.animatedURL == nil
            && (k <= 1.02 || 1 / k > baseDensity * 1.02)
        p.sharp.isHidden = !usable
        guard usable else {
            p.base.mask = nil
            return
        }
        let ky = p.layerPx.height / p.sharpLayerPx.height, b = backing
        let r = p.sharpRegion
        let frame = CGRect(x: r.minX * k / b, y: r.minY * ky / b, width: r.width * k / b, height: r.height * ky / b)
        p.sharp.frame = frame
        if p.shown?.hasAlpha == true {
            // Picture minus the sharp rectangle (even-odd), on the same pixel edges.
            let path = CGMutablePath()
            path.addRect(p.base.bounds.insetBy(dx: -1, dy: -1))
            path.addRect(frame)
            p.baseMask.frame = p.base.bounds
            p.baseMask.path = path
            p.base.mask = p.baseMask
        } else {
            p.base.mask = nil
        }
    }

    private func dropSharp(_ p: Pane) {
        p.refineGen += 1
        p.refineWork?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.sharp.contents = nil
        p.sharp.isHidden = true
        p.base.mask = nil
        CATransaction.commit()
        p.sharpRegion = .null
        p.refineInfo = ""
    }

    /// Debounced: a render starts once the view has rested. A vector is cheap to draw, so it
    /// rests less and is also redrawn during a long pinch, at most every 150 ms.
    private func scheduleRefine(_ i: Int, delay: TimeInterval) {
        let p = panes[i]
        p.refineWork?.cancel()
        let now = CFAbsoluteTimeGetCurrent()
        let since = p.refinePendingSince ?? now
        p.refinePendingSince = since
        var wait = delay
        if p.shown?.vector != nil {
            wait = min(delay, 0.05)
            if now - since > 0.15 { wait = 0 }
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panes.indices.contains(i) else { return }
                self.panes[i].refinePendingSince = nil
                self.refine(i)
            }
        }
        p.refineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Diagnostics only: `PICTTY_GPU_ONLY=1` shows the GPU picture alone, for A/B comparisons.
    private static let gpuOnly = ProcessInfo.processInfo.environment["PICTTY_GPU_ONLY"] == "1"
    private static let verbose = ProcessInfo.processInfo.environment["PICTTY_VERBOSE"] == "1"

    private func refine(_ i: Int) {
        guard panes.indices.contains(i), window != nil, !Self.gpuOnly else { return }
        let p = panes[i]
        guard let s = p.shown, s.frames <= 1, p.animatedURL == nil, !p.image.isHidden else { return }

        // Past 300 % a photo shows the bilinear picture, as it always did. A vector has no
        // pixels to magnify: it is drawn sharp at any zoom. A picture larger than a GPU texture
        // is drawn from every pixel at any zoom once they are decoded, bilinear past 300 %.
        let baseDensity = CGFloat(p.displayed?.width ?? 0) / max(p.layerPx.width, 1)
        let fromDetail = s.detail != nil && baseDensity < 0.98
        guard p.vp.scale <= 3 || s.vector != nil || fromDetail else {
            if p.sharp.contents != nil { dropSharp(p) }
            p.refineInfo = L("GPU bilinear")
            delegate?.canvasRefined(pane: i)
            return
        }

        let b = backing
        let visiblePt = p.image.convert(p.container.bounds, from: p.container)
        let visible = CGRect(x: visiblePt.minX * b, y: visiblePt.minY * b, width: visiblePt.width * b, height: visiblePt.height * b)
        let layerPx = p.layerPx

        if let vector = s.vector {
            refineVector(i, vector: vector, visible: visible)
            return
        }

        // The best source: the smallest decode with at least one pixel per output pixel,
        // else the largest there is.
        let candidates = [s.preview, s.full, s.detail].compactMap { $0 }.sorted { $0.width < $1.width }
        guard let largest = candidates.last else { return }
        let source = candidates.first { CGFloat($0.width) >= layerPx.width * 0.98 } ?? largest
        let adequate = CGFloat(source.width) >= layerPx.width * 0.98 || source === s.detail
            || (source === s.full && !ImageDecoder.needsDetail(s.pixelSize))
            || (s.full == nil && CGFloat(source.width) >= s.pixelSize.width - 0.5)

        // Already sharp and still covering the view?
        if !p.sharp.isHidden, p.sharpLayerPx == layerPx, p.sharpAdequate || !adequate,
           RefineMath.covers(p.sharpRegion, visible: visible, layerPixels: layerPx) { return }

        var margin = Self.refineMargin
        var region = RefineMath.region(visible: visible, layerPixels: layerPx, margin: margin)
        if let r = region, r.width * r.height > Self.refineMaxPixels {
            margin = 0
            region = RefineMath.region(visible: visible, layerPixels: layerPx, margin: margin)
        }
        guard let region, region.width * region.height <= Self.refineMaxPixels else { return }

        // Exactly one source pixel per output pixel, and it is what the GPU shows: already 1:1.
        if source === p.displayed, source.width == Int(layerPx.width), source.height == Int(layerPx.height) {
            if p.sharp.contents != nil { dropSharp(p) }
            p.refineInfo = L("1:1, no resampling")
            delegate?.canvasRefined(pane: i)
            return
        }

        let magnified = p.vp.scale > 3
        let kernelName = magnified ? "Bilinear" : "Lanczos"
        let detailNote = source === s.detail ? " · " + L("every pixel") : ""
        let srcRect = RefineMath.sourceRect(for: region, layerPixels: layerPx,
                                            sourcePixels: CGSize(width: source.width, height: source.height))
        p.refineGen += 1
        let gen = p.refineGen
        let url = s.url
        refineQueue.async { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()
            let out = Resampler.render(source, from: srcRect, width: Int(region.width), height: Int(region.height),
                                       kernel: magnified ? .linear : .lanczos)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let out else { return }
                    let mp = region.width * region.height / 1_000_000
                    self.install(out, pane: i, gen: gen, url: url, layerPx: layerPx, region: region, adequate: adequate,
                                 info: String(format: "%@ %d×%d · %.1f MP · %.0f ms%@", kernelName,
                                              Int(region.width), Int(region.height), mp, ms, detailNote))
                }
            }
        }
    }

    /// SVG: the visible region drawn straight from the vector, at exactly one pixel per device pixel.
    private func refineVector(_ i: Int, vector: VectorImage, visible: CGRect) {
        let p = panes[i]
        let layerPx = p.layerPx
        if !p.sharp.isHidden, p.sharpLayerPx == layerPx,
           RefineMath.covers(p.sharpRegion, visible: visible, layerPixels: layerPx) { return }
        var region = RefineMath.region(visible: visible, layerPixels: layerPx, margin: Self.refineMargin)
        if let r = region, r.width * r.height > Self.refineMaxPixels {
            region = RefineMath.region(visible: visible, layerPixels: layerPx, margin: 0)
        }
        guard let region, region.width * region.height <= Self.refineMaxPixels, let url = p.shown?.url else { return }
        p.refineGen += 1
        let gen = p.refineGen
        refineQueue.async { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()
            let out = vector.render(region, of: layerPx, width: Int(region.width), height: Int(region.height))
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let out else { return }
                    self.install(out, pane: i, gen: gen, url: url, layerPx: layerPx, region: region, adequate: true,
                                 info: String(format: "Vector %d×%d · %.0f ms", Int(region.width), Int(region.height), ms))
                }
            }
        }
    }

    /// Puts a finished settled render on screen, if nothing has moved on since it was asked for.
    private func install(_ out: CGImage, pane i: Int, gen: Int, url: URL, layerPx: CGSize, region: CGRect,
                         adequate: Bool, info: String) {
        guard panes.indices.contains(i) else { return }
        let p = panes[i]
        guard p.refineGen == gen, p.shown?.url == url, p.layerPx == layerPx else { return }
        let wasHidden = p.sharp.isHidden
        p.sharpLayerPx = layerPx
        p.sharpRegion = region
        p.sharpAdequate = adequate
        p.refineInfo = info
        if Self.verbose { FileHandle.standardError.write(Data("refine pane \(i): \(info)\n".utf8)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.sharp.contents = out
        layoutSharp(p)
        CATransaction.commit()
        if wasHidden, !p.sharp.isHidden {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.12
            p.sharp.add(fade, forKey: "focus")
        }
        delegate?.canvasRefined(pane: i)
    }

    // MARK: - Background

    private func applyBackground() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = background == .glass ? NSColor.clear.cgColor : NSColor.black.cgColor
        let checker = Self.checkerColor
        for p in panes {
            p.backdrop.backgroundColor = checker
            p.backdrop.isHidden = !(p.shown?.hasAlpha == true && background == .checkerboard)
        }
        CATransaction.commit()
    }

    /// 8-point dark checks, the convention for "transparent here".
    private static let checkerColor: CGColor = {
        let tile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor(white: 0.16, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            NSColor(white: 0.24, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }()

    // MARK: - Animated GIF / PNG / WebP / HEICS

    private func startAnimation(_ p: Pane, url: URL) {
        guard p.animatedURL != url else { return }
        stopAnimation(p)
        dropSharp(p)
        p.animatedURL = url
        let flag = StopFlag()
        p.animationStop = flag
        CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak p] _, frame, stop in
            guard !flag.stop, let p else { stop.pointee = true; return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            p.base.contents = frame
            CATransaction.commit()
        }
    }

    private func stopAnimation(_ p: Pane) {
        guard p.animatedURL != nil else { return }
        p.animationStop?.stop = true
        p.animationStop = nil
        p.animatedURL = nil
        p.displayed = nil
    }

    // MARK: - Input

    private func pan(pane i: Int, dx: CGFloat, dy: CGFloat) {
        guard let o = orientedSize(pane: i) else { return }
        let p = panes[i]
        let disp = CGSize(width: o.width * p.vp.scale / backing, height: o.height * p.vp.scale / backing)
        guard disp.width > 0, disp.height > 0 else { return }
        p.vp.center = CGPoint(x: p.vp.center.x - dx / disp.width, y: p.vp.center.y - dy / disp.height)
        layoutPane(i, animated: false)
        propagate(from: i)
        delegate?.canvasViewportChanged(pane: i)
    }

    /// Zooms pane `i` so the picture point under `point` stays under it.
    func zoom(pane i: Int, to newScale: CGFloat, about point: CGPoint, animated: Bool = false) {
        guard let o = orientedSize(pane: i) else { return }
        let rects = paneRects(in: bounds.size)
        guard rects.indices.contains(i) else { return }
        let p = panes[i]
        let rect = rects[i]
        let scale = min(max(newScale, ZoomMath.steps[0]), ZoomMath.steps[ZoomMath.steps.count - 1])
        let disp = CGSize(width: o.width * p.vp.scale / backing, height: o.height * p.vp.scale / backing)
        let next = CGSize(width: o.width * scale / backing, height: o.height * scale / backing)
        let off = CGPoint(x: point.x - rect.midX, y: point.y - rect.midY)
        let u = CGPoint(x: p.vp.center.x + off.x / disp.width, y: p.vp.center.y + off.y / disp.height)
        p.vp.scale = scale
        p.vp.center = CGPoint(x: u.x - off.x / next.width, y: u.y - off.y / next.height)
        layoutPane(i, animated: animated)
        propagate(from: i, animated: animated)
    }

    /// Scrolling pans when the picture overflows its pane, otherwise it flips pictures. It never zooms.
    override func scrollWheel(with e: NSEvent) {
        let i = paneIndex(at: convert(e.locationInWindow, from: nil))
        if isPannable(pane: i) {
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 16
            pan(pane: i, dx: e.scrollingDeltaX * k, dy: e.scrollingDeltaY * k)
            return
        }
        guard e.momentumPhase.isEmpty else { return }
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        if e.hasPreciseScrollingDeltas, !e.phase.isEmpty {
            if e.phase.contains(.began) || e.phase.contains(.mayBegin) { swipeAccum = 0; swipeFired = false }
            swipeAccum += d
            if !swipeFired, abs(swipeAccum) > 28 {
                swipeFired = true
                delegate?.canvasRequestsStep(swipeAccum > 0 ? -1 : 1, pane: i)
            }
        } else if d != 0, e.timestamp - lastWheelStep > 0.07 {
            lastWheelStep = e.timestamp
            delegate?.canvasRequestsStep(d > 0 ? -1 : 1, pane: i)
        }
    }

    /// Trackpad pinch zooms around the fingers.
    override func magnify(with e: NSEvent) {
        let point = convert(e.locationInWindow, from: nil)
        let i = paneIndex(at: point)
        guard panes.indices.contains(i) else { return }
        zoom(pane: i, to: panes[i].vp.scale * max(0.1, 1 + e.magnification), about: point)
        delegate?.canvasViewportChanged(pane: i)
    }

    /// Two fingers turning on the trackpad: past 45° the picture turns a quarter, and again past
    /// the next 90°, the way the gesture turns photos elsewhere on the Mac.
    override func rotate(with e: NSEvent) {
        if e.phase.contains(.began) { rotationAccum = 0 }
        rotationAccum += CGFloat(e.rotation)
        // The event counts counterclockwise as positive.
        while abs(rotationAccum) >= 45 {
            let clockwise = rotationAccum < 0
            delegate?.canvasRotateGesture(clockwise ? 1 : -1)
            rotationAccum += clockwise ? 90 : -90
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) { rotationAccum = 0 }
    }

    override func smartMagnify(with e: NSEvent) {
        let point = convert(e.locationInWindow, from: nil)
        delegate?.canvasSmartZoom(pane: paneIndex(at: point), at: point)
    }

    override func mouseDown(with e: NSEvent) {
        if picking {
            let point = convert(e.locationInWindow, from: nil)
            guard panes.indices.contains(0), let size = Optional(panes[0].image.bounds.size), size.width > 0 else { return }
            let local = panes[0].image.convert(point, from: layer)
            guard local.x >= 0, local.y >= 0, local.x < size.width, local.y < size.height else { return }
            delegate?.canvasPicked(CGPoint(x: local.x / size.width, y: local.y / size.height))
            return
        }
        if e.modifierFlags.contains(.option), let picked = loupe.sample {
            delegate?.canvasPickedColour(picked.hex)
            return
        }
        if e.clickCount == 2 { delegate?.canvasToggleFullScreen(); return }
        let point = convert(e.locationInWindow, from: nil)
        // Wipe: grab the line or its grip, or click anywhere on a picture that is not zoomed
        // in for panning, and the split follows the pointer.
        if isOverlay, compareLayout == .wipe {
            let x = bounds.width * wipeFraction
            let onGrip = hypot(point.x - x, point.y - bounds.midY) < 22
            if abs(point.x - x) < 8 || onGrip || !isPannable(pane: 0) {
                draggingWipe = true
                wipeFraction = min(max(point.x / max(bounds.width, 1), 0.02), 0.98)
                NSCursor.resizeLeftRight.push()
                return
            }
        }
        let i = paneIndex(at: point)
        let inTitlebar = point.y < 28 && window?.styleMask.contains(.fullScreen) == false
        if !isPannable(pane: i) || inTitlebar { window?.performDrag(with: e); return }
        dragFrom = point
        dragPane = i
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with e: NSEvent) {
        let point = convert(e.locationInWindow, from: nil)
        if draggingWipe {
            wipeFraction = min(max(point.x / max(bounds.width, 1), 0.02), 0.98)
            return
        }
        guard let from = dragFrom else { return }
        pan(pane: dragPane, dx: point.x - from.x, dy: point.y - from.y)
        dragFrom = point
    }

    override func mouseUp(with e: NSEvent) {
        if draggingWipe { draggingWipe = false; NSCursor.pop(); return }
        guard dragFrom != nil else { return }
        dragFrom = nil
        NSCursor.pop()
    }

    override func flagsChanged(with e: NSEvent) {
        super.flagsChanged(with: e)
        updateLoupe(option: e.modifierFlags.contains(.option))
    }

    override func mouseExited(with e: NSEvent) {
        lastPointer = nil
        loupe.hide()
    }

    /// Shows the loupe under the pointer while ⌥ is held over a picture.
    func updateLoupe(option: Bool = NSEvent.modifierFlags.contains(.option)) {
        guard option, let point = lastPointer, bounds.contains(point) else { loupe.hide(); return }
        let i = paneIndex(at: point)
        guard panes.indices.contains(i), let s = panes[i].shown,
              let source = s.detail ?? s.full ?? s.preview ?? panes[i].displayed else { loupe.hide(); return }
        let p = panes[i]
        // Pointer → the picture's own (unrotated, unmirrored) coordinates, via the layer transform.
        let local = p.image.convert(point, from: layer)
        let size = p.image.bounds.size
        guard size.width > 0, size.height > 0,
              local.x >= 0, local.y >= 0, local.x < size.width, local.y < size.height else { loupe.hide(); return }
        let u = local.x / size.width, v = local.y / size.height
        let x = Int(u * CGFloat(source.width)), y = Int(v * CGFloat(source.height))
        let original = CGPoint(x: u * s.pixelSize.width, y: v * s.pixelSize.height)
        loupe.show(source, x: x, y: y, original: original, at: point, in: bounds, scale: backing)
    }

    /// For screenshots: the loupe at a point, as if ⌥ were held there.
    func showLoupe(at point: CGPoint) {
        lastPointer = point
        updateLoupe(option: true)
    }

    func hideLoupe() { updateLoupe(option: false) }

    override func mouseMoved(with e: NSEvent) {
        lastPointer = convert(e.locationInWindow, from: nil)
        if e.modifierFlags.contains(.option) { updateLoupe(option: true) }
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        delegate?.canvasContextMenu(pane: paneIndex(at: convert(event.locationInWindow, from: nil)))
    }

    override func resetCursorRects() {
        if picking { return addCursorRect(bounds, cursor: .crosshair) }
        let rects = paneRects(in: bounds.size)
        if isOverlay, compareLayout == .wipe {
            addCursorRect(CGRect(x: bounds.width * wipeFraction - 6, y: 0, width: 12, height: bounds.height), cursor: .resizeLeftRight)
        }
        for (i, r) in rects.enumerated() where isPannable(pane: i) {
            addCursorRect(r, cursor: .openHand)
            if isOverlay { break }
        }
    }
}
