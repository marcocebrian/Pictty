// The Adjust panel's side of the conductor: one picture edited at a time, on screen only until it
// is saved. The edited pixels replace the picture's decodes on the canvas, so zoom, the settled
// Lanczos render, the loupe, the histogram and the clipping warnings all show the edit.
//
// A quarter turn or a mirror of the picture on screen is an edit too. Saved alone, it changes the
// file's orientation tag and not one pixel; saved with other edits, the pixels are turned before
// they are encoded.

import AppKit
import PicttyCore
import SwiftUI
import UniformTypeIdentifiers

/// The picture as it was when editing began, to go back to.
final class LightSession {
    let renderer: LightRenderer
    let preview: CGImage
    /// The picture's own size and transparency, before any crop.
    let pixelSize: CGSize
    let hasAlpha: Bool
    var editedFullRequested = false

    init(renderer: LightRenderer, preview: CGImage, pixelSize: CGSize, hasAlpha: Bool) {
        self.renderer = renderer
        self.preview = preview
        self.pixelSize = pixelSize
        self.hasAlpha = hasAlpha
    }
}

extension ViewerWindowController: NSMenuItemValidation {
    /// Edits that are only on screen: adjustments, or a turn or mirror of the picture.
    var hasUnsavedEdits: Bool { hasUnsavedAdjustments || orientationChange != nil }

    var hasUnsavedAdjustments: Bool { lightSession != nil && hasPixelEdits }

    /// Edits that change pixels: the panel's adjustments, or a crop.
    var hasPixelEdits: Bool { !model.light.isNeutral || model.crop != nil }

    /// The turn and mirror of the picture on screen, if it has any and it can be saved.
    var orientationChange: (quarterTurns: Int, mirror: Bool)? {
        guard !model.isComparing, let item = model.current, canvas.shown(pane: 0)?.url == item.url else { return nil }
        let vp = canvas.viewport(pane: 0)
        return vp.rotation != 0 || vp.mirror ? (vp.rotation, vp.mirror) : nil
    }

    /// The edited picture keeps its own pixels on the canvas.
    func keepsEdits(_ url: URL) -> Bool {
        lightSession?.renderer.url == url && hasPixelEdits
    }

    /// The dot in the close button, as every Mac document window shows unsaved changes.
    func updateDocumentEdited() {
        let edited = hasUnsavedEdits
        if window?.isDocumentEdited != edited { window?.isDocumentEdited = edited }
        let url = model.current?.url
        if window?.representedURL != url { window?.representedURL = url }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveEdits(_:)), #selector(revertEdits(_:)): return hasUnsavedEdits && !model.isSaving
        case #selector(saveEditsAs(_:)): return model.current != nil && model.lightUnavailable == nil && !model.isSaving
        case #selector(toggleOriginal(_:)): return hasUnsavedAdjustments && !model.cropping
        case #selector(toggleCrop(_:)): return model.current != nil && model.lightUnavailable == nil
        default: return true
        }
    }

    @objc func toggleLight(_ sender: Any?) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            model.showLight.toggle()
            if model.showLight { model.showInspector = false }
            if !model.showLight { model.pickingWhite = false; canvas.picking = false }
        }
        updateLightAvailability()
        if model.showLight { NeuralDenoiser.shared.warmUp() }
        syncChrome()
        // Best Fit: the window grows by the panel so the picture keeps its size, as for the pinned strip.
        fitWindowToPicture(animated: true)
        revealChrome()
    }

    /// Why the picture on screen cannot be edited, or nil when it can.
    func updateLightAvailability() {
        let offers = model.current.map { item in
            ImageFormats.isRaw(item.url) || (NeuralDenoiser.shared.isAvailable && canvas.shown(pane: 0)?.isHDR != true)
        } ?? false
        if model.offersDenoise != offers { model.offersDenoise = offers }
        var reason: String?
        if let item = model.current {
            if model.isComparing { reason = L("Editing works on one picture at a time. Leave Compare (D) to edit.") }
            else if ImageFormats.isVector(item.url) { reason = L("Vector pictures (SVG) are drawn, not developed: there is no light to adjust.") }
            else if isAnimated(item) { reason = L("Animated pictures can't be edited yet.") }
            else if canvas.shown(pane: 0)?.url != item.url { reason = L("Loading…") }
        } else {
            reason = L("Open a picture to edit it.")
        }
        if model.lightUnavailable != reason { model.lightUnavailable = reason }
        let engine: LightRenderer.Engine? = model.current.map { ImageFormats.isRaw($0.url) ? .appleRAW : .pictty }
        if model.lightEngine != engine { model.lightEngine = engine }
    }

    // MARK: - Editing

    /// The panel's sliders, wheels and buttons land here.
    func setLight(_ a: Adjustments) {
        let wasDenoised = model.light.denoise > 0
        model.light = a
        // The network's first pass over a picture takes a second; the panel says so.
        if a.denoise > 0, !wasDenoised, !model.denoising, lightSession?.renderer.engine != .appleRAW,
           denoisedOnce != model.current?.url {
            denoisedOnce = model.current?.url
            model.denoising = true
        }
        refreshEdit()
    }

    /// The network's progress, for the canvas: under way, then a moment of done.
    func denoiseProgressed(_ fraction: Double, full: Bool) {
        if model.denoiseFull != full { model.denoiseFull = full }
        model.denoiseDone = false
        model.denoising = true
        if model.denoiseProgress == nil || fraction == 1 || Int(fraction * 4) != Int((model.denoiseProgress ?? 0) * 4) {
            timingMark(String(format: "noise badge: %@ %.0f %%", full ? "every pixel" : "on screen", fraction * 100))
        }
        model.denoiseProgress = fraction
    }

    func denoiseFinished() {
        guard model.denoiseProgress != nil || model.denoising else { return }
        model.denoising = false
        model.denoiseProgress = nil
        model.denoiseDone = true
        timingMark("noise badge: noise reduced")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.model.denoiseDone = false
            timingMark("noise badge: gone")
        }
    }

    /// Auto: the picture's own noise sets the strength; a clean picture is left alone.
    @objc func autoDenoise(_ sender: Any?) {
        guard model.lightUnavailable == nil, let url = model.current?.url, let shown = canvas.shown(pane: 0),
              let image = originalPreview(shown) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let levels = PictureMeasure.noiseLevels(image)
            let amount = PictureMeasure.denoiseAmount(levels)
            let steps = Double(max(levels.full, levels.half, levels.quarter))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.model.current?.url == url else { return }
                    var a = self.model.light
                    a.denoise = amount
                    self.setLight(a)
                    if amount == 0 {
                        self.showToast("Clean already: there is no noise to take out", symbol: "checkmark.seal")
                    } else {
                        self.showToast(L("Noise reduction %ld · measured %.1f levels of noise", Int(amount * 100), steps),
                                       symbol: "wand.and.sparkles")
                    }
                }
            }
        }
    }

    /// Puts what the edits make of the picture on the canvas: the adjustments through the engine,
    /// then the crop (none while cropping, which shows the whole picture to crop from).
    func refreshEdit() {
        defer { updateDocumentEdited() }
        guard model.lightUnavailable == nil, let url = model.current?.url, let shown = canvas.shown(pane: 0),
              shown.url == url else { return }
        if lightSession?.renderer.url != url {
            guard hasPixelEdits || model.cropping else { return }
            beginLight(url: url, shown: shown)
        }
        guard let session = lightSession else { return }
        if model.showingOriginal { model.showingOriginal = false }
        if model.light.isNeutral {
            session.renderer.cancelAll()
            model.lightTiming = ""
            present(session.preview, full: false, session: session)
            if let full = store.cached(url, full: true) { present(full.image, full: true, session: session) }
            if model.crop == nil || model.cropping, let known = analyses[url.path] { publish(known.analysis, for: url) }
            return
        }
        session.renderer.render(model.light) { [weak self] r in self?.lightRendered(r, url: url) }
    }

    private func beginLight(url: URL, shown: CanvasView.Shown) {
        guard let preview = originalPreview(shown) else { return }
        let renderer = LightRenderer(url: url, preview: preview, isHDR: shown.isHDR, maxPixel: store.previewMaxPixel)
        renderer.onDenoised = { [weak self] in
            guard let self, self.lightSession?.renderer === renderer else { return }
            self.denoiseFinished()
            self.refreshEdit()
        }
        renderer.onDenoiseProgress = { [weak self] fraction, full in
            guard let self, self.lightSession?.renderer === renderer else { return }
            self.denoiseProgressed(fraction, full: full)
        }
        lightSession = LightSession(renderer: renderer, preview: preview, pixelSize: shown.pixelSize, hasAlpha: shown.hasAlpha)
    }

    /// The crop applied, if there is one and it is not being made, and the picture's size to match.
    private func present(_ image: CGImage, full: Bool, session: LightSession) {
        let crop = model.cropping ? nil : model.crop
        let out = crop?.apply(to: image) ?? image
        let size = crop?.croppedSize(session.pixelSize) ?? session.pixelSize
        let resized = canvas.shown(pane: 0)?.pixelSize != size
        canvas.showEdited(out, full: full, pane: 0, pixelSize: size, hasAlpha: session.hasAlpha || crop?.isRounded == true)
        if resized {
            // A crop is a different picture to fit: the zoom mode and the window follow it.
            applyZoom(animated: false)
            fitWindowToPicture(animated: true)
        }
        if crop != nil, !full { analyseEdit(out, url: session.renderer.url) }
    }

    /// The untouched picture at screen size: a full decode on screen is edited at screen size, and
    /// zooming in renders every pixel.
    private func originalPreview(_ shown: CanvasView.Shown) -> CGImage? {
        if let session = lightSession, session.renderer.url == shown.url { return session.preview }
        guard let image = shown.preview ?? shown.full else { return nil }
        let limit = CGFloat(store.previewMaxPixel)
        let longest = CGFloat(max(image.width, image.height))
        guard longest > limit * 1.5 else { return image }
        let k = limit / longest
        return Resampler.render(image, from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                width: Int(CGFloat(image.width) * k), height: Int(CGFloat(image.height) * k)) ?? image
    }

    private func lightRendered(_ r: LightRenderer.Rendered, url: URL) {
        guard let session = lightSession, session.renderer.url == url, model.current?.url == url,
              r.adjustments == model.light, !model.showingOriginal else { return }
        session.editedFullRequested = false
        present(r.image, full: false, session: session)
        let engine = session.renderer.engine == .pictty ? L("Pictty engine") : L("Apple RAW engine")
        model.lightTiming = String(format: "%@ · %.0f ms · %ld×%ld", engine, r.milliseconds, r.image.width, r.image.height)
        if model.crop == nil || model.cropping { analyseEdit(r.image, url: url) }
        updateStatus()
    }

    /// Histogram and clipping of the edit, live. Kept apart from the per-file measurements.
    private func analyseEdit(_ image: CGImage, url: URL) {
        lightAnalysisTicket &+= 1
        let ticket = lightAnalysisTicket
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let a = ImageAnalysis.analyze(image, maxPixel: 1024)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let a, ticket == self.lightAnalysisTicket, self.keepsEdits(url) else { return }
                    self.model.analysis = a
                    self.canvas.setClipMask(a.mask, pane: 0)
                }
            }
        }
    }

    /// Zoomed in past the screen-sized edit: every pixel, through the same engine.
    func requestEditedFull(_ url: URL) {
        guard let session = lightSession, !session.editedFullRequested else { return }
        // Every pixel waits for the screen-sized noise reduction: they would only compete for the
        // GPU, and the larger one takes its coarse grain from the smaller. Asked again when it is done.
        guard !(model.denoising && model.light.denoise > 0 && !model.denoiseFull) else { return }
        session.editedFullRequested = true
        let a = model.light
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.lightSession === session, self.model.light == a, self.canvas.needsFull(url) else {
                session.editedFullRequested = false
                return
            }
            let render: (CGImage) -> Void = { original in
                guard !a.isNeutral else { return self.present(original, full: true, session: session) }
                session.renderer.renderFull(original, a) { [weak self] r in
                    guard let self else { return }
                    if self.model.denoiseFull { self.denoiseFinished() }
                    guard self.lightSession === session, self.model.light == r.adjustments,
                          !self.model.showingOriginal else { return }
                    self.present(r.image, full: true, session: session)
                    self.updateStatus()
                }
            }
            if session.renderer.engine == .appleRAW { return render(session.preview) }
            if let full = self.store.cached(url, full: true) { return render(full.image) }
            self.store.load(url, full: true) { d in if let d { render(d.image) } }
        }
    }

    /// The picture's own decodes back on the canvas, with their own histogram.
    private func showOriginalPixels() {
        guard let session = lightSession else { return }
        let url = session.renderer.url
        let resized = canvas.shown(pane: 0)?.pixelSize != session.pixelSize
        canvas.showEdited(session.preview, full: false, pane: 0, pixelSize: session.pixelSize, hasAlpha: session.hasAlpha)
        if let full = store.cached(url, full: true) { canvas.showEdited(full.image, full: true, pane: 0) }
        if resized {
            applyZoom(animated: false)
            fitWindowToPicture(animated: true)
        }
        if let known = analyses[url.path] { publish(known.analysis, for: url) }
        updateStatus()
    }

    /// Before and after (Y): the original while it is on, the edit again after.
    @objc func toggleOriginal(_ sender: Any?) {
        setShowingOriginal(!model.showingOriginal)
    }

    func setShowingOriginal(_ on: Bool) {
        guard hasUnsavedAdjustments, model.showingOriginal != on else { return }
        model.showingOriginal = on
        if on {
            lightSession?.renderer.cancelAll()
            showOriginalPixels()
        } else {
            refreshEdit()
        }
    }

    /// Every slider back to zero; the algorithm choices stay.
    @objc func resetLight(_ sender: Any?) { setLight(model.light.valuesReset) }

    /// File ▸ Revert: the adjustments and any turn or mirror, all gone.
    @objc func revertEdits(_ sender: Any?) {
        if model.cropping { cancelCrop() }
        model.crop = nil
        setLight(model.light.valuesReset)
        resetOrientation()
    }

    private func resetOrientation() {
        guard orientationChange != nil else { return }
        var vp = canvas.viewport(pane: 0)
        vp.rotation = 0
        vp.mirror = false
        canvas.setViewport(vp, pane: 0, animated: true)
        model.mirrored = false
        fitWindowToPicture(animated: true)
        updateDocumentEdited()
    }

    /// The picture changed: the edits go (settled before, if they had to be).
    func endLight() {
        model.denoising = false
        model.denoiseProgress = nil
        model.denoiseDone = false
        model.crop = nil
        model.cropping = false
        syncCropChrome()
        lightSession?.renderer.cancelAll()
        lightSession = nil
        lightAnalysisTicket &+= 1
        model.light = model.light.valuesReset
        model.showingOriginal = false
        model.lightTiming = ""
        model.pickingWhite = false
        canvas?.picking = false
        updateDocumentEdited()
    }

    // MARK: - White balance

    /// Auto: the light the picture was taken under, estimated, and taken out.
    @objc func autoWhiteBalance(_ sender: Any?) {
        guard model.lightUnavailable == nil, let url = model.current?.url, let shown = canvas.shown(pane: 0),
              let image = originalPreview(shown) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let light = ColourMath.estimateIlluminant(image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.model.current?.url == url else { return }
                    guard let light else {
                        return self.showToast("Not enough neutral to go by: set it by hand", symbol: "wand.and.stars", tone: .warning)
                    }
                    let wb = ColourMath.whiteBalance(neutral: light)
                    var a = self.model.light
                    a.temperature = (wb.temperature * 100).rounded() / 100
                    a.tint = (wb.tint * 100).rounded() / 100
                    self.setLight(a)
                }
            }
        }
    }

    /// The eyedropper: the next click on the picture says what should be grey.
    @objc func toggleWhitePicker(_ sender: Any?) {
        model.pickingWhite.toggle()
        canvas.picking = model.pickingWhite
        if model.pickingWhite { showToast("Click something that should be neutral grey", symbol: "eyedropper") }
    }

    func pickedWhite(at point: CGPoint) {
        model.pickingWhite = false
        canvas.picking = false
        guard let shown = canvas.shown(pane: 0), let image = originalPreview(shown),
              let colour = ColourMath.sample(image, at: point) else { return }
        guard colour.max() > 0.004, colour.max() < 0.97 else {
            return showToast("Too dark or too bright to tell: pick a mid grey", symbol: "eyedropper", tone: .warning)
        }
        let wb = ColourMath.whiteBalance(neutral: colour)
        var a = model.light
        a.temperature = (wb.temperature * 100).rounded() / 100
        a.tint = (wb.tint * 100).rounded() / 100
        setLight(a)
    }

    // MARK: - Unsaved changes

    /// Runs `proceed` once the edits on screen are saved or let go; asks first if there are any.
    /// `cancelled` runs if the person keeps them on screen.
    func settleEdits(cancelled: (() -> Void)? = nil, then proceed: @escaping () -> Void) {
        guard hasUnsavedEdits, let window, let item = model.current else { return proceed() }
        if window.attachedSheet != nil { cancelled?(); return }
        let alert = NSAlert()
        alert.messageText = L("Do you want to save the changes made to “%@”?", item.fileName)
        alert.informativeText = L("Your changes will be lost if you don’t save them.")
        let inPlace = canSaveInPlace(item.url)
        alert.addButton(withTitle: inPlace ? L("Save") : L("Save As…"))
        alert.addButton(withTitle: L("Cancel"))
        let discard = alert.addButton(withTitle: L("Don’t Save"))
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                inPlace ? self.saveInPlace(then: proceed, cancelled: cancelled) : self.saveAs(then: proceed, cancelled: cancelled)
            case .alertThirdButtonReturn:
                if self.model.cropping { self.cancelCrop() }
                self.model.crop = nil
                self.setLight(self.model.light.valuesReset)
                self.endLight()
                self.resetOrientation()
                proceed()
            default:
                cancelled?()
            }
        }
    }

    // MARK: - Saving

    /// Save writes over the file itself: only formats ImageIO can write back, and never a RAW.
    func canSaveInPlace(_ url: URL) -> Bool {
        guard !ImageFormats.isRaw(url), let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return ExportFormat(fileType: type) != nil
    }

    /// ⌘S: no questions. The file keeps its format, size, colour profile, metadata and bit depth;
    /// a JPEG keeps the quality it was made with.
    @objc func saveEdits(_ sender: Any?) {
        guard let item = model.current, hasUnsavedEdits, !model.isSaving else { return }
        canSaveInPlace(item.url) ? saveInPlace(then: nil, cancelled: nil) : saveAs(then: nil, cancelled: nil)
    }

    @objc func saveEditsAs(_ sender: Any?) {
        guard model.current != nil, model.lightUnavailable == nil, !model.isSaving else { return }
        saveAs(then: nil, cancelled: nil)
    }

    private func saveInPlace(then proceed: (() -> Void)?, cancelled: (() -> Void)?) {
        guard let item = model.current, let type = UTType(filenameExtension: item.url.pathExtension),
              let format = ExportFormat(fileType: type) else { return }
        var o = prefs.exportOptions
        o.format = format
        o.colorSpace = .original
        o.longEdge = nil
        o.metadata = .all
        o.hdr = .gainMap
        o.depth = (canvas.shown(pane: 0)?.preview?.bitsPerComponent ?? 8) > 8 && format.depths.contains(.sixteen) ? .sixteen : .eight
        o.matchQuality = true
        var dest = item.url
        if model.crop?.isRounded == true, !format.keepsAlpha {
            // Rounded corners are transparency, which a JPEG cannot hold: a PNG beside it, the
            // JPEG untouched. No question asked; nothing is lost either way.
            o.format = .png
            o.depth = .eight
            dest = Self.freeName(item.url.deletingPathExtension().appendingPathExtension("png"))
        }
        export(item.url, to: dest, options: o, then: proceed, cancelled: cancelled)
    }

    /// `url`, or "name 2", "name 3"… if a file is already there.
    static func freeName(_ url: URL) -> URL {
        var candidate = url, n = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Save As: any format this Mac can write, every setting shown.
    func saveAs(then proceed: (() -> Void)?, cancelled: (() -> Void)?) {
        guard let item = model.current, let window else { return }
        let shown = canvas.shown(pane: 0)
        var size = shown?.pixelSize ?? .zero
        if let o = orientationChange, o.quarterTurns % 2 == 1 { size = CGSize(width: size.height, height: size.width) }
        let settings = ExportSettings(options: prefs.exportOptions, isHDR: shown?.isHDR ?? false,
                                      hasAlpha: shown?.hasAlpha ?? false, pixelSize: size, edited: hasUnsavedEdits,
                                      sample: shown?.preview ?? shown?.full)
        let panel = NSSavePanel()
        panel.title = hasUnsavedEdits ? L("Save As") : L("Convert")
        panel.prompt = hasUnsavedEdits ? L("Save") : L("Convert")
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let base = item.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = base + (hasUnsavedEdits ? L(" edited") : "") + "." + settings.options.format.fileExtension
        panel.allowedContentTypes = [settings.options.format.type]
        let accessory = NSHostingView(rootView: ExportSettingsView(settings: settings))
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        settings.onFormatChange = { [weak panel] format in
            guard let panel else { return }
            panel.allowedContentTypes = [format.type]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = name + "." + format.fileExtension
            accessory.frame.size = accessory.fittingSize
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let dest = panel.url else { cancelled?(); return }
            self.prefs.exportOptions = settings.options
            var o = settings.options
            o.matchQuality = false
            self.export(item.url, to: dest, options: o, then: proceed, cancelled: cancelled)
        }
    }

    /// Writes the picture with its edits, off the main thread, as gently as the edits allow:
    /// a turn or mirror alone saved over the file changes its orientation tag and nothing else.
    private func export(_ url: URL, to dest: URL, options: ExportOptions, then proceed: (() -> Void)?,
                        cancelled: (() -> Void)?) {
        let a = model.light
        let adjusted = hasUnsavedAdjustments
        let crop = model.crop
        let turn = orientationChange
        let engine = lightSession?.renderer.engine ?? (ImageFormats.isRaw(url) ? .appleRAW : .pictty)
        let renderer = lightSession?.renderer
        let inPlace = dest.standardizedFileURL == url.standardizedFileURL
        model.isSaving = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            var lossless = false
            if inPlace, !adjusted, let turn, ImageExporter.reorient(url, quarterTurns: turn.quarterTurns, mirror: turn.mirror) {
                lossless = true
            } else if let original = ImageDecoder.full(url) {
                let isHDR = original.isHDR
                var picture = a.isNeutral
                    ? original.image
                    : LightRenderer.renderWhole(original.image, url: url, engine: engine, isHDR: isHDR, a, output: .linear,
                                                progress: { fraction in
                                                    DispatchQueue.main.async {
                                                        MainActor.assumeIsolated { self?.denoiseProgressed(fraction, full: true) }
                                                    }
                                                }, renderer: renderer)
                if let crop, let p = picture { picture = crop.apply(to: p) }
                if let turn, let p = picture { picture = ImageExporter.oriented(p, quarterTurns: turn.quarterTurns, mirror: turn.mirror) }
                var o = options
                if o.matchQuality, o.format == .jpeg, let q = JPEGQuality.setting(for: url) { o.quality = q }
                if let picture {
                    do { try ImageExporter.write(picture, isHDR: isHDR, original: url, to: dest, options: o) }
                    catch { failure = L(error.localizedDescription) }
                } else {
                    failure = L("The edit could not be rendered.")
                }
            } else {
                failure = L("The picture could not be read.")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.isSaving = false
                    if self.model.denoiseFull { self.denoiseFinished() }
                    if let failure {
                        self.showToast(L("Not saved: %@", failure), symbol: "exclamationmark.triangle", tone: .error)
                        cancelled?()
                        return
                    }
                    self.saved(url, to: dest, lossless: lossless, then: proceed)
                }
            }
        }
    }

    private func saved(_ url: URL, to dest: URL, lossless: Bool, then proceed: (() -> Void)?) {
        showToast(lossless ? L("Saved %@ · turned without re-encoding", dest.lastPathComponent) : L("Saved %@", dest.lastPathComponent),
                  symbol: "checkmark.circle", tone: .success)
        let sameFile = dest.standardizedFileURL == url.standardizedFileURL
        // The file changed under every cache.
        for changed in [url, dest] {
            store.forget(changed)
            probes.removeValue(forKey: changed.path)
            analyses.removeValue(forKey: changed.path)
            ThumbStore.shared.forget(changed)
        }
        let intoFolder = dest.deletingLastPathComponent().standardizedFileURL == model.folderURL?.standardizedFileURL
        if sameFile {
            // What is on disk now is the picture: shown from the file, upright as it says.
            lightSession?.renderer.cancelAll()
            lightSession = nil
            model.light = model.light.valuesReset
            canvas.clear(pane: 0)
        } else {
            setLight(model.light.valuesReset)
            endLight()
            resetOrientation()
        }
        updateDocumentEdited()
        if let proceed {
            proceed()
            rescanFolder()
        } else if let folder = model.folderURL {
            loadFolder(folder, selecting: sameFile || !intoFolder ? url : dest)
        }
    }
}
