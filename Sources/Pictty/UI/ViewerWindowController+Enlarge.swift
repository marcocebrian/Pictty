// Enlarge: the learned 2× / 4× enlargement, the last pixel edit (after the adjustments and the crop,
// before a turn). On screen, while the whole picture fits, the screen-sized edit stands in for it:
// at that size the network and a plain enlargement look the same. Zoomed in past it, every pixel of
// the edit is shown enlarged plainly at once (the canvas's Lanczos), and the network's enlargement
// replaces it when it is done, kept while the edit stays as it is.

import AppKit
import PicttyCore

/// What an enlargement was made from: it is good while these are what they were.
struct EnlargeKey: Equatable {
    let light: Adjustments
    let crop: CropBox?
    let factor: Int
}

/// One run of the network, stopped by `cancel()` from the main thread.
final class EnlargeRun: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    let key: EnlargeKey

    init(key: EnlargeKey) { self.key = key }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

extension ViewerWindowController {
    /// Why the picture on screen, as cropped, cannot be enlarged; nil if it can.
    var enlargeRefusal: EnlargeRule.Refusal? {
        guard let shown = canvas.shown(pane: 0) else { return nil }
        let base = lightSession.map { $0.renderer.url == shown.url ? $0.pixelSize : shown.pixelSize } ?? shown.pixelSize
        return EnlargeRule.refusal(pixelSize: model.crop?.croppedSize(base) ?? base, isHDR: shown.isHDR)
    }

    /// Enlarge can be offered at all: the network is in the app, one picture is on screen and editable.
    var offersEnlarge: Bool {
        NeuralUpscaler.shared.isAvailable && model.current != nil && !model.isComparing && model.lightUnavailable == nil
    }

    static func refusalText(_ r: EnlargeRule.Refusal) -> String {
        switch r {
        case .tooLarge: L("Enlarge works on pictures up to 8 MP: crop this one first")
        case .hdr: L("Enlarge is not available for HDR pictures")
        }
    }

    /// The strip's 2×, 4× and Off.
    func setEnlarge(_ factor: Int?) {
        guard factor != model.enlarge else { return }
        if let factor {
            guard offersEnlarge, EnlargeRule.factors.contains(factor) else { return }
            if let r = enlargeRefusal { return showToast(Self.refusalText(r), symbol: "exclamationmark.triangle") }
            NeuralUpscaler.shared.warmUp()
        }
        if model.showingOriginal { setShowingOriginal(false) }
        stopEnlarging()
        model.enlarge = factor
        refreshEdit()
        applyZoom(animated: true)
        fitWindowToPicture(animated: true)
        updateDocumentEdited()
    }

    /// The menu's Enlarge: the toolbar's strip, or why this picture cannot be enlarged.
    @objc func showEnlarge(_ sender: Any?) {
        if let r = enlargeRefusal { return showToast(Self.refusalText(r), symbol: "exclamationmark.triangle") }
        revealChrome()
        NeuralUpscaler.shared.warmUp()
        model.enlargePickerOpen = true
    }

    /// A new crop: past 8 MP, the enlargement goes, with a word why.
    func enlargeCropChanged() {
        guard model.enlarge != nil, enlargeRefusal == .tooLarge else { return }
        stopEnlarging()
        model.enlarge = nil
        showToast(L("Enlarge turned off: the crop is over 8 MP"), symbol: "arrow.down.right.and.arrow.up.left")
    }

    func stopEnlarging() {
        enlargeRun?.cancel()
        enlargeRun = nil
        if model.enlargeProgress != nil { model.enlargeProgress = nil }
    }

    /// Every pixel of the edit on the canvas; with Enlarge on, the network's enlargement follows.
    func presentFull(_ image: CGImage, session: LightSession) {
        present(image, full: true, session: session)
        guard let factor = model.enlarge, !model.cropping, !model.showingOriginal else { return }
        let key = EnlargeKey(light: model.light, crop: model.crop, factor: factor)
        if let done = session.enlarged, done.key == key { return showEnlarged(done.image, session: session) }
        if let run = enlargeRun, run.key == key, !run.isCancelled { return }
        stopEnlarging()
        let run = EnlargeRun(key: key)
        enlargeRun = run
        let url = session.renderer.url
        let source = key.crop?.apply(to: image) ?? image
        // A moment's wait: a slider still moving would only start it over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.enlargeRun === run, !run.isCancelled else { return }
            self.enlargeProgressed(0)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let start = CFAbsoluteTimeGetCurrent()
                let big = NeuralUpscaler.shared.enlarge(source, factor: factor, cancelled: { run.isCancelled }, progress: { f in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.enlargeRun === run else { return }
                            self.enlargeProgressed(f)
                        }
                    }
                })
                let seconds = CFAbsoluteTimeGetCurrent() - start
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.enlargeRun === run else { return }
                        self.enlargeRun = nil
                        guard let big, !run.isCancelled, self.lightSession === session, self.model.current?.url == url,
                              self.model.enlarge == factor, self.model.light == key.light, self.model.crop == key.crop,
                              !self.model.cropping else {
                            self.model.enlargeProgress = nil
                            return
                        }
                        session.enlarged = (key, big)
                        self.enlargeFinished()
                        if !self.model.showingOriginal { self.showEnlarged(big, session: session) }
                        self.showToast(L("Enlarged %ld× · %@ → %@ · %.1f s", factor, "\(source.width)×\(source.height)",
                                         "\(big.width)×\(big.height)", seconds), symbol: "arrow.up.left.and.arrow.down.right")
                    }
                }
            }
        }
    }

    private func showEnlarged(_ image: CGImage, session: LightSession) {
        let size = CGSize(width: image.width, height: image.height)
        canvas.showEdited(Self.screenCopy(image), full: true, pane: 0, pixelSize: size,
                          hasAlpha: session.hasAlpha || model.crop?.isRounded == true)
        updateStatus()
    }

    /// The network's progress, for the canvas's badge: under way, then a moment of done.
    func enlargeProgressed(_ fraction: Double) {
        model.enlargeDone = false
        model.enlargeProgress = fraction
    }

    func enlargeFinished() {
        model.enlargeProgress = nil
        model.enlargeDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.model.enlargeDone = false }
    }
}
