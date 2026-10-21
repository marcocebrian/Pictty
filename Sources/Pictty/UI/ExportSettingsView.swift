// Save As and Convert: every setting in plain sight under the file name, nothing behind a
// disclosure. Only what applies to the chosen format shows; the rest goes rather than greys out.

import PicttyCore
import SwiftUI

@MainActor
final class ExportSettings: ObservableObject {
    @Published var options: ExportOptions {
        didSet {
            if options.format != oldValue.format {
                if !options.format.depths.contains(options.depth) { options.depth = .eight }
                onFormatChange?(options.format)
            }
        }
    }
    let isHDR: Bool
    let hasAlpha: Bool
    let pixelSize: CGSize
    let edited: Bool
    var onFormatChange: ((ExportFormat) -> Void)?

    init(options: ExportOptions, isHDR: Bool, hasAlpha: Bool, pixelSize: CGSize, edited: Bool) {
        var o = options
        if !ExportFormat.writable.contains(o.format) { o.format = .jpeg }
        self.options = o
        self.isHDR = isHDR
        self.hasAlpha = hasAlpha
        self.pixelSize = pixelSize
        self.edited = edited
    }

    /// What the file will measure, after any resize.
    var outputSize: CGSize {
        guard let edge = options.longEdge, edge > 0, max(pixelSize.width, pixelSize.height) > CGFloat(edge) else { return pixelSize }
        let k = CGFloat(edge) / max(pixelSize.width, pixelSize.height)
        return CGSize(width: (pixelSize.width * k).rounded(), height: (pixelSize.height * k).rounded())
    }
}

struct ExportSettingsView: View {
    @ObservedObject var settings: ExportSettings

    private static let edges = [7680, 6000, 4096, 3840, 2560, 2048, 1600, 1080]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 9) {
            row("Format") {
                Picker("", selection: $settings.options.format) {
                    ForEach(ExportFormat.writable) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if settings.options.format.isLossy {
                row("Quality") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.options.quality, in: 0.1...1)
                            .frame(width: 220)
                        Text("\(Int((settings.options.quality * 100).rounded()))")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                        Text(qualityHint)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if settings.options.format.depths.count > 1 {
                row("Bit depth") {
                    Picker("", selection: $settings.options.depth) {
                        ForEach(settings.options.format.depths) { Text(L($0.title)).tag($0) }
                    }
                    .labelsHidden()
                .fixedSize()
                }
            }

            if settings.isHDR, settings.options.format.carriesHDR {
                row("HDR") {
                    Picker("", selection: $settings.options.hdr) {
                        ForEach(ExportHDR.allCases) { Text(L($0.title)).tag($0) }
                    }
                    .labelsHidden()
                .fixedSize()
                }
            }

            row("Colour profile") {
                Picker("", selection: $settings.options.colorSpace) {
                    ForEach(ExportColorSpace.allCases) { Text(L($0.title)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(settings.isHDR && settings.options.format.carriesHDR && settings.options.hdr != .sdr)
            }

            row("Size") {
                HStack(spacing: 8) {
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

            row("Metadata") {
                Picker("", selection: $settings.options.metadata) {
                    ForEach(ExportMetadata.allCases) { Text(L($0.title)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            if settings.options.format == .tiff {
                row("Compression") {
                    Picker("", selection: $settings.options.compression) {
                        ForEach(ExportCompression.allCases) { Text(L($0.title)).tag($0) }
                    }
                    .labelsHidden()
                .fixedSize()
                }
            }

            if settings.options.format == .jpeg, settings.hasAlpha {
                row("Transparency") {
                    Picker("", selection: $settings.options.matteWhite) {
                        Text("On white").tag(true)
                        Text("On black").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                .fixedSize()
                }
            }

            if [.jpeg, .heic].contains(settings.options.format) {
                row("Options") {
                    HStack(spacing: 16) {
                        if settings.options.format == .jpeg {
                            Toggle("Progressive", isOn: $settings.options.progressive)
                        }
                        Toggle("Embed a thumbnail", isOn: $settings.options.embedThumbnail)
                    }
                }
            }

            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Label(settings.edited ? L("The Light adjustments are applied to every pixel.")
                                      : L("No adjustments: a straight conversion, the pixels upright."),
                      systemImage: settings.edited ? "slider.horizontal.3" : "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(minWidth: 560, alignment: .leading)
    }

    private var qualityHint: String {
        switch settings.options.quality {
        case ..<0.5: L("small file")
        case ..<0.8: L("balanced")
        case ..<0.95: L("high")
        default: L("near lossless")
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            Text(L(title))
                .gridColumnAlignment(.trailing)
            content()
        }
    }
}
