// Annotate: arrows, shapes, text, numbered steps, highlighter, blur, censor, magnifier and spotlight
// over the picture, with their own toolbar while annotating. Editable until the picture is left;
// drawn into the pixels on Save, Print and Copy, last of all the edits (before a turn).

import AppKit
import PicttyCore
import Vision

extension ViewerWindowController {
    var offersAnnotate: Bool { model.current != nil && !model.isComparing && model.lightUnavailable == nil }

    @objc func toggleAnnotate(_ sender: Any?) {
        if model.annotating { return finishAnnotating() }
        guard offersAnnotate else { return }
        if model.cropping { commitCrop() }
        if model.showingOriginal { setShowingOriginal(false) }
        model.enlargePickerOpen = false
        model.backgroundPickerOpen = false
        model.annotating = true
        if model.annotationTool == nil { model.annotationTool = .arrow }
        syncChrome()
        // Measured once SwiftUI has put the bar in.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.annotating else { return }
            self.growToFitAnnotationBar()
        }
        updateAnnotationOverlay()
    }

    /// A window narrower than the annotation bar grows to show all of it (centred, kept on screen);
    /// Done gives it back its size, unless it was resized meanwhile.
    private func growToFitAnnotationBar() {
        guard let window, let bar = annotateToolbarHost, !window.styleMask.contains(.fullScreen) else { return }
        bar.layoutSubtreeIfNeeded()
        let need = bar.fittingSize.width + 40
        guard bar.fittingSize.width > 100, window.frame.width < need else { return }
        var f = window.frame
        f.origin.x -= (need - f.width) / 2
        f.size.width = need
        if let screen = window.screen?.visibleFrame {
            f.size.width = min(f.width, screen.width)
            f.origin.x = min(max(f.minX, screen.minX), screen.maxX - f.width)
        }
        framesBeforeAnnotating = (window.frame, f)
        window.setFrame(f, display: true, animate: true)
    }

    func finishAnnotating() {
        annotationOverlay?.finishEditing()
        model.annotating = false
        model.selectedAnnotation = nil
        // Not resized meanwhile (a point or two of rounding aside): it goes back.
        if let frames = framesBeforeAnnotating, let window, abs(window.frame.width - frames.grown.width) < 3,
           abs(window.frame.height - frames.grown.height) < 3 {
            window.setFrame(frames.before, display: true, animate: true)
        }
        framesBeforeAnnotating = nil
        syncChrome()
        updateAnnotationOverlay()
        window?.makeFirstResponder(canvas)
    }

    /// The marks' view follows the picture: after every layout, zoom, pan or turn, and every change.
    func updateAnnotationOverlay() {
        guard let overlay = annotationOverlay else { return }
        let shown = canvas.shown(pane: 0)
        let visible = (model.annotating || !model.annotations.isEmpty) && !model.showingOriginal && !model.isComparing
            && !model.cropping && shown != nil && shown?.url == model.current?.url
        overlay.isHidden = !visible
        guard visible, let shown, let frame = canvas.pictureFrame(pane: 0) else { return }
        overlay.frame = canvas.frame
        overlay.pictureFrame = frame
        let vp = canvas.viewport(pane: 0)
        overlay.orient = Orient(quarterTurns: vp.rotation, mirror: vp.mirror)
        overlay.space = AnnotationSpace(crop: model.crop?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1), size: shown.pixelSize)
        overlay.base = shown.preview ?? shown.full
        overlay.items = model.annotations
        overlay.selected = model.selectedAnnotation
        overlay.interactive = model.annotating
        overlay.tool = model.annotationTool
    }

    func installAnnotationOverlay(in container: NSView) {
        let overlay = AnnotationOverlayView(frame: container.bounds)
        overlay.isHidden = true
        overlay.willChange = { [weak self] in self?.annotationsWillChange() }
        overlay.changed = { [weak self] item in self?.replaceAnnotation(item) }
        overlay.added = { [weak self] item, pending in self?.addAnnotation(item, pending: pending) ?? item }
        overlay.committed = { [weak self] id in self?.commitAnnotation(id) }
        overlay.select = { [weak self] id in self?.model.selectedAnnotation = id; self?.updateAnnotationOverlay() }
        overlay.removeIfEmpty = { [weak self] id in self?.discardAnnotation(id) }
        container.addSubview(overlay)
        annotationOverlay = overlay
    }

    // MARK: Changes

    /// Before every change that Undo should step back over: the window's own Undo (Edit menu, ⌘Z).
    func annotationsWillChange() { registerAnnotationUndo(model.annotations) }

    /// A mark just made (dragged out, or its text typed): Undo takes it away again.
    /// After it, the tool goes back to Select, to move or adjust what was just made; numbered steps
    /// stay, being placed one after another.
    func commitAnnotation(_ id: UUID) {
        registerAnnotationUndo(model.annotations.filter { $0.id != id })
        if model.annotationTool != .step {
            model.annotationTool = nil
            updateAnnotationOverlay()
        }
    }

    private func registerAnnotationUndo(_ state: [Annotation]) {
        guard let undo = window?.undoManager else { return }
        undo.registerUndo(withTarget: self) { c in
            c.registerAnnotationUndo(c.model.annotations)  // registered while undoing: it is the Redo
            c.model.annotations = state
            if let id = c.model.selectedAnnotation, !state.contains(where: { $0.id == id }) { c.model.selectedAnnotation = nil }
            c.annotationsChanged()
        }
        undo.setActionName(L("Annotation"))
    }

    private func annotationsChanged() {
        // The first mark makes the picture edited: the editing session holds it like any other edit.
        if lightSession?.renderer.url != model.current?.url { refreshEdit() }
        updateAnnotationOverlay()
        updateDocumentEdited()
        model.objectWillChange.send()
    }

    /// A new mark in the current style; Auto picks the colour that stands out against the picture under it.
    /// `pending`: being drawn or typed; it enters Undo when it is done (`commitAnnotation`).
    @discardableResult
    func addAnnotation(_ item: Annotation, pending: Bool = false) -> Annotation {
        var item = item
        item.style = model.annotationStyle
        if item.kind == .censor { item.solid = model.censorSolid }
        if model.autoColour, ![.blur, .censor, .spotlight, .highlighter].contains(item.kind),
           let average = averageColour(around: item.a) {
            item.style.colour = AnnotationStyle.contrasting(average: average)
        }
        if item.kind == .highlighter, model.autoColour { item.style.colour = AnnotationStyle.palette[1] }
        if !pending { annotationsWillChange() }
        model.annotations.append(item)
        model.selectedAnnotation = item.id
        annotationsChanged()
        return item
    }

    func replaceAnnotation(_ item: Annotation) {
        guard let i = model.annotations.firstIndex(where: { $0.id == item.id }) else { return }
        model.annotations[i] = item
        annotationsChanged()
    }

    /// A mark started and given up (a click, empty text): gone, never in Undo.
    func discardAnnotation(_ id: UUID) {
        model.annotations.removeAll { $0.id == id }
        if model.selectedAnnotation == id { model.selectedAnnotation = nil }
        annotationsChanged()
    }

    func deleteSelectedAnnotation() {
        guard let id = model.selectedAnnotation else { return }
        annotationsWillChange()
        model.annotations.removeAll { $0.id == id }
        model.selectedAnnotation = nil
        annotationsChanged()
    }

    func duplicateSelectedAnnotation() {
        guard let id = model.selectedAnnotation, var copy = model.annotations.first(where: { $0.id == id }) else { return }
        annotationsWillChange()
        copy.id = UUID()
        let d = CGPoint(x: 0.02, y: 0.02)
        copy.a = CGPoint(x: copy.a.x + d.x, y: copy.a.y + d.y)
        copy.b = CGPoint(x: copy.b.x + d.x, y: copy.b.y + d.y)
        copy.points = copy.points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        model.annotations.append(copy)
        model.selectedAnnotation = copy.id
        annotationsChanged()
    }

    func undoAnnotation() { window?.undoManager?.undo(); updateAnnotationOverlay() }
    func redoAnnotation() { window?.undoManager?.redo(); updateAnnotationOverlay() }
    var canUndoAnnotation: Bool { window?.undoManager?.canUndo ?? false }
    var canRedoAnnotation: Bool { window?.undoManager?.canRedo ?? false }

    // MARK: Style

    func setAnnotationTool(_ kind: Annotation.Kind?) {
        annotationOverlay?.finishEditing()
        model.annotationTool = kind
        updateAnnotationOverlay()
    }

    /// A style change applies to the selected mark too.
    func setAnnotationStyle(_ change: (inout AnnotationStyle) -> Void) {
        change(&model.annotationStyle)
        guard let id = model.selectedAnnotation, var item = model.annotations.first(where: { $0.id == id }) else { return }
        annotationsWillChange()
        change(&item.style)
        replaceAnnotation(item)
    }

    func setAnnotationColour(_ colour: AnnotationStyle.RGBA?) {
        model.autoColour = colour == nil
        guard let colour else { return }
        setAnnotationStyle { $0.colour = colour }
    }

    /// The picture's average colour around `u` (0…1 before the crop), from what is on screen.
    private func averageColour(around u: CGPoint) -> (r: Double, g: Double, b: Double)? {
        guard let overlay = annotationOverlay, let base = overlay.base else { return nil }
        let p = overlay.space.pixel(u)
        let kx = CGFloat(base.width) / overlay.space.size.width, ky = CGFloat(base.height) / overlay.space.size.height
        let side = max(8, CGFloat(min(base.width, base.height)) * 0.06)
        let r = CGRect(x: p.x * kx - side / 2, y: p.y * ky - side / 2, width: side, height: side).integral
            .intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard r.width >= 1, let patch = base.cropping(to: r) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    // MARK: Smart redact

    /// E-mail addresses, phone and card numbers covered, and faces blurred, found by macOS's own text
    /// and face recognition on the picture as it is. Each is an ordinary mark; one Undo takes them all.
    func smartRedact() {
        guard let overlay = annotationOverlay, let base = overlay.base, let url = model.current?.url else { return }
        let space = overlay.space
        model.maskWorking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.sensitiveRegions(in: base)
            timingMark("redact: \(found.count) region(s) in \(base.width)×\(base.height)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.maskWorking = false
                    guard self.model.current?.url == url, self.model.annotating else { return }
                    guard !found.isEmpty else {
                        return self.showToast(L("Nothing to hide found: no e-mail, phone or card numbers, no faces"),
                                              symbol: "checkmark.shield")
                    }
                    self.annotationsWillChange()
                    for (rect, isFace) in found {
                        // Vision's 0…1, origin bottom-left, of the finished picture → the picture before the crop.
                        let p = CGPoint(x: rect.minX * space.size.width, y: (1 - rect.maxY) * space.size.height)
                        let q = CGPoint(x: rect.maxX * space.size.width, y: (1 - rect.minY) * space.size.height)
                        var item = Annotation(kind: isFace ? .blur : .censor, a: space.unit(p), b: space.unit(q))
                        item.style = self.model.annotationStyle
                        self.model.annotations.append(item)
                    }
                    self.annotationsChanged()
                    self.showToast(L("Hid %ld things: e-mails, numbers and faces", found.count), symbol: "eye.slash")
                }
            }
        }
    }

    nonisolated private static func sensitiveRegions(in image: CGImage) -> [(CGRect, Bool)] {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([text, faces])
        var out: [(CGRect, Bool)] = []
        let patterns = [#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, #"\+?\d[\d ()./-]{7,}\d"#, #"\b(?:\d[ -]?){13,19}\b"#]
            .compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        for observation in text.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let s = candidate.string
            for regex in patterns {
                for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                    guard let range = Range(match.range, in: s), let box = try? candidate.boundingBox(for: range) else { continue }
                    out.append((box.boundingBox.insetBy(dx: -0.004, dy: -0.004), false))
                }
            }
        }
        for face in faces.results ?? [] {
            let b = face.boundingBox
            out.append((b.insetBy(dx: -b.width * 0.15, dy: -b.height * 0.2), true))
        }
        return out
    }

    // MARK: Keys

    /// While annotating: tools by letter, ⌫, ⌘D, Esc, Return. Typing into a text mark is left alone.
    func handleAnnotateKey(_ event: NSEvent, chars: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard model.annotating else { return false }
        if annotationOverlay?.isEditingText == true || window?.firstResponder is NSTextView { return false }
        if flags == .command, chars == "d" { duplicateSelectedAnnotation(); return true }
        guard flags.subtracting(.shift).isEmpty else { return false }
        switch event.keyCode {
        case 51, 117: deleteSelectedAnnotation(); return true  // ⌫, ⌦
        case 53:
            if model.selectedAnnotation != nil { model.selectedAnnotation = nil; updateAnnotationOverlay() } else { finishAnnotating() }
            return true
        case 36, 76: finishAnnotating(); return true
        default: break
        }
        let tools: [String: Annotation.Kind?] = ["v": nil, "a": .arrow, "r": .rectangle, "u": .roundedRectangle, "o": .ellipse,
                                                  "t": .text, "n": .step, "h": .highlighter, "b": .blur, "x": .censor,
                                                  "m": .magnifier, "s": .spotlight]
        if let tool = tools[chars.lowercased()] { setAnnotationTool(tool); return true }
        return false
    }
}
