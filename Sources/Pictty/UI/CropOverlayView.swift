// The crop frame, drawn over the picture while cropping. Corners and edges resize, the inside
// moves, and with rounded corners on, a knob inside each corner sets its radius (all four at once
// when they are linked). Everything is worked out on screen, in the picture's turned and mirrored
// 0…1 coordinates, and handed back in the file's own.

import AppKit
import PicttyCore

final class CropOverlayView: NSView {
    /// The picture on screen, in this view's coordinates.
    var pictureFrame: CGRect = .zero { didSet { if oldValue != pictureFrame { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    var orient = Orient() { didSet { needsDisplay = true } }
    /// The picture's own size as it shows (turned), in pixels: what ratios and the size readout mean.
    var displayPixels: CGSize = .zero
    /// The crop being made, in the file's own coordinates.
    var box = CropBox() { didSet { if oldValue != box { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    /// Width over height on screen, or nil for free.
    var ratio: Double?
    var rounded = false { didSet { needsDisplay = true } }
    var linkedCorners = true

    var onChange: ((CropBox) -> Void)?
    var onCommit: (() -> Void)?

    private enum Grip: Equatable {
        case corner(Int)   // on screen: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left
        case edge(Int)     // 0 top, 1 right, 2 bottom, 3 left
        case radius(Int)
        case move
    }

    private var grip: Grip?
    private var dragFrom: CGPoint = .zero
    private var startRect: CGRect = .zero
    private var startRadii: [Double] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// The crop on screen, 0…1 of the picture as it shows.
    private var unitRect: CGRect { orient.display(box.rect) }

    private var viewRect: CGRect {
        let u = unitRect, f = pictureFrame
        return CGRect(x: f.minX + u.minX * f.width, y: f.minY + u.minY * f.height, width: u.width * f.width, height: u.height * f.height)
    }

    private var displayRadii: [Double] { orient.displayRadii(box.radii) }

    private func radiusPoints(_ i: Int) -> CGFloat { CGFloat(displayRadii[i]) * min(viewRect.width, viewRect.height) }

    private func corner(_ i: Int, of r: CGRect) -> CGPoint {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)][i]
    }

    /// Inward diagonal of on-screen corner `i`.
    private func inward(_ i: Int) -> CGPoint {
        [CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1), CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1)][i]
    }

    private func radiusKnob(_ i: Int) -> CGPoint {
        let r = viewRect, c = corner(i, of: r), d = inward(i)
        // At the middle of the rounded arc; a little way in when the corner is square, to be grabbable.
        let along = max(radiusPoints(i) * (1 - 1 / 2.0.squareRoot()), 10)
        return CGPoint(x: c.x + d.x * along, y: c.y + d.y * along)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard pictureFrame.width > 1 else { return }
        let r = viewRect
        let shape = CropBox.path(r, radii: (0..<4).map { Double(radiusPoints($0)) })

        // Everything outside the crop, dimmed.
        let dim = CGMutablePath()
        dim.addRect(bounds)
        dim.addPath(shape)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.addPath(dim)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.58).cgColor)
        ctx.fillPath(using: .evenOdd)

        // Thirds while moving anything, faintly otherwise.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(grip == nil ? 0.16 : 0.42).cgColor)
        ctx.setLineWidth(0.5)
        for k in 1...2 {
            let x = r.minX + r.width * CGFloat(k) / 3, y = r.minY + r.height * CGFloat(k) / 3
            ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // The frame, with a soft shadow so it reads on white skies too.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        // Corner brackets and edge bars, Photos-style.
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3.5)
        ctx.setLineCap(.round)
        let arm = min(20, r.width / 3, r.height / 3)
        if !rounded {
            for i in 0..<4 {
                let c = corner(i, of: r), d = inward(i)
                ctx.move(to: CGPoint(x: c.x + d.x * arm, y: c.y))
                ctx.addLine(to: c)
                ctx.addLine(to: CGPoint(x: c.x, y: c.y + d.y * arm))
            }
        }
        let bar = min(22, r.width / 4, r.height / 4)
        ctx.move(to: CGPoint(x: r.midX - bar / 2, y: r.minY)); ctx.addLine(to: CGPoint(x: r.midX + bar / 2, y: r.minY))
        ctx.move(to: CGPoint(x: r.midX - bar / 2, y: r.maxY)); ctx.addLine(to: CGPoint(x: r.midX + bar / 2, y: r.maxY))
        ctx.move(to: CGPoint(x: r.minX, y: r.midY - bar / 2)); ctx.addLine(to: CGPoint(x: r.minX, y: r.midY + bar / 2))
        ctx.move(to: CGPoint(x: r.maxX, y: r.midY - bar / 2)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.midY + bar / 2))
        ctx.strokePath()
        ctx.restoreGState()

        if rounded {
            // Square handles at the true corners, a round knob for each radius.
            for i in 0..<4 {
                let c = corner(i, of: r)
                let handle = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
                ctx.fill(handle)
                let k = radiusKnob(i)
                let knob = CGRect(x: k.x - 6.5, y: k.y - 6.5, width: 13, height: 13)
                ctx.setFillColor(NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1).cgColor)
                ctx.setShadow(offset: .zero, blur: grip == .radius(i) ? 8 : 4,
                              color: NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 0.9).cgColor)
                ctx.fillEllipse(in: knob)
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: knob.insetBy(dx: 1, dy: 1))
            }
        }

        drawSizeBadge(in: ctx, below: r)
    }

    /// The crop's size in pixels, under the frame (above it when there is no room below).
    private func drawSizeBadge(in ctx: CGContext, below r: CGRect) {
        let u = unitRect
        let w = Int((u.width * displayPixels.width).rounded()), h = Int((u.height * displayPixels.height).rounded())
        let text = NSAttributedString(string: "\(w) × \(h)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        var badge = CGRect(x: r.midX - size.width / 2 - 8, y: r.maxY + 8, width: size.width + 16, height: size.height + 6)
        if badge.maxY > bounds.maxY - 90 { badge.origin.y = r.minY - badge.height - 8 }
        if badge.minY < 4 { badge.origin.y = r.maxY - badge.height - 10 }
        let path = CGPath(roundedRect: badge, cornerWidth: badge.height / 2, cornerHeight: badge.height / 2, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        ctx.fillPath()
        text.draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 3))
    }

    // MARK: Hit testing and cursors

    private func grip(at p: CGPoint) -> Grip? {
        let r = viewRect
        if rounded {
            for i in 0..<4 where hypot(p.x - radiusKnob(i).x, p.y - radiusKnob(i).y) < 10 { return .radius(i) }
        }
        for i in 0..<4 where hypot(p.x - corner(i, of: r).x, p.y - corner(i, of: r).y) < 16 { return .corner(i) }
        if abs(p.y - r.minY) < 10, p.x > r.minX, p.x < r.maxX { return .edge(0) }
        if abs(p.x - r.maxX) < 10, p.y > r.minY, p.y < r.maxY { return .edge(1) }
        if abs(p.y - r.maxY) < 10, p.x > r.minX, p.x < r.maxX { return .edge(2) }
        if abs(p.x - r.minX) < 10, p.y > r.minY, p.y < r.maxY { return .edge(3) }
        if r.contains(p) { return .move }
        return nil
    }

    override func resetCursorRects() {
        guard pictureFrame.width > 1 else { return }
        let r = viewRect
        addCursorRect(r.insetBy(dx: 10, dy: 10), cursor: .openHand)
        let edges: [(CGRect, NSCursor.FrameResizePosition)] = [
            (CGRect(x: r.minX + 12, y: r.minY - 8, width: r.width - 24, height: 16), .top),
            (CGRect(x: r.maxX - 8, y: r.minY + 12, width: 16, height: r.height - 24), .right),
            (CGRect(x: r.minX + 12, y: r.maxY - 8, width: r.width - 24, height: 16), .bottom),
            (CGRect(x: r.minX - 8, y: r.minY + 12, width: 16, height: r.height - 24), .left),
        ]
        for (rect, position) in edges { addCursorRect(rect, cursor: NSCursor.frameResize(position: position, directions: .all)) }
        let corners: [NSCursor.FrameResizePosition] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        for i in 0..<4 {
            let c = corner(i, of: r)
            addCursorRect(CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28), cursor: NSCursor.frameResize(position: corners[i], directions: .all))
        }
        if rounded {
            for i in 0..<4 {
                let k = radiusKnob(i)
                addCursorRect(CGRect(x: k.x - 8, y: k.y - 8, width: 16, height: 16), cursor: .pointingHand)
            }
        }
    }

    // MARK: Dragging

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2, viewRect.contains(p) { onCommit?(); return }
        grip = grip(at: p)
        dragFrom = p
        startRect = unitRect
        startRadii = displayRadii
        if grip == .move { NSCursor.closedHand.push() }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let grip, pictureFrame.width > 1 else { return }
        let p = convert(e.locationInWindow, from: nil)
        let f = pictureFrame
        let dx = (p.x - dragFrom.x) / f.width, dy = (p.y - dragFrom.y) / f.height
        var next = box
        switch grip {
        case .move:
            var r = startRect.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(r.minX, 0), 1 - r.width)
            r.origin.y = min(max(r.minY, 0), 1 - r.height)
            next.rect = orient.stored(r)
        case .corner(let i):
            next.rect = orient.stored(resizeCorner(i, to: CGPoint(x: (p.x - f.minX) / f.width, y: (p.y - f.minY) / f.height)))
        case .edge(let i):
            next.rect = orient.stored(resizeEdge(i, dx: dx, dy: dy))
        case .radius(let i):
            // The knob sits on the arc's middle, r(1 − 1/√2) in from the corner on each axis; the
            // drag along the inward diagonal moves it, and the radius follows.
            let d = inward(i)
            let along = ((p.x - dragFrom.x) * d.x + (p.y - dragFrom.y) * d.y) / 2
            let side = max(min(viewRect.width, viewRect.height), 1)
            let value = min(max(startRadii[i] + Double(along / (1 - 1 / 2.0.squareRoot()) / side), 0), 0.5)
            // ⌥ flips linking for this drag: one corner of four linked, or all four of unlinked.
            let linked = linkedCorners != e.modifierFlags.contains(.option)
            var radii = startRadii
            if linked { radii = Array(repeating: value, count: 4) } else { radii[i] = value }
            next.radii = orient.storedRadii(radii)
        }
        if next != box {
            box = next
            onChange?(next)
        }
    }

    override func mouseUp(with e: NSEvent) {
        if grip == .move { NSCursor.pop() }
        grip = nil
        needsDisplay = true
    }

    /// Smallest crop, in points on screen.
    private static let minimum: CGFloat = 28

    /// Width over height in 0…1 units, for the ratio on screen.
    private var unitRatio: Double? {
        guard let ratio, displayPixels.width > 0 else { return nil }
        return ratio * Double(displayPixels.height / displayPixels.width)
    }

    private func resizeCorner(_ i: Int, to raw: CGPoint) -> CGRect {
        let s = startRect
        let anchor = corner((i + 2) % 4, of: s)
        let minW = Self.minimum / pictureFrame.width, minH = Self.minimum / pictureFrame.height
        var p = CGPoint(x: min(max(raw.x, 0), 1), y: min(max(raw.y, 0), 1))
        let sx: CGFloat = i == 1 || i == 2 ? 1 : -1, sy: CGFloat = i >= 2 ? 1 : -1
        var w = max((p.x - anchor.x) * sx, minW), h = max((p.y - anchor.y) * sy, minH)
        if let k = unitRatio.map({ CGFloat($0) }) {
            // The ratio wins over the pointer: the larger of the two sizes it allows, kept inside.
            if w / h > k { h = w / k } else { w = h * k }
            let maxW = sx > 0 ? 1 - anchor.x : anchor.x, maxH = sy > 0 ? 1 - anchor.y : anchor.y
            if w > maxW { w = maxW; h = w / k }
            if h > maxH { h = maxH; w = h * k }
        }
        p = CGPoint(x: anchor.x + w * sx, y: anchor.y + h * sy)
        return Orient.bounds(anchor, p)
    }

    private func resizeEdge(_ i: Int, dx: CGFloat, dy: CGFloat) -> CGRect {
        var r = startRect
        let minW = Self.minimum / pictureFrame.width, minH = Self.minimum / pictureFrame.height
        switch i {
        case 0: let y = min(max(r.minY + dy, 0), r.maxY - minH); r = CGRect(x: r.minX, y: y, width: r.width, height: r.maxY - y)
        case 1: r.size.width = min(max(r.width + dx, minW), 1 - r.minX)
        case 2: r.size.height = min(max(r.height + dy, minH), 1 - r.minY)
        default: let x = min(max(r.minX + dx, 0), r.maxX - minW); r = CGRect(x: x, y: r.minY, width: r.maxX - x, height: r.height)
        }
        guard let k = unitRatio.map({ CGFloat($0) }) else { return r }
        // With a ratio, the other side follows, centred on where it was, and stays inside.
        if i == 1 || i == 3 {
            var h = r.width / k
            let cy = startRect.midY
            h = min(h, 2 * min(cy, 1 - cy))
            let w = h * k
            let x = i == 1 ? r.minX : r.maxX - w
            return CGRect(x: x, y: cy - h / 2, width: w, height: h)
        } else {
            var w = r.height * k
            let cx = startRect.midX
            w = min(w, 2 * min(cx, 1 - cx))
            let h = w / k
            let y = i == 2 ? r.minY : r.maxY - h
            return CGRect(x: cx - w / 2, y: y, width: w, height: h)
        }
    }

    /// The largest crop of `ratio` (on screen) that fits the picture, centred where the crop is now.
    static func fitted(_ box: CropBox, ratio: Double?, orient: Orient, displayPixels: CGSize) -> CropBox {
        guard let ratio, displayPixels.width > 0 else { return box }
        let k = CGFloat(ratio) * displayPixels.height / displayPixels.width
        let current = orient.display(box.rect)
        let c = CGPoint(x: current.midX, y: current.midY)
        var w: CGFloat = 1, h = 1 / k
        if h > 1 { h = 1; w = k }
        // As large as the picture allows, then moved to keep the old centre where it can.
        var x = c.x - w / 2, y = c.y - h / 2
        x = min(max(x, 0), 1 - w)
        y = min(max(y, 0), 1 - h)
        var out = box
        out.rect = orient.stored(CGRect(x: x, y: y, width: w, height: h))
        return out
    }
}
