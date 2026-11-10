// The annotations over the picture: drawn by the same code that puts them in the file, at the
// picture's own resolution mapped to the screen (zoom, pan, turn). While annotating it takes the
// mouse: draws with the chosen tool, selects, moves, resizes by the handles, edits text.

import AppKit
import PicttyCore

final class AnnotationOverlayView: NSView {
    /// The picture on screen, in this view's coordinates, turned and mirrored as it shows.
    var pictureFrame: CGRect = .zero { didSet { if oldValue != pictureFrame { needsDisplay = true } } }
    var orient = Orient() { didSet { if oldValue != orient { needsDisplay = true } } }
    /// From the picture's 0…1 points (before the crop) to the finished picture's pixels.
    var space = AnnotationSpace(crop: CGRect(x: 0, y: 0, width: 1, height: 1), size: CGSize(width: 1, height: 1)) {
        didSet { if oldValue != space { needsDisplay = true } }
    }
    /// The picture under the marks (any resolution), for blur, censor and the magnifier.
    var base: CGImage? { didSet { if oldValue !== base { needsDisplay = true } } }
    var items: [Annotation] = [] { didSet { if oldValue != items { needsDisplay = true } } }
    var selected: UUID? { didSet { if oldValue != selected { needsDisplay = true } } }
    var interactive = false
    /// nil: select and move.
    var tool: Annotation.Kind?

    /// The controller's side: a mark is about to change (for Undo), changed, added, selected; text to edit.
    var willChange: (() -> Void)?
    var changed: ((Annotation) -> Void)?
    var added: ((Annotation, _ pending: Bool) -> Annotation)?
    var committed: ((UUID) -> Void)?
    var select: ((UUID?) -> Void)?
    var removeIfEmpty: ((UUID) -> Void)?

    private enum Drag {
        case create(UUID)
        case move(UUID, from: CGPoint, original: Annotation)
        case handle(UUID, Int, original: Annotation)
    }
    private var drag: Drag?
    private var editor: NSTextField?
    private var editing: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { interactive ? super.hitTest(point) : nil }

    // MARK: Geometry

    /// Finished-picture pixels to this view.
    private var toView: CGAffineTransform {
        let d0 = orient.display(CGPoint.zero), dx = orient.display(CGPoint(x: 1, y: 0)), dy = orient.display(CGPoint(x: 0, y: 1))
        let unit = CGAffineTransform(a: dx.x - d0.x, b: dx.y - d0.y, c: dy.x - d0.x, d: dy.y - d0.y, tx: d0.x, ty: d0.y)
        return CGAffineTransform(scaleX: 1 / max(space.size.width, 1), y: 1 / max(space.size.height, 1))
            .concatenating(unit)
            .concatenating(CGAffineTransform(scaleX: pictureFrame.width, y: pictureFrame.height))
            .concatenating(CGAffineTransform(translationX: pictureFrame.minX, y: pictureFrame.minY))
    }

    private func pixel(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil).applying(toView.inverted())
    }

    /// Screen points in picture pixels: handles and tolerances stay the same size on screen.
    private var pixelsPerPoint: CGFloat {
        let t = toView
        return 1 / max(hypot(t.a, t.b), 1e-6)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !items.isEmpty || selected != nil else { return }
        ctx.saveGState()
        ctx.concatenate(toView)
        AnnotationRenderer.draw(items.filter { $0.id != editing }, in: ctx, space: space, base: base)
        ctx.restoreGState()
        guard interactive, let id = selected, let item = items.first(where: { $0.id == id }) else { return }
        // The selection: a dashed outline and its handles, in screen points.
        let r = item.bounds(in: space).applying(toView).insetBy(dx: -4, dy: -4)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(r)
        ctx.setLineDash(phase: 0, lengths: [])
        for h in handles(item) {
            let p = h.applying(toView)
            let dot = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
            ctx.setFillColor(.white); ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: dot)
        }
    }

    /// The handles of a mark, in finished-picture pixels.
    private func handles(_ item: Annotation) -> [CGPoint] {
        switch item.kind {
        case .arrow:
            let p = space.pixel(item.a), q = space.pixel(item.b), c = item.control(in: space)
            let mid = CGPoint(x: (p.x + 2 * c.x + q.x) / 4, y: (p.y + 2 * c.y + q.y) / 4)
            return [p, q, mid]
        case .rectangle, .roundedRectangle, .ellipse, .blur, .censor, .spotlight:
            let r = item.box(in: space)
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .magnifier:
            let m = item.magnifier(in: space)
            return [CGPoint(x: m.spot.x + m.r, y: m.spot.y), m.loupe]
        default: return []
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return super.mouseDown(with: event) }
        finishEditing()
        let p = pixel(event), slop = 6 * pixelsPerPoint
        // A handle of the selected mark, then any mark (topmost first) when selecting.
        if let id = selected, let item = items.first(where: { $0.id == id }),
           let h = handles(item).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 8 * pixelsPerPoint }) {
            willChange?()
            drag = .handle(id, h, original: item)
            return
        }
        if tool == nil || event.modifierFlags.contains(.command) {
            if let item = items.reversed().first(where: { $0.hit(p, in: space, slop: slop) }) {
                select?(item.id)
                if event.clickCount == 2, item.kind == .text { return beginEditing(item.id) }
                willChange?()
                drag = .move(item.id, from: p, original: item)
            } else {
                select?(nil)
            }
            return
        }
        guard let kind = tool else { return }
        let u = space.unit(p)
        var item = Annotation(kind: kind, a: u)
        if kind == .highlighter { item.points = [u] }
        if kind == .magnifier {
            item.radius = 0.06
            let m = item.magnifier(in: space)
            item.b = space.unit(CGPoint(x: min(p.x + m.R * 2.2, space.size.width - m.R), y: max(p.y - m.R * 1.6, m.R)))
        }
        guard let made = added?(item, kind != .step) else { return }
        if kind == .text { return beginEditing(made.id) }
        if kind == .step { return }
        drag = .create(made.id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive, let drag else { return }
        let p = pixel(event), u = space.unit(p)
        switch drag {
        case let .create(id):
            guard var item = items.first(where: { $0.id == id }) else { return }
            switch item.kind {
            case .highlighter: item.points.append(u)
            case .magnifier:
                let c = space.pixel(item.a)
                item.radius = max(0.02, hypot(p.x - c.x, p.y - c.y) / space.minSide)
                let m = item.magnifier(in: space)
                item.b = space.unit(CGPoint(x: min(c.x + m.R * 2.2, space.size.width - m.R), y: max(c.y - m.R * 1.6, m.R)))
            default:
                item.b = event.modifierFlags.contains(.shift) && item.isBox ? square(from: item.a, to: u) : u
            }
            changed?(item)
        case let .move(id, from, original):
            var item = original
            let d = CGPoint(x: space.unit(p).x - space.unit(from).x, y: space.unit(p).y - space.unit(from).y)
            item.a = CGPoint(x: original.a.x + d.x, y: original.a.y + d.y)
            item.b = CGPoint(x: original.b.x + d.x, y: original.b.y + d.y)
            item.points = original.points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
            item.id = id
            changed?(item)
        case let .handle(id, h, original):
            var item = original
            item.id = id
            switch item.kind {
            case .arrow:
                if h == 0 { item.a = u } else if h == 1 { item.b = u } else {
                    // The middle: how far it is pulled aside, in lengths of the arrow.
                    let a = space.pixel(item.a), b = space.pixel(item.b)
                    let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 1e-6)
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    item.bend = ((p.x - mid.x) * -dy + (p.y - mid.y) * dx) / len / len
                }
            case .magnifier:
                if h == 0 {
                    let c = space.pixel(item.a)
                    item.radius = max(0.02, hypot(p.x - c.x, p.y - c.y) / space.minSide)
                } else { item.b = u }
            default:
                // A corner moves; the opposite one stays.
                let r = original.box(in: space)
                let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                item.a = space.unit(corners[(h + 2) % 4])
                item.b = event.modifierFlags.contains(.shift) ? square(from: item.a, to: u) : u
            }
            changed?(item)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard interactive, let d = drag else { return }
        drag = nil
        if case let .create(id) = d, let item = items.first(where: { $0.id == id }) {
            // A click with a drawing tool and no drag: nothing worth keeping.
            let r = item.bounds(in: space)
            if item.kind != .magnifier, item.kind != .highlighter || item.points.count < 2, max(r.width, r.height) < 3 * pixelsPerPoint
                || (item.isBox && min(item.box(in: space).width, item.box(in: space).height) < 2 * pixelsPerPoint) {
                removeIfEmpty?(id)
            } else {
                committed?(id)
            }
        }
    }

    /// `b` moved so the box from `a` is square on the finished picture.
    private func square(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let pa = space.pixel(a), pb = space.pixel(b)
        let side = max(abs(pb.x - pa.x), abs(pb.y - pa.y))
        return space.unit(CGPoint(x: pa.x + (pb.x >= pa.x ? side : -side), y: pa.y + (pb.y >= pa.y ? side : -side)))
    }

    // MARK: Text

    func beginEditing(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        finishEditing()
        editing = id
        let frame = item.textFrame(in: space).applying(toView)
        let size = item.style.textSize(space.minSide) / pixelsPerPoint
        let field = NSTextField(string: item.text)
        field.font = NSFont.systemFont(ofSize: max(size, 9), weight: .bold)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(cgColor: item.style.colour.cgColor) ?? .systemRed
        field.textColor = item.style.colour.isLight ? .black : .white
        field.focusRingType = .none
        field.placeholderString = L("Text")
        field.frame = CGRect(x: frame.minX, y: frame.minY, width: max(frame.width, size * 8), height: frame.height)
        field.target = self
        field.action = #selector(fieldDone(_:))
        addSubview(field)
        window?.makeFirstResponder(field)
        editor = field
        needsDisplay = true
    }

    @objc private func fieldDone(_ sender: NSTextField) { finishEditing() }

    /// The text typed becomes the mark's; empty, the mark goes.
    func finishEditing() {
        guard let field = editor, let id = editing else { return }
        editor = nil
        editing = nil
        let text = field.stringValue
        field.removeFromSuperview()
        if var item = items.first(where: { $0.id == id }) {
            let isNew = item.text.isEmpty
            if text.trimmingCharacters(in: .whitespaces).isEmpty { if isNew { removeIfEmpty?(id) } else { willChange?(); removeIfEmpty?(id) } }
            else if isNew { item.text = text; changed?(item); committed?(id) }
            else if item.text != text { willChange?(); item.text = text; changed?(item) }
        }
        window?.makeFirstResponder(superview)
        needsDisplay = true
    }

    var isEditingText: Bool { editor != nil }
}
