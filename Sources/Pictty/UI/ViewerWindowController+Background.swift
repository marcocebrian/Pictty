// Remove background: macOS finds the subjects; behind them, transparency, white, black, a colour or
// the background blurred. An edit like the others: after the adjustments, before the crop.

import AppKit
import PicttyCore

extension ViewerWindowController {
    var offersBackground: Bool { model.current != nil && !model.isComparing && model.lightUnavailable == nil }

    /// The strip's fills and Off.
    func setBackground(_ fill: BackgroundFill?) {
        guard fill != model.background, fill == nil || offersBackground else { return }
        if let session = lightSession, session.renderer.url == model.current?.url, session.noSubject, fill != nil {
            return showToast(L("No subject found to keep"), symbol: "person.crop.circle.badge.questionmark")
        }
        if model.showingOriginal { setShowingOriginal(false) }
        model.background = fill
        stopStaleEnlarging()
        refreshEdit()
        updateDocumentEdited()
    }

    /// Edit ▸ Remove Background: the toolbar's strip.
    @objc func showBackground(_ sender: Any?) {
        guard offersBackground else { return }
        revealChrome()
        model.backgroundPickerOpen = true
    }

    /// Colour…: the standard colour panel; the fill follows it.
    func pickBackgroundColour() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(backgroundColourPicked(_:)))
        panel.showsAlpha = false
        if case let .colour(r, g, b) = model.background { panel.color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        panel.orderFront(nil)
    }

    @objc func backgroundColourPicked(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        setBackground(.colour(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
    }

    /// `image` (the edit before the crop) with its background replaced, if the mask for its size is
    /// made; otherwise as it is, and the mask is asked for (the edit is shown again when it comes).
    func withBackground(_ image: CGImage, session: LightSession) -> CGImage {
        guard let fill = model.background else { return image }
        let key = "\(image.width)x\(image.height)"
        if let mask = session.masks[key] {
            return BackgroundComposite.apply(image, mask: mask, fill: fill) ?? image
        }
        guard !session.noSubject, session.masking.insert(key).inserted else { return image }
        model.maskWorking = true
        let url = session.renderer.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SubjectMask.make(for: image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    session.masking.remove(key)
                    if session.masking.isEmpty { self.model.maskWorking = false }
                    guard self.lightSession === session, self.model.current?.url == url else { return }
                    switch result {
                    case let .found(mask):
                        session.masks[key] = mask
                        self.refreshEdit()
                    case .noSubject, .failed:
                        session.noSubject = true
                        self.model.background = nil
                        self.showToast(L("No subject found to keep"), symbol: "person.crop.circle.badge.questionmark")
                        self.refreshEdit()
                        self.updateDocumentEdited()
                    }
                }
            }
        }
        return image
    }

    /// For Save, Print and Copy, off the main thread: every pixel with its background replaced.
    nonisolated static func withBackground(_ image: CGImage, fill: BackgroundFill) -> CGImage {
        guard case let .found(mask) = SubjectMask.make(for: image) else { return image }
        return BackgroundComposite.apply(image, mask: mask, fill: fill) ?? image
    }
}
