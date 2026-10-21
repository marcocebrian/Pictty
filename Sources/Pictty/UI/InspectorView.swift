// The metadata panel. Camera, exposure, image, software/provenance, dates,
// location and keywords — each section headed by an SF Symbol, each row a
// label/value pair with tabular figures so numbers line up column-wise. Every
// section can be switched off, here in the header's menu or in Settings.
//
// The "Software" section is the one people rarely see and often need: it is
// where the derivation trail lives — what produced the file, what toolkit
// touched it last, whether it came from something else, and when.

import AppKit
import PicttyCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var prefs: Preferences
    let controller: ViewerWindowController

    var body: some View {
        // Nothing while put away: a hidden panel costs the picture nothing, at launch or after.
        if model.showInspector { panel }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))

            if model.isComparing {
                panePicker
                Divider().overlay(.white.opacity(0.08))
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if prefs.shows(.histogram), let analysis = model.analysis {
                        HistogramCard(analysis: analysis, showClipping: model.showClipping, style: $prefs.histogramStyle) {
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
                    ForEach(report.sections.filter { InspectorSection(sectionTitle: $0.title).map(prefs.shows) ?? true }) { section in
                        SectionBlock(section: section)
                    }
                    if prefs.shows(.keywords) {
                        KeywordsCard(keywords: report.keywords, tags: report.finderTags)
                    }
                    if prefs.shows(.renderer) { technicalFooter }
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
                sectionMenu
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

    /// Which sections the panel shows; the same switches as in Settings.
    private var sectionMenu: some View {
        Menu {
            ForEach(InspectorSection.allCases) { section in
                Toggle(isOn: Binding(get: { prefs.shows(section) }, set: { prefs.setShows(section, $0) })) {
                    Label(L(section.title), systemImage: section.symbol)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .help("Choose the sections to show")
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
                    FieldRow(field: field)
                }
            }
            .padding(.leading, 19)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }
}

private struct FieldRow: View {
    /// The value is selectable text: drag across it, or double-click a word, and ⌘C.
    let field: MetadataField

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
        }
    }

    private var valueColor: Color {
        switch field.tint {
        case .normal:  return .white.opacity(0.86)
        case .accent:  return Color.accentColor.opacity(0.95)
        case .warning: return .orange
        }
    }
}

// MARK: - Keywords

/// The file's keywords and its Finder tags as chips, at the bottom of the panel; a long list
/// scrolls inside the card. A click copies the word.
private struct KeywordsCard: View {
    let keywords: [String]
    let tags: [String]
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .font(.system(size: 9.5, weight: .semibold))
                    .frame(width: 13)
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                Text(L("Keywords").uppercased())
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                if keywords.count + tags.count > 0 {
                    Text("\(keywords.count + tags.count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            if keywords.isEmpty && tags.isEmpty {
                Text("No keywords or tags")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 19)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !keywords.isEmpty { group("Keywords", "text.word.spacing", keywords) }
                        if !tags.isEmpty { group("Finder tags", "tag.fill", tags) }
                    }
                    .padding(.leading, 19)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 132)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }

    private func group(_ title: String, _ symbol: String, _ words: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Only worth saying which is which when there are both.
            if !keywords.isEmpty && !tags.isEmpty {
                Label(L(title), systemImage: symbol)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            FlowLayout(spacing: 4) {
                ForEach(words, id: \.self) { word in
                    Text(copied == word ? L("Copied") : word)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(copied == word ? Color.green : .white.opacity(0.86))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(.white.opacity(0.09)))
                        .contentShape(Capsule())
                        .onTapGesture { copy(word) }
                        .help(word)
                }
            }
        }
    }

    private func copy(_ word: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(word, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { copied = word }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            if copied == word { withAnimation(.easeInOut(duration: 0.15)) { copied = nil } }
        }
    }
}

/// Lays its children out left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                  proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if !row.items.isEmpty, row.width + spacing + w > width {
                let next = row.y + row.height + spacing
                rows.append(row)
                row = Row(y: next)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + w
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
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
/// is clipped at each end and the switch for the warnings. The title switches to the waveform,
/// which shows where across the picture the highlights and shadows are.
struct HistogramCard: View {
    let analysis: ImageAnalysis
    let showClipping: Bool
    @Binding var style: HistogramStyle
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: style == .waveform ? "waveform.path.ecg" : "chart.bar.xaxis")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 13)
                ForEach(HistogramStyle.allCases) { option in
                    Button { withAnimation(.easeInOut(duration: 0.18)) { style = option } } label: {
                        Text(L(option.title).uppercased())
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(style == option ? 0.85 : 0.32))
                            .lineLimit(1)
                            .fixedSize()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(option == .waveform
                          ? L("Waveform: the picture's columns left to right, brightness bottom to top. A line along the top edge is blown highlights, along the bottom blocked shadows.")
                          : L("Histogram: how many pixels at each brightness, shadows left, highlights right."))
                }
                Spacer()
                // Only the symbol, so it fits beside both titles in every language; the yellow
                // glow says it can be pressed, and grows when the warnings are on.
                Button(action: toggle) {
                    Image(systemName: "exclamationmark.triangle\(showClipping ? ".fill" : "")")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFBBC04).opacity(showClipping ? 1 : 0.85))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 24, height: 22)
                        .background(Circle().fill(Color(hex: 0xFBBC04).opacity(showClipping ? 0.26 : 0.1)))
                        .overlay(Circle().strokeBorder(Color(hex: 0xFBBC04).opacity(showClipping ? 0.5 : 0.22), lineWidth: 0.5))
                        .shadow(color: Color(hex: 0xFBBC04).opacity(showClipping ? 0.6 : 0.3), radius: showClipping ? 7 : 4)
                        .contentShape(Circle())
                }
                .buttonStyle(PressScale())
                .help("Clipping warnings (J)")
                .accessibilityLabel(L("Clipping warnings"))
            }

            Group {
                if style == .waveform { waveform } else { histogram }
            }
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

    private var histogram: some View {
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
    }

    /// The traces over a scale at quarters, with the two edges where clipping lands marked in
    /// the warnings' colours: red along the top, blue along the bottom.
    private var waveform: some View {
        ZStack {
            Canvas { ctx, size in
                for q in 1...3 {
                    let y = (size.height * CGFloat(q) / 4).rounded() + 0.5
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                }
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 1)), with: .color(Color(hex: 0xEB2828).opacity(0.55)))
                ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)),
                         with: .color(Color(hex: 0x1E64F5).opacity(0.55)))
            }
            if let wave = analysis.waveform {
                Image(decorative: wave, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .blendMode(.plusLighter)
            }
        }
        .frame(height: 96)
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
