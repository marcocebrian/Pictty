// Cropping: C (or the toolbar's crop button) shows the whole picture with room around it, the crop
// frame on it, and the crop toolbar under it. Return or Done keeps the crop, Esc or Cancel leaves
// the picture as it was. The crop is an edit like the others: on screen until saved.

import AppKit
import PicttyCore
import SwiftUI

extension ViewerWindowController {
    @objc func toggleCrop(_ sender: Any?) {
        model.cropping ? commitCrop() : startCrop()
    }

    func startCrop() {
        guard !model.cropping, model.lightUnavailable == nil, model.current != nil else { return }
        if model.showingOriginal { setShowingOriginal(false) }
        model.pickingWhite = false
        canvas.picking = false
        model.cropDraft = model.crop ?? CropBox()
        model.cropRounded = model.cropDraft.isRounded
        model.cropping = true
        refreshEdit()
        frameForCropping()
        syncCropChrome()
    }

    /// Done: the crop stays (none, if it is the whole picture with square corners).
    func commitCrop() {
        guard model.cropping else { return }
        let draft = model.cropDraft
        model.crop = draft.isWhole ? nil : draft
        model.cropping = false
        refreshEdit()
        applyZoom(animated: true)
        fitWindowToPicture(animated: true)
        syncCropChrome()
        updateDocumentEdited()
    }

    /// Esc: the picture as it was before cropping began.
    func cancelCrop() {
        guard model.cropping else { return }
        model.cropping = false
        refreshEdit()
        applyZoom(animated: true)
        fitWindowToPicture(animated: true)
        syncCropChrome()
    }

    /// The whole picture, a little smaller than the window, so every handle can be reached and the
    /// toolbar does not cover the bottom edge.
    private func frameForCropping() {
        guard let fit = canvas.fitScale(pane: 0) else { return }
        var vp = canvas.viewport(pane: 0)
        vp.scale = fit * 0.8
        vp.center = CGPoint(x: 0.5, y: 0.47)
        canvas.setViewport(vp, pane: 0, animated: false)
        updateZoomLabel()
        updateCropOverlay()
    }

    // MARK: - Ratio and corners

    /// The ratio on screen, width over height, or nil for free.
    var cropRatioValue: Double? {
        guard var r = model.cropRatio.value else { return nil }
        if r == 0, let o = canvas.orientedSize(pane: 0), o.height > 0 { r = o.width / o.height }
        return model.cropRatioTurned ? 1 / r : r
    }

    func setCropRatio(_ ratio: CropRatio) {
        model.cropRatio = ratio
        model.cropRatioTurned = false
        refitCrop()
    }

    /// X: a landscape ratio made portrait, or the other way.
    @objc func turnCropRatio(_ sender: Any?) {
        guard model.cropping, let r = model.cropRatio.value, r != 1 else { return }
        model.cropRatioTurned.toggle()
        refitCrop()
    }

    private func refitCrop() {
        guard let o = canvas.orientedSize(pane: 0) else { return }
        let vp = canvas.viewport(pane: 0)
        model.cropDraft = CropOverlayView.fitted(model.cropDraft, ratio: cropRatioValue,
                                                 orient: Orient(quarterTurns: vp.rotation, mirror: vp.mirror), displayPixels: o)
        updateCropOverlay()
    }

    /// R: rounded corners on or off. On starts from a gentle radius.
    @objc func toggleCropRounded(_ sender: Any?) {
        guard model.cropping else { return }
        model.cropRounded.toggle()
        model.cropDraft.radii = Array(repeating: model.cropRounded ? 0.08 : 0, count: 4)
        updateCropOverlay()
    }

    /// The toolbar's slider: every corner to one radius.
    func setCropRadius(_ value: Double) {
        model.cropDraft.radii = Array(repeating: min(max(value, 0), 0.5), count: 4)
        if !model.cropRounded { model.cropRounded = true }
        updateCropOverlay()
    }

    func toggleCropLinked() {
        model.cropLinkedCorners.toggle()
        if model.cropLinkedCorners, let most = model.cropDraft.radii.max() {
            model.cropDraft.radii = Array(repeating: most, count: 4)
        }
        updateCropOverlay()
    }

    @objc func resetCrop(_ sender: Any?) {
        model.cropDraft = CropBox()
        model.cropRatio = .free
        model.cropRatioTurned = false
        model.cropRounded = false
        updateCropOverlay()
    }

    // MARK: - Chrome

    /// The overlay follows the picture: after any layout, zoom or turn.
    func updateCropOverlay() {
        guard let overlay = cropOverlay else { return }
        overlay.isHidden = !model.cropping
        guard model.cropping else { return }
        overlay.frame = canvas.frame
        if let frame = canvas.pictureFrame(pane: 0) { overlay.pictureFrame = frame }
        let vp = canvas.viewport(pane: 0)
        overlay.orient = Orient(quarterTurns: vp.rotation, mirror: vp.mirror)
        overlay.displayPixels = canvas.orientedSize(pane: 0) ?? .zero
        overlay.ratio = cropRatioValue
        overlay.rounded = model.cropRounded
        overlay.linkedCorners = model.cropLinkedCorners
        overlay.box = model.cropDraft
        overlay.needsDisplay = true
        // Diagnostics: `PICTTY_CROPDUMP=<path>` saves the frame as drawn, which window snapshots miss.
        if let path = ProcessInfo.processInfo.environment["PICTTY_CROPDUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { return }
                overlay.cacheDisplay(in: overlay.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func syncCropChrome() {
        updateCropOverlay()
        syncChrome()
        if model.cropping { window?.makeFirstResponder(canvas) }
    }

    /// Keys while cropping; true when handled. Anything that would leave the picture is held back.
    func handleCropKey(_ event: NSEvent, chars: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard model.cropping else { return false }
        if flags.contains(.command) { return false }
        switch event.keyCode {
        case 53: cancelCrop(); return true
        case 36, 76: commitCrop(); return true
        default: break
        }
        switch chars {
        case "c", "C": commitCrop()
        case "x", "X": turnCropRatio(nil)
        case "r", "R": toggleCropRounded(nil)
        default: break
        }
        return true
    }
}

// MARK: - The crop toolbar

/// The floating toolbar while cropping: ratio, rounded corners, reset, Cancel and Done.
struct CropToolbarView: View {
    @ObservedObject var model: ViewerModel
    let controller: ViewerWindowController

    private var radius: Double { model.cropDraft.radii.max() ?? 0 }

    var body: some View {
        HStack(spacing: 4) {
            ratioMenu
            GlyphButton(symbol: model.cropRatioTurned ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate",
                        help: "Turn the ratio (X)", isOn: model.cropRatioTurned) { controller.turnCropRatio(nil) }
                .disabled(model.cropRatio.value == nil || model.cropRatio.value == 1)
                .opacity(model.cropRatio.value == nil || model.cropRatio.value == 1 ? 0.35 : 1)

            separator

            GlyphButton(symbol: "app", help: "Rounded corners (R)", isOn: model.cropRounded) { controller.toggleCropRounded(nil) }
            if model.cropRounded {
                Slider(value: Binding(get: { radius }, set: { controller.setCropRadius($0) }), in: 0...0.5)
                    .controlSize(.mini)
                    .frame(width: 90)
                    .help(L("Corner radius, all four"))
                Text("\(Int((radius * 200).rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 34, alignment: .leading)
                GlyphButton(symbol: model.cropLinkedCorners ? "link" : "link.badge.plus",
                            help: model.cropLinkedCorners ? "All corners together · click for one at a time (⌥ while dragging)"
                                                          : "One corner at a time · click to link them",
                            isOn: model.cropLinkedCorners) { controller.toggleCropLinked() }
            }

            separator

            GlyphButton(symbol: "arrow.counterclockwise", help: "Whole picture, square corners") { controller.resetCrop(nil) }

            separator

            Button { controller.cancelCrop() } label: {
                Text("Cancel")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(L("Esc"))
            Button { controller.commitCrop() } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0xFBBC04), Color(hex: 0xF57C3B)],
                                                              startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .foregroundStyle(.black.opacity(0.85))
                    .shadow(color: Color(hex: 0xFBBC04).opacity(0.5), radius: 6)
            }
            .buttonStyle(.plain)
            .help(L("Return"))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize()
        .liquidGlassCapsule(tint: 0.5, shadow: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.cropRounded)
    }

    private var ratioMenu: some View {
        Menu {
            ForEach(Array(CropRatio.groups.enumerated()), id: \.offset) { _, group in
                Section(group.title.isEmpty ? "" : L(group.title)) {
                    ForEach(group.ratios) { ratio in
                        Button {
                            controller.setCropRatio(ratio)
                        } label: {
                            if ratio == model.cropRatio { Image(systemName: "checkmark") }
                            Text(ratio.detail.isEmpty ? L(ratio.name) : "\(L(ratio.name))  ·  \(L(ratio.detail))")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "aspectratio")
                Text(L(model.cropRatio.name))
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .help(L("Aspect ratio"))
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 0.5, height: 16)
            .padding(.horizontal, 5)
    }
}
