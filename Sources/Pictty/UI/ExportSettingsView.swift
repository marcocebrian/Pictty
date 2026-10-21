// Save As and Convert: every setting in plain sight under the file name, nothing behind a
// disclosure. The formats are cards with their own badge and what each can hold; the settings
// that apply to the chosen one follow, each with its icon; the foot says how big the file will
// be, measured by encoding a sample of the picture, not guessed.
//
// It lives in the system save panel, so it follows the panel's light or dark appearance.

import PicttyCore
import SwiftUI

@MainActor
final class ExportSettings: ObservableObject {
    @Published var options: ExportOptions {
        didSet {
            if options.format != oldValue.format {
                if !options.format.depths.contains(options.depth) { options.depth = options.format.depths[0] }
                onFormatChange?(options.format)
            }
            if options != oldValue { scheduleEstimate() }
        }
    }
    let isHDR: Bool
    let hasAlpha: Bool
    let pixelSize: CGSize
    let edited: Bool
    /// The picture as it will be saved, at screen size: what the size estimate encodes.
    let sample: CGImage?
    var onFormatChange: ((ExportFormat) -> Void)?

    /// Bytes, once measured.
    @Published private(set) var estimate: Int?
    private var estimateTicket = 0
    private var sampleSmall: CGImage?

    init(options: ExportOptions, isHDR: Bool, hasAlpha: Bool, pixelSize: CGSize, edited: Bool, sample: CGImage? = nil) {
        var o = options
        if !ExportFormat.writable.contains(o.format) { o.format = .jpeg }
        self.options = o
        self.isHDR = isHDR
        self.hasAlpha = hasAlpha
        self.pixelSize = pixelSize
        self.edited = edited
        self.sample = sample
        scheduleEstimate()
    }

    /// What the file will measure, after any resize.
    var outputSize: CGSize {
        guard let edge = options.longEdge, edge > 0, max(pixelSize.width, pixelSize.height) > CGFloat(edge) else { return pixelSize }
        let k = CGFloat(edge) / max(pixelSize.width, pixelSize.height)
        return CGSize(width: (pixelSize.width * k).rounded(), height: (pixelSize.height * k).rounded())
    }

    /// Encodes a sample of up to a megapixel with the settings and scales the bytes to the output size.
    private func scheduleEstimate() {
        guard let sample else { return }
        estimateTicket += 1
        let ticket = estimateTicket
        let options = options, isHDR = isHDR, output = outputSize
        let small = sampleSmall
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12) { [weak self] in
            var reduced = small
            if reduced == nil {
                let k = min(1, 1024 / Double(max(sample.width, sample.height)))
                let w = max(1, Int(Double(sample.width) * k)), h = max(1, Int(Double(sample.height) * k))
                reduced = k < 1 ? Resampler.render(sample, from: CGRect(x: 0, y: 0, width: sample.width, height: sample.height),
                                                   width: w, height: h) : sample
            }
            guard let reduced, let bytes = ImageExporter.encodedSize(reduced, isHDR: isHDR, options: options) else { return }
            let scale = Double(output.width * output.height) / Double(max(reduced.width * reduced.height, 1))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, ticket == self.estimateTicket else { return }
                    self.sampleSmall = reduced
                    self.estimate = Int(Double(bytes) * scale)
                }
            }
        }
    }
}

struct ExportSettingsView: View {
    @ObservedObject var settings: ExportSettings

    private static let edges = [7680, 6000, 4096, 3840, 2560, 2048, 1600, 1080]
    private var o: ExportOptions { settings.options }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            formats
            about
            Divider()
            rows
            Divider()
            foot
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: 640, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: o.format)
    }

    // MARK: Formats

    private var formats: some View {
        HStack(spacing: 8) {
            ForEach(ExportFormat.writable) { format in
                FormatCard(format: format, selected: format == o.format) { settings.options.format = format }
            }
        }
    }

    private var about: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L(o.format.summary))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                ForEach(o.format.abilities, id: \.self) { Chip(text: L($0)) }
            }
            .fixedSize()
        }
    }

    // MARK: Settings

    private var rows: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            if o.format.isLossy {
                row("Quality", "dial.medium", [0x4285F4, 0x34A8F0]) {
                    HStack(spacing: 10) {
                        Slider(value: $settings.options.quality, in: 0.1...1)
                            .frame(width: 230)
                        Text("\(Int((o.quality * 100).rounded()))")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                        Text(qualityHint)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
            if o.format.depths.count > 1 {
                row("Bit depth", "square.stack.3d.up", [0xA05CE0, 0x7B61FF]) {
                    Picker("", selection: $settings.options.depth) {
                        ForEach(o.format.depths) { Text(L($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if settings.isHDR, o.format.carriesHDR {
                row("HDR", "sun.max.fill", [0xFBBC04, 0xF57C3B]) {
                    Picker("", selection: $settings.options.hdr) {
                        ForEach(ExportHDR.allCases) { Text(L($0.title)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            row("Colour profile", "paintpalette.fill", [0xEA4335, 0xA05CE0]) {
                Picker("", selection: $settings.options.colorSpace) {
                    ForEach(ExportColorSpace.allCases) { Text(L($0.title)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(settings.isHDR && o.format.carriesHDR && o.hdr != .sdr || o.format.isSceneLinear)
            }
            row("Size", "arrow.up.left.and.arrow.down.right", [0x34A853, 0x00ACC1]) {
                HStack(spacing: 10) {
                    Picker("", selection: $settings.options.longEdge) {
                        Text("Original").tag(Int?.none)
                        ForEach(Self.edges.filter { CGFloat($0) < max(settings.pixelSize.width, settings.pixelSize.height) }, id: \.self) {
                            Text(L("%ld px long edge", $0)).tag(Int?.some($0))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(L("%ld × %ld px", Int(settings.outputSize.width), Int(settings.outputSize.height)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            row("Metadata", "tag.fill", [0x607D8B, 0x455A64]) {
                Picker("", selection: $settings.options.metadata) {
                    ForEach(ExportMetadata.allCases) { Text(L($0.title)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if o.format == .tiff {
                row("Compression", "archivebox.fill", [0x795548, 0x5D4037]) {
                    Picker("", selection: $settings.options.compression) {
                        ForEach(ExportCompression.allCases) { Text(L($0.title)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if !o.format.keepsAlpha, settings.hasAlpha {
                row("Transparency", "checkerboard.rectangle", [0x9E9E9E, 0x616161]) {
                    Picker("", selection: $settings.options.matteWhite) {
                        Text("On white").tag(true)
                        Text("On black").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if [.jpeg, .heic].contains(o.format) {
                row("Options", "slider.horizontal.3", [0x4285F4, 0x6A4CE0]) {
                    HStack(spacing: 16) {
                        if o.format == .jpeg { Toggle("Progressive", isOn: $settings.options.progressive) }
                        Toggle("Embed a thumbnail", isOn: $settings.options.embedThumbnail)
                    }
                }
            }
        }
    }

    private var foot: some View {
        HStack(alignment: .center, spacing: 12) {
            FormatBadge(format: o.format, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let bytes = settings.estimate {
                        Text("≈ " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                            .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                    } else {
                        Text("…").font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    Text(L("%ld × %ld px", Int(settings.outputSize.width), Int(settings.outputSize.height)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Label(settings.edited ? L("The edits are applied to every pixel.")
                                      : L("No edits: a straight conversion, the pixels upright."),
                      systemImage: settings.edited ? "slider.horizontal.3" : "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.2), value: settings.estimate)
    }

    private var qualityHint: String {
        switch o.quality {
        case ..<0.5: L("small file")
        case ..<0.8: L("balanced")
        case ..<0.95: L("high")
        default: L("near lossless")
        }
    }

    private func row<Content: View>(_ title: String, _ symbol: String, _ colors: [UInt32],
                                    @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)))
                Text(L(title))
            }
            .gridColumnAlignment(.leading)
            content()
        }
    }
}

// MARK: - Format cards

private struct FormatCard: View {
    let format: ExportFormat
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                FormatBadge(format: format, size: 40)
                    .scaleEffect(selected ? 1.06 : 1)
                Text(format.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.05) : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L(format.summary))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
    }
}

/// A document with a folded corner in the format's own colour, its name on it.
struct FormatBadge: View {
    let format: ExportFormat
    var size: CGFloat = 40

    var body: some View {
        let w = size * 0.8, h = size
        ZStack(alignment: .bottom) {
            DogEar(fold: w * 0.3)
                .fill(LinearGradient(colors: format.colours.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom))
                .shadow(color: Color(hex: format.colours[1]).opacity(0.35), radius: 3, y: 1)
            DogEar(fold: w * 0.3)
                .stroke(.white.opacity(0.25), lineWidth: 0.5)
            // The folded corner.
            Path { p in
                p.move(to: CGPoint(x: w * 0.7, y: 0))
                p.addLine(to: CGPoint(x: w * 0.7, y: w * 0.3))
                p.addLine(to: CGPoint(x: w, y: w * 0.3))
                p.closeSubpath()
            }
            .fill(.white.opacity(0.45))
            .frame(width: w, height: h, alignment: .topLeading)
            Text(format.badge)
                .font(.system(size: size * (format.badge.count > 3 ? 0.18 : 0.22), weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                .padding(.bottom, h * 0.14)
        }
        .frame(width: w, height: h)
    }
}

private struct DogEar: Shape {
    let fold: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = r.width * 0.12
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .foregroundStyle(.secondary)
    }
}

// MARK: - What each format is for

extension ExportFormat {
    /// The short name on the badge.
    var badge: String {
        switch self {
        case .jpeg: "JPG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .jpegxl: "JXL"
        case .jpeg2000: "JP2"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .exr: "EXR"
        }
    }

    /// Top and bottom of the badge's gradient.
    var colours: [UInt32] {
        switch self {
        case .jpeg: [0xFBBC04, 0xF57C3B]
        case .heic: [0x34A8F0, 0x4285F4]
        case .avif: [0xA05CE0, 0x7B61FF]
        case .jpegxl: [0x5C6BC0, 0x3949AB]
        case .jpeg2000: [0x26C6DA, 0x00897B]
        case .png: [0x66BB6A, 0x34A853]
        case .tiff: [0x78909C, 0x546E7A]
        case .exr: [0xEC407A, 0xC2185B]
        }
    }

    /// What it is good for, in one line.
    var summary: String {
        switch self {
        case .jpeg: "Opens everywhere. Lossy, 8-bit, no transparency."
        case .heic: "Smaller than JPEG at the same look; Apple's own. HDR and transparency."
        case .avif: "Often the smallest for the web. HDR and transparency."
        case .jpegxl: "Small files, wide support in newer apps. HDR and transparency."
        case .jpeg2000: "Archives and medical imaging. Up to 16-bit."
        case .png: "Lossless, with transparency: graphics, screenshots, the web."
        case .tiff: "Lossless, for print and other editors. Up to 32-bit float."
        case .exr: "Linear floating point: HDR masters and compositing."
        }
    }

    /// What it can hold, as chips.
    var abilities: [String] {
        var out = [isLossy ? "Lossy" : "Lossless"]
        if carriesHDR || isSceneLinear { out.append("HDR") }
        if keepsAlpha { out.append("Transparency") }
        if let deepest = depths.last, deepest != .eight { out.append(deepest.title) }
        return out
    }
}
