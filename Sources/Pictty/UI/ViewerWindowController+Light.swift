// The Light panel's side of the conductor: one picture edited at a time, on screen only until it
// is saved. The edited pixels replace the picture's decodes on the canvas, so zoom, the settled
// Lanczos render, the loupe, the histogram and the clipping warnings all show the edit.

import AppKit
import PicttyCore
import SwiftUI
import UniformTypeIdentifiers

/// The picture as it was when editing began, to go back to.
final class LightSession {
    let renderer: LightRenderer
    let preview: CGImage
    var editedFullRequested = false

    init(renderer: LightRenderer, preview: CGImage) {
        self.renderer = renderer
        self.preview = preview
    }
}

extension ViewerWindowController {
    var hasUnsavedEdits: Bool { lightSession != nil && !model.light.isNeutral }

    /// The edited picture keeps its own pixels on the canvas.
    func keepsEdits(_ url: URL) -> Bool {
        lightSession?.renderer.url == url && !model.light.isNeutral
    }

    @objc func toggleLight(_ sender: Any?) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            model.showLight.toggle()
            if model.showLight { model.showInspector = false }
        }
        updateLightAvailability()
        revealChrome()
    }

    /// Why the picture on screen cannot be edited, or nil when it can.
    func updateLightAvailability() {
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

    /// The panel's sliders and buttons land here.
    func setLight(_ a: LightAdjustments) {
        let previous = model.light
        model.light = a
        guard model.lightUnavailable == nil, let url = model.current?.url, let shown = canvas.shown(pane: 0),
              shown.url == url else { return }
        if lightSession?.renderer.url != url {
            guard !a.isNeutral else { return }
            beginLight(url: url, shown: shown)
        }
        guard let session = lightSession else { return }
        if model.showingOriginal { model.showingOriginal = false }
        if a.isNeutral {
            session.renderer.cancelAll()
            if !previous.isNeutral { showOriginalPixels() }
            model.lightTiming = ""
            return
        }
        session.renderer.render(a) { [weak self] r in self?.lightRendered(r, url: url) }
    }

    private func beginLight(url: URL, shown: CanvasView.Shown) {
        guard var preview = shown.preview ?? shown.full else { return }
        // A full decode on screen is edited at screen size; zooming in renders every pixel.
        let limit = CGFloat(store.previewMaxPixel)
        let longest = CGFloat(max(preview.width, preview.height))
        if longest > limit * 1.5 {
            let k = limit / longest
            preview = Resampler.render(preview, from: CGRect(x: 0, y: 0, width: preview.width, height: preview.height),
                                       width: Int(CGFloat(preview.width) * k), height: Int(CGFloat(preview.height) * k)) ?? preview
        }
        let renderer = LightRenderer(url: url, preview: preview, isHDR: shown.isHDR, maxPixel: store.previewMaxPixel)
        lightSession = LightSession(renderer: renderer, preview: preview)
    }

    private func lightRendered(_ r: LightRenderer.Rendered, url: URL) {
        guard let session = lightSession, session.renderer.url == url, model.current?.url == url,
              r.adjustments == model.light, !model.showingOriginal else { return }
        session.editedFullRequested = false
        canvas.showEdited(r.image, full: false, pane: 0)
        let engine = session.renderer.engine == .pictty ? L("Pictty engine") : L("Apple RAW engine")
        model.lightTiming = String(format: "%@ · %.0f ms · %ld×%ld", engine, r.milliseconds, r.image.width, r.image.height)
        analyseEdit(r.image, url: url)
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
        session.editedFullRequested = true
        let a = model.light
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.lightSession === session, self.model.light == a, self.canvas.needsFull(url) else {
                session.editedFullRequested = false
                return
            }
            let render: (CGImage) -> Void = { original in
                session.renderer.renderFull(original, a) { [weak self] r in
                    guard let self, self.lightSession === session, self.model.light == r.adjustments,
                          !self.model.showingOriginal else { return }
                    self.canvas.showEdited(r.image, full: true, pane: 0)
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
        canvas.showEdited(session.preview, full: false, pane: 0)
        if let full = store.cached(url, full: true) { canvas.showEdited(full.image, full: true, pane: 0) }
        if let known = analyses[url.path] { publish(known.analysis, for: url) }
        updateStatus()
    }

    /// Before and after (\): the original while it is on, the edit again after.
    @objc func toggleOriginal(_ sender: Any?) {
        setShowingOriginal(!model.showingOriginal)
    }

    func setShowingOriginal(_ on: Bool) {
        guard hasUnsavedEdits, model.showingOriginal != on else { return }
        model.showingOriginal = on
        if on {
            lightSession?.renderer.cancelAll()
            showOriginalPixels()
        } else {
            setLight(model.light)
        }
    }

    /// Every slider back to zero; the algorithm choices stay.
    @objc func resetLight(_ sender: Any?) { setLight(model.light.valuesReset) }

    /// The picture changed: the edits go (settled before, if they had to be).
    func endLight() {
        lightSession?.renderer.cancelAll()
        lightSession = nil
        lightAnalysisTicket &+= 1
        model.light = model.light.valuesReset
        model.showingOriginal = false
        model.lightTiming = ""
    }

    // MARK: - Unsaved changes

    /// Runs `proceed` once the edits on screen are saved or let go; asks first if there are any.
    /// `cancelled` runs if the person keeps them on screen.
    func settleEdits(cancelled: (() -> Void)? = nil, then proceed: @escaping () -> Void) {
        guard hasUnsavedEdits, let window, let item = model.current else { return proceed() }
        if window.attachedSheet != nil { cancelled?(); return }
        let alert = NSAlert()
        alert.messageText = L("Save the changes to “%@”?", item.fileName)
        alert.informativeText = L("The Light adjustments are only on screen. If you don't save them, they're lost.")
        let inPlace = canSaveInPlace(item.url)
        alert.addButton(withTitle: inPlace ? L("Save") : L("Save As…"))
        alert.addButton(withTitle: L("Cancel"))
        let discard = alert.addButton(withTitle: L("Don't Save"))
        discard.hasDestructiveAction = true
        if inPlace { alert.addButton(withTitle: L("Save As…")) }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                inPlace ? self.saveInPlace(then: proceed, cancelled: cancelled) : self.saveAs(then: proceed, cancelled: cancelled)
            case .alertThirdButtonReturn:
                self.setLight(self.model.light.valuesReset)
                self.endLight()
                proceed()
            case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
                self.saveAs(then: proceed, cancelled: cancelled)
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

    @objc func saveEdits(_ sender: Any?) {
        guard let item = model.current, model.lightUnavailable == nil else { return }
        guard hasUnsavedEdits else { return showToast("Nothing to save: no adjustments", symbol: "slider.horizontal.3") }
        canSaveInPlace(item.url) ? saveInPlace(then: nil, cancelled: nil) : saveAs(then: nil, cancelled: nil)
    }

    @objc func saveEditsAs(_ sender: Any?) {
        guard model.current != nil, model.lightUnavailable == nil else { return }
        saveAs(then: nil, cancelled: nil)
    }

    private static let overwriteNoticeKey = "light.overwriteNoticeShown"

    private func saveInPlace(then proceed: (() -> Void)?, cancelled: (() -> Void)?) {
        guard let item = model.current, let window,
              let type = UTType(filenameExtension: item.url.pathExtension), let format = ExportFormat(fileType: type) else { return }
        let write = { [weak self] in
            guard let self else { return }
            var o = self.prefs.exportOptions
            o.format = format
            o.colorSpace = .original
            o.longEdge = nil
            o.metadata = .all
            o.depth = (self.canvas.shown(pane: 0)?.preview?.bitsPerComponent ?? 8) > 8 && format.depths.contains(.sixteen) ? .sixteen : .eight
            self.export(item.url, to: item.url, options: o, then: proceed, cancelled: cancelled)
        }
        // Once, the first time: Save replaces the original.
        guard !Preferences.store.bool(forKey: Self.overwriteNoticeKey) else { return write() }
        let alert = NSAlert()
        alert.messageText = L("Save replaces “%@”", item.fileName)
        alert.informativeText = L("The adjustments are written into the file itself and the original pixels are gone. To keep the original, use Save As (⇧⌘S).")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Don't tell me again")
        alert.beginSheetModal(for: window) { response in
            if alert.suppressionButton?.state == .on { Preferences.store.set(true, forKey: Self.overwriteNoticeKey) }
            response == .alertFirstButtonReturn ? write() : cancelled?()
        }
    }

    /// Save As: any format this Mac can write, every setting shown.
    func saveAs(then proceed: (() -> Void)?, cancelled: (() -> Void)?) {
        guard let item = model.current, let window else { return }
        let shown = canvas.shown(pane: 0)
        let settings = ExportSettings(options: prefs.exportOptions, isHDR: shown?.isHDR ?? false,
                                      hasAlpha: shown?.hasAlpha ?? false, pixelSize: shown?.pixelSize ?? .zero,
                                      edited: hasUnsavedEdits)
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
            self.export(item.url, to: dest, options: settings.options, then: proceed, cancelled: cancelled)
        }
    }

    /// Renders every pixel with the Light values and writes it, off the main thread.
    private func export(_ url: URL, to dest: URL, options: ExportOptions, then proceed: (() -> Void)?,
                        cancelled: (() -> Void)?) {
        let a = model.light
        let edited = hasUnsavedEdits
        let engine = lightSession?.renderer.engine ?? (ImageFormats.isRaw(url) ? .appleRAW : .pictty)
        model.isSaving = true
        showToast(edited ? "Saving…" : "Converting…", symbol: "square.and.arrow.down")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            if let original = ImageDecoder.full(url) {
                let isHDR = original.isHDR
                let picture = edited
                    ? LightRenderer.renderWhole(original.image, url: url, engine: engine, isHDR: isHDR, a, output: .linear)
                    : original.image
                if let picture {
                    do { try ImageExporter.write(picture, isHDR: isHDR, original: url, to: dest, options: options) }
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
                    if let failure {
                        self.showToast(L("Not saved: %@", failure), symbol: "exclamationmark.triangle", tone: .error)
                        cancelled?()
                        return
                    }
                    self.saved(url, to: dest, then: proceed)
                }
            }
        }
    }

    private func saved(_ url: URL, to dest: URL, then proceed: (() -> Void)?) {
        showToast(L("Saved %@", dest.lastPathComponent), symbol: "checkmark.circle", tone: .success)
        let sameFile = dest.standardizedFileURL == url.standardizedFileURL
        // The file changed under every cache; the edited pixels on screen are what it holds now.
        for changed in [url, dest] {
            store.forget(changed)
            probes.removeValue(forKey: changed.path)
            analyses.removeValue(forKey: changed.path)
            ThumbStore.shared.forget(changed)
        }
        let intoFolder = dest.deletingLastPathComponent().standardizedFileURL == model.folderURL?.standardizedFileURL
        if sameFile {
            lightSession?.renderer.cancelAll()
            lightSession = nil
            model.light = model.light.valuesReset
        } else {
            setLight(model.light.valuesReset)
            endLight()
        }
        if let proceed {
            proceed()
            rescanFolder()
        } else if let folder = model.folderURL {
            loadFolder(folder, selecting: sameFile || !intoFolder ? url : dest)
        }
    }
}
