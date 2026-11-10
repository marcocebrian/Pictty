// Image Size: the picture resampled to a size in pixels, percent, centimetres or inches, with Pictty's
// one method (Lanczos, shrinking in linear light). It is not Enlarge: no new detail is made, and
// the dialog says so when the picture grows. An edit like the others, last of all, before a turn.

import AppKit
import ImageIO
import PicttyCore
import SwiftUI

extension ViewerWindowController {
    /// The picture's size before Image Size: as cropped and enlarged.
    var sizeBeforeResize: CGSize? {
        guard let shown = canvas.shown(pane: 0), shown.url == model.current?.url else { return nil }
        let base = lightSession.map { $0.renderer.url == shown.url ? $0.pixelSize : shown.pixelSize } ?? shown.pixelSize
        return EnlargeRule.outputSize(model.crop?.croppedSize(base) ?? base, factor: model.enlarge ?? 1)
    }

    @objc func showImageSize(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, let item = model.current, let base = sizeBeforeResize else { return }
        if model.cropping { commitCrop() }
        let ppi = Self.resolution(of: item.url)
        var sheet: NSWindow?
        let view = ImageSizeView(original: base, current: model.resize ?? base, ppi: ppi, enlargeOffered: offersEnlarge,
                                 done: { [weak self] size in
                                     if let sheet { window.endSheet(sheet) }
                                     if let size { self?.setResize(size == base ? nil : size) }
                                 })
        let host = NSHostingController(rootView: view)
        let s = NSWindow(contentViewController: host)
        s.styleMask = [.titled]
        s.title = L("Resize")
        sheet = s
        window.beginSheet(s)
    }

    func setResize(_ size: CGSize?) {
        guard size != model.resize else { return }
        if let size, !ImageSizeMath.isValid(size) { return }
        if model.showingOriginal { setShowingOriginal(false) }
        model.resize = size
        refreshEdit()
        applyZoom(animated: true)
        fitWindowToPicture(animated: true)
        updateDocumentEdited()
    }

    /// A new crop or Enlarge: the size set for the old picture no longer fits it.
    func resizeNoLongerFits() {
        guard model.resize != nil else { return }
        model.resize = nil
        showToast(L("Resize undone: the picture's shape or size changed"), symbol: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
    }

    /// The file's own pixels per inch, or 72.
    static func resolution(of url: URL) -> Double {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi > 0 else { return 72 }
        return dpi
    }
}

/// The standard Image Size sheet: Fit into, Width and Height in a unit, Resolution, Scale
/// proportionally, the size it makes, and how it is done (one method, said, not chosen).
struct ImageSizeView: View {
    let original: CGSize
    let ppi: Double
    let enlargeOffered: Bool
    let done: (CGSize?) -> Void

    @State private var width: Double
    @State private var height: Double
    @State private var unit: ImageSizeMath.Unit = .pixels
    @State private var resolution: Double
    @State private var proportional = true
    @State private var preset = 0

    private static let presets: [(String, CGSize)] = [
        ("640 × 480", CGSize(width: 640, height: 480)), ("800 × 600", CGSize(width: 800, height: 600)),
        ("1024 × 768", CGSize(width: 1024, height: 768)), ("1280 × 1024", CGSize(width: 1280, height: 1024)),
        ("1920 × 1080 (Full HD)", CGSize(width: 1920, height: 1080)), ("2560 × 1440", CGSize(width: 2560, height: 1440)),
        ("3840 × 2160 (4K)", CGSize(width: 3840, height: 2160)),
    ]

    init(original: CGSize, current: CGSize, ppi: Double, enlargeOffered: Bool, done: @escaping (CGSize?) -> Void) {
        self.original = original
        self.ppi = ppi
        self.enlargeOffered = enlargeOffered
        self.done = done
        _width = State(initialValue: current.width)
        _height = State(initialValue: current.height)
        _resolution = State(initialValue: ppi)
    }

    /// The size in pixels the fields make.
    private var target: CGSize {
        CGSize(width: ImageSizeMath.pixels(width, unit: unit, base: original.width, ppi: resolution).rounded(),
               height: ImageSizeMath.pixels(height, unit: unit, base: original.height, ppi: resolution).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Fit into:").gridColumnAlignment(.trailing)
                    Picker("", selection: $preset) {
                        Text("Custom").tag(0)
                        ForEach(Self.presets.indices, id: \.self) { i in Text(Self.presets[i].0).tag(i + 1) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: preset) { _, p in
                        guard p > 0 else { return }
                        let s = ImageSizeMath.fit(original, into: Self.presets[p - 1].1)
                        proportional = true
                        unit = .pixels
                        width = s.width; height = s.height
                    }
                }
                GridRow {
                    Text("Width:")
                    HStack {
                        field($width) { w in
                            guard proportional else { return }
                            let px = ImageSizeMath.pixels(w, unit: unit, base: original.width, ppi: resolution)
                            height = ImageSizeMath.value(px * original.height / original.width, unit: unit, base: original.height, ppi: resolution)
                        }
                        Picker("", selection: $unit) {
                            Text("pixels").tag(ImageSizeMath.Unit.pixels)
                            Text("percent").tag(ImageSizeMath.Unit.percent)
                            Text("cm").tag(ImageSizeMath.Unit.centimetres)
                            Text("inches").tag(ImageSizeMath.Unit.inches)
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        .onChange(of: unit) { old, new in
                            let w = ImageSizeMath.pixels(width, unit: old, base: original.width, ppi: resolution)
                            let h = ImageSizeMath.pixels(height, unit: old, base: original.height, ppi: resolution)
                            width = ImageSizeMath.value(w, unit: new, base: original.width, ppi: resolution)
                            height = ImageSizeMath.value(h, unit: new, base: original.height, ppi: resolution)
                        }
                    }
                }
                GridRow {
                    Text("Height:")
                    field($height) { h in
                        guard proportional else { return }
                        let px = ImageSizeMath.pixels(h, unit: unit, base: original.height, ppi: resolution)
                        width = ImageSizeMath.value(px * original.width / original.height, unit: unit, base: original.width, ppi: resolution)
                    }
                }
                GridRow {
                    Text("Resolution:")
                    HStack {
                        TextField("", value: $resolution, format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                        Text("pixels/inch").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle("Scale proportionally", isOn: $proportional)
                }
            }

            Divider()

            let t = target, valid = ImageSizeMath.isValid(t), method = ImageSizeMath.method(from: original, to: t)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Now:") {
                    Text(verbatim: "\(Int(original.width)) × \(Int(original.height)) · " + megapixels(original))
                }
                LabeledContent("New size:") {
                    Text(verbatim: valid ? "\(Int(t.width)) × \(Int(t.height)) · " + megapixels(t) : "—")
                        .foregroundStyle(valid ? .primary : Color.red)
                }
                .fontWeight(.semibold)
                Label {
                    Text(methodText(method))
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if method == .enlarge {
                    Label(enlargeOffered ? "Resize makes the picture bigger, not more detailed. For new detail, use AI Enlarge 2× or 4× (Edit menu)."
                                         : "Resize makes the picture bigger, not more detailed.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !valid {
                    Label("Too large: up to 32 768 pixels a side and 300 MP.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .monospacedDigit()

            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Resize") { done(t) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func field(_ value: Binding<Double>, changed: @escaping (Double) -> Void) -> some View {
        TextField("", value: Binding(get: { value.wrappedValue }, set: { v in
            value.wrappedValue = v
            preset = 0
            changed(v)
        }), format: .number.precision(.fractionLength(0...2)))
        .frame(width: 90)
        .multilineTextAlignment(.trailing)
    }

    private func megapixels(_ s: CGSize) -> String { String(format: "%.1f MP", s.width * s.height / 1_000_000) }

    private func methodText(_ m: ImageSizeMath.Method) -> LocalizedStringKey {
        switch m {
        case .shrink: "Lanczos, in linear light: the sharpest classic way to shrink. Fine detail and colours stay true."
        case .enlarge: "Lanczos: the sharpest classic way to enlarge. Clean edges, no blur."
        case .same: "The picture stays as it is."
        }
    }
}
