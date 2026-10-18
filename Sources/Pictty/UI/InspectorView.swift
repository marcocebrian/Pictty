// The metadata panel. Camera, exposure, image, software/provenance, dates and
// location — each section headed by an SF Symbol, each row a label/value pair
// with tabular figures so numbers line up column-wise.
//
// The "Software" section is the one people rarely see and often need: it is
// where the derivation trail lives — what produced the file, what toolkit
// touched it last, whether it came from something else, and when.

import AppKit
import PicttyCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: ViewerModel
    let controller: ViewerWindowController

    @State private var copiedRow: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))

            if model.isComparing {
                panePicker
                Divider().overlay(.white.opacity(0.08))
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let analysis = model.analysis {
                        HistogramCard(analysis: analysis, showClipping: model.showClipping) {
                            controller.toggleClipping(nil)
                        }
                    }
                    let report = activeReport
                    if report.sections.isEmpty {
                        Text("No metadata in this file.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.62))
                            .padding(.top, 12)
                    }
                    ForEach(report.sections) { section in
                        SectionBlock(section: section, copiedRow: $copiedRow)
                    }
                    technicalFooter
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassCard(tint: 0.8, scrim: 0.62)
        // Room for the card's shadow inside its hosting view.
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 4))
    }

    /// What the file is, as a symbol and a gradient for the header tile.
    private func kind(_ item: ImageItem, _ report: MetadataReport) -> (symbol: String, colors: [Color]) {
        if item.url.pathExtension.lowercased() == "svg" { return ("scribble.variable", [Color(hex: 0xA05CE0), Color(hex: 0xEA4335)]) }
        if item.isRaw { return ("camera.aperture", [Color(hex: 0xF57C3B), Color(hex: 0xEA4335)]) }
        if report.isAnimated { return ("film.stack", [Color(hex: 0x34A853), Color(hex: 0x00ACC1)]) }
        if report.isHDR { return ("sun.max.fill", [Color(hex: 0xFBBC04), Color(hex: 0xF57C3B)]) }
        return ("photo", [Color(hex: 0x4285F4), Color(hex: 0x34A8F0)])
    }

    private var activeReport: MetadataReport {
        model.activePane == 0 ? model.report : model.compareReport
    }

    private var activeItem: ImageItem? {
        model.item(forPane: model.activePane) ?? model.current
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("INFORMATION")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                GlyphButton(symbol: "xmark", help: "Close (I)") { controller.toggleInspector(nil) }
            }

            if let item = activeItem {
                let report = activeReport
                HStack(alignment: .center, spacing: 10) {
                    SymbolTile(symbol: kind(item, report).symbol, colors: kind(item, report).colors, size: 34)
                    Text(item.fileName)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: 5) {
                    Badge(text: item.fileExtension.isEmpty ? L("FILE") : item.fileExtension, tone: .plain)
                    if report.isHDR {
                        Badge(text: "HDR", tone: .accent)
                    }
                    if report.isAnimated {
                        Badge(text: "ANIMATED", tone: .plain)
                    }
                    if report.hasLocation {
                        Badge(text: "GPS", tone: .plain)
                    }
                    if item.isRaw {
                        Badge(text: "RAW", tone: .plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    private var panePicker: some View {
        HStack(spacing: 6) {
            ForEach(0..<model.paneCount, id: \.self) { pane in
                Button {
                    model.activePane = pane
                    controller.activePaneChanged()
                } label: {
                    HStack(spacing: 4) {
                        Text("\(pane + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                        Text(pane == 0 ? L("Primary") : L("Pane %ld", pane + 1))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(model.activePane == pane ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06))
                    )
                    .foregroundStyle(model.activePane == pane ? Color.accentColor : Color.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Footer

    private var technicalFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                Text("RENDERER")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.66))
            }

            footerRow("Decoded", model.decodeSummary.isEmpty ? "—" : model.decodeSummary, "cpu")
            footerRow("At rest", model.renderSummary.isEmpty ? "—" : model.renderSummary, "sparkles")
            footerRow("Colour", model.colorSpaceSummary, "paintpalette")
            footerRow("Display", model.displaySummary, "display")
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }

    private func footerRow(_ label: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9.5))
                .frame(width: 13)
                .foregroundStyle(.white.opacity(0.5))
            Text(L(label))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.62))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Section

private struct SectionBlock: View {
    let section: MetadataSection
    @Binding var copiedRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: section.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .frame(width: 13)
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                Text(L(section.title).uppercased())
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.66))
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(section.fields) { field in
                    FieldRow(field: field,
                             isCopied: copiedRow == field.id.uuidString,
                             onCopy: {
                                 copy(field)
                             })
                }
            }
            .padding(.leading, 19)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }

    private func copy(_ field: MetadataField) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(field.value, forType: .string)
        copiedRow = field.id.uuidString
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            if copiedRow == field.id.uuidString { copiedRow = nil }
        }
    }
}

private struct FieldRow: View {
    let field: MetadataField
    let isCopied: Bool
    let onCopy: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 5) {
                if let symbol = field.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9))
                        .frame(width: 11)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Text(L(field.label))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
                    // Room for longer labels in other languages without truncating.
                    .minimumScaleFactor(0.82)
            }
            .frame(width: 106, alignment: .leading)

            Text(L(field.value))
                .font(.system(size: 11, weight: .medium,
                              design: field.mono ? .monospaced : .rounded))
                .foregroundStyle(valueColor)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 0)

            if hovering || isCopied {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isCopied ? Color.green : Color.white.opacity(0.62))
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 1) { onCopy() }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .animation(.easeInOut(duration: 0.15), value: isCopied)
    }

    private var valueColor: Color {
        switch field.tint {
        case .normal:  return .white.opacity(0.86)
        case .accent:  return Color.accentColor.opacity(0.95)
        case .warning: return .orange
        }
    }
}

// MARK: - Badge

struct Badge: View {
    enum Tone { case plain, accent }
    let text: String
    var tone: Tone = .plain

    var body: some View {
        Text(L(text))
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(tone == .accent ? Color.black.opacity(0.85) : Color.white.opacity(0.72))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tone == .accent ? Color.accentColor : Color.white.opacity(0.1))
            )
    }
}

// MARK: - Histogram

/// Red, green and blue added together over the luminance, the way light adds; with how much
/// is clipped at each end and the switch for the warnings.
private struct HistogramCard: View {
    let analysis: ImageAnalysis
    let showClipping: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                Text("HISTOGRAM")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                Button(action: toggle) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle\(showClipping ? ".fill" : "")")
                        Text("Clipping")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(showClipping ? Color.orange.opacity(0.3) : .white.opacity(0.08)))
                    .foregroundStyle(showClipping ? Color.orange : .white.opacity(0.7))
                }
                .buttonStyle(PressScale())
                .help("Clipping warnings (J)")
            }

            Canvas { ctx, size in
                func area(_ bins: [Float]) -> Path {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: size.height))
                    for (i, v) in bins.enumerated() {
                        p.addLine(to: CGPoint(x: CGFloat(i) / 255 * size.width, y: size.height * (1 - CGFloat(v) * 0.94)))
                    }
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                    return p
                }
                ctx.fill(area(analysis.luma), with: .color(.white.opacity(0.16)))
                ctx.blendMode = .plusLighter
                ctx.fill(area(analysis.red), with: .color(Color(hex: 0xEA4335).opacity(0.55)))
                ctx.fill(area(analysis.green), with: .color(Color(hex: 0x34A853).opacity(0.55)))
                ctx.fill(area(analysis.blue), with: .color(Color(hex: 0x4285F4).opacity(0.6)))
            }
            .frame(height: 78)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack {
                clipLabel(L("Shadows"), analysis.shadowsClipped, Color(hex: 0x1E64F5))
                Spacer()
                clipLabel(L("Highlights"), analysis.highlightsClipped, Color(hex: 0xEB2828))
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }

    private func clipLabel(_ title: String, _ share: Double, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.white.opacity(0.66))
            Text(share < 0.0005 ? "0 %" : String(format: share < 0.01 ? "%.2f %%" : "%.1f %%", share * 100))
                .monospacedDigit()
                .foregroundStyle(share > 0.005 ? color.mix(with: .white, by: 0.35) : .white.opacity(0.7))
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
    }
}
