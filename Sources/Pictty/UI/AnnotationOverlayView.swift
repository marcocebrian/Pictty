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
    var items: [Annotation] = [] { didSet { if oldValue != items { needsDisplay = true; restyleEditor() } } }
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
    /// The pill behind the field while typing: rounded and padded like the mark it becomes.
    private var editorPill: NSView?
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
        // The text tool on a text mark: that text, to edit, not a new one on top of it.
        if tool == .text, let item = items.reversed().first(where: { $0.kind == .text && $0.hit(p, in: space, slop: slop) }) {
            select?(item.id)
            return beginEditing(item.id)
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
            case .arrow:
                item.b = event.modifierFlags.contains(.shift) ? snapped(from: item.a, to: u) : u
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
                let shift = event.modifierFlags.contains(.shift)
                if h == 0 { item.a = shift ? snapped(from: item.b, to: u) : u } else if h == 1 { item.b = shift ? snapped(from: item.a, to: u) : u } else {
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

    /// `b` turned about `a` to the nearest 45° on the finished picture (⇧ with the arrow).
    private func snapped(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let pa = space.pixel(a), pb = space.pixel(b)
        let len = hypot(pb.x - pa.x, pb.y - pa.y), step = CGFloat.pi / 4
        let ang = (atan2(pb.y - pa.y, pb.x - pa.x) / step).rounded() * step
        return space.unit(CGPoint(x: pa.x + cos(ang) * len, y: pa.y + sin(ang) * len))
    }

    /// The selected mark moved by `dx`, `dy` screen points (the arrow keys), whatever the zoom or turn.
    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let id = selected, var item = items.first(where: { $0.id == id }) else { return }
        let inv = toView.inverted()
        let o = CGPoint.zero.applying(inv), v = CGPoint(x: dx, y: dy).applying(inv)
        let d = CGPoint(x: (v.x - o.x) / space.size.width * space.crop.width, y: (v.y - o.y) / space.size.height * space.crop.height)
        willChange?()
        item.a = CGPoint(x: item.a.x + d.x, y: item.a.y + d.y)
        item.b = CGPoint(x: item.b.x + d.x, y: item.b.y + d.y)
        item.points = item.points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        changed?(item)
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
        let size = item.style.textSize(space.minSide) / pixelsPerPoint
        let field = NSTextField(string: item.text)
        field.font = NSFont.systemFont(ofSize: max(size, 9), weight: .bold)
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = item.style.colour.isLight ? .black : .white
        field.focusRingType = .none
        field.placeholderString = L("Text")
        // Several lines: Return starts a new one (see the delegate below), the field grows to fit.
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.lineBreakMode = .byClipping
        field.delegate = self
        let pill = FlippedView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = item.style.colour.cgColor
        pill.addSubview(field)
        addSubview(pill)
        editorPill = pill
        editor = field
        fitEditor()
        window?.makeFirstResponder(field)
        // A text opened again: the caret at its end, to add to it, not everything selected to be typed over.
        if let text = field.currentEditor() as? NSTextView {
            text.setSelectedRange(NSRange(location: (field.stringValue as NSString).length, length: 0))
        }
        needsDisplay = true
    }

    /// The field takes the mark's colour and size when they change while it is typed.
    private func restyleEditor() {
        guard let field = editor, let id = editing, let item = items.first(where: { $0.id == id }) else { return }
        editorPill?.layer?.backgroundColor = item.style.colour.cgColor
        field.textColor = item.style.colour.isLight ? .black : .white
        field.font = NSFont.systemFont(ofSize: max(item.style.textSize(space.minSide) / pixelsPerPoint, 9), weight: .bold)
        fitEditor()
    }

    /// The pill over the mark's, as large as the text typed so far, the field inset the way the
    /// text is drawn (a little room on the right for the next letter).
    private func fitEditor() {
        guard let field = editor, let pill = editorPill, let id = editing, var item = items.first(where: { $0.id == id }) else { return }
        item.text = field.stringValue
        let frame = item.textFrame(in: space).applying(toView)
        let size = field.font?.pointSize ?? 12
        let fits = field.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: 100_000, height: 100_000)) ?? .zero
        let padX = size * 0.4, padY = size * 0.18
        let width = max(frame.width, fits.width + 2 * padX + size * 0.5, size * 6)
        pill.frame = CGRect(x: frame.minX, y: frame.minY, width: width, height: max(frame.height, fits.height + 2 * padY))
        pill.layer?.cornerRadius = size * 0.4
        field.frame = CGRect(x: padX - 2, y: padY - 1, width: width - padX * 2 + 4, height: fits.height)
    }

    /// The text typed becomes the mark's; empty, the mark goes.
    func finishEditing() {
        guard let field = editor, let id = editing else { return }
        editor = nil
        editing = nil
        var text = field.stringValue
        while text.hasSuffix("\n") { text.removeLast() }
        editorPill?.removeFromSuperview()
        editorPill = nil
        if var item = items.first(where: { $0.id == id }) {
            let isNew = item.text.isEmpty
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { if isNew { removeIfEmpty?(id) } else { willChange?(); removeIfEmpty?(id) } }
            else if isNew { item.text = text; changed?(item); committed?(id) }
            else if item.text != text { willChange?(); item.text = text; changed?(item) }
        }
        window?.makeFirstResponder(superview)
        needsDisplay = true
    }

    var isEditingText: Bool { editor != nil }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension AnnotationOverlayView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { fitEditor() }

    /// Return: a new line. Esc, Tab or ⌘Return: done. A click outside is done too (mouseDown).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let command = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        switch selector {
        case #selector(NSResponder.insertNewline(_:)) where command,
             #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            finishEditing()
        case #selector(NSResponder.insertNewline(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)
            fitEditor()
        case Selector(("noop:")) where command && [36, 76].contains(NSApp.currentEvent?.keyCode ?? 0):
            finishEditing()
        default:
            return false
        }
        return true
    }
}
