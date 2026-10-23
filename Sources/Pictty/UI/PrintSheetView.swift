// Print: the paper on the left, as it will come out of the printer, and every choice on the right.
// The picture is dragged into place on the sheet, resized by its corners, and ⌥-dragged to choose
// what a crop keeps. The quality panel says, in ppi and in words, whether the picture has the
// pixels for the size, from the distance a print that size is looked at, and offers to enlarge it
// before the printer does.

import AppKit
import PicttyCore
import SwiftUI

enum PrintOrientation: String, CaseIterable, Identifiable, Codable {
    case auto, portrait, landscape
    var id: String { rawValue }
}

/// How colours outside what the paper can reach are brought into it.
enum PrintIntent: String, CaseIterable, Identifiable, Codable {
    case perceptual, relative
    var id: String { rawValue }
    var title: String {
        switch self {
        case .perceptual: "Perceptual"
        case .relative: "Relative colorimetric"
        }
    }
    var summary: String {
        switch self {
        case .perceptual: "Every colour moves a little so the ones the paper can't reach keep their differences. For vivid pictures."
        case .relative: "The colours the paper can reach print exactly; the rest go to the nearest it has. For most pictures."
        }
    }
    var cg: CGColorRenderingIntent { self == .perceptual ? .perceptual : .relativeColorimetric }
}

enum PrintCaption: String, CaseIterable, Identifiable, Codable {
    case none, fileName, details, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .fileName: "File name"
        case .details: "Name, date and camera"
        case .custom: "Your own text"
        }
    }
}

/// The Print sheet's choices, remembered for the next print.
struct PrintSettings: Codable, Equatable {
    var printerID: String?
    var paperID: String?
    var orientation = PrintOrientation.auto
    var sizing = PrintSizing.fitPage
    /// A photo size or a custom frame of another shape: covered and cropped, or the whole picture inside.
    var fill = true
    var unit = PrintUnit.standard()
    var upscale = false
    var sharpening = PrintSharpening.standard
    var finish = PaperFinish.glossy
    var intent = PrintIntent.relative
    var caption = PrintCaption.none
    var captionText = ""
}

@MainActor
final class PrintSession: ObservableObject {
    struct Picture {
        /// Screen-sized, upright, edits and all.
        let preview: CGImage?
        /// Every pixel's worth, upright.
        let pixels: CGSize
        let name: String
        let details: String
        let edited: Bool
    }

    let picture: Picture
    let printers: [Printer]
    @Published private(set) var papers: [Paper] = []
    @Published var settings: PrintSettings {
        didSet { if settings != oldValue { changed(from: oldValue) } }
    }
    @Published var layout: PrintLayout
    @Published var guides = PrintLayout.Guides()
    @Published var preparing = false
    var onPrint: (() -> Void)?
    var onCancel: (() -> Void)?
    private let prefs: Preferences
    private var quietly = false

    init(picture: Picture, prefs: Preferences, printers: [Printer] = Printers.all()) {
        self.picture = picture
        self.prefs = prefs
        self.printers = printers
        var s = prefs.printSettings
        if !printers.contains(where: { $0.id == s.printerID }) {
            s.printerID = (printers.first(where: \.isDefault) ?? printers.first)?.id
        }
        settings = s
        layout = PrintLayout(paper: .zero, printable: .zero, picture: picture.pixels, box: .zero, fill: false)
        loadPapers()
        relayout()
    }

    var printer: Printer? { printers.first { $0.id == settings.printerID } }

    var paper: Paper {
        papers.first { $0.id == settings.paperID } ?? papers.first ?? Printers.standIns[0]
    }

    var pictureIsLandscape: Bool { picture.pixels.width > picture.pixels.height }

    var landscape: Bool {
        switch settings.orientation {
        case .auto: pictureIsLandscape
        case .portrait: false
        case .landscape: true
        }
    }

    /// The picture's own pixels on paper.
    var quality: PrintQuality { PrintQuality(ppi: layout.ppi, printed: layout.printedRect.size) }

    /// The print as it comes out: with upscaling on, counted from what is sent.
    var printQuality: PrintQuality {
        guard upscaling else { return quality }
        return .upscaled(ppi: layout.ppi, sent: sentPPI, printed: layout.printedRect.size)
    }

    /// True when upscaling is on and enlarges this print.
    var upscaling: Bool { settings.upscale && sentPPI > layout.ppi + 0.5 }

    /// What Pictty sends to the printer, when it is not the picture's own pixels.
    var target: CGSize? {
        PrintResolution.target(visible: layout.visiblePixels.size, printed: layout.printedRect.size, ppi: layout.ppi,
                               upscale: settings.upscale)
    }

    var sentPPI: Double {
        guard let target, layout.printedRect.width > 0 else { return layout.ppi }
        return Double(target.width / (layout.printedRect.width / 72))
    }

    /// How much upscaling would enlarge the picture.
    var upscaleFactor: Double {
        guard let t = PrintResolution.target(visible: layout.visiblePixels.size, printed: layout.printedRect.size,
                                             ppi: layout.ppi, upscale: true), layout.visiblePixels.width > 0 else { return 1 }
        return Double(t.width / layout.visiblePixels.width)
    }

    /// The photo sizes in the chosen unit, and whether each fits the paper as it is turned.
    var photoSizes: [(size: PhotoSize, fits: Bool)] {
        PhotoSize.standard(for: settings.unit == .inch ? .inch : .cm).map { size in
            let box = PrintLayout.box(for: .photo(size), picture: picture.pixels, printable: layout.printable)
            return (size, PrintLayout.fits(box, on: layout.paper))
        }
    }

    /// The largest print at the printer's resolution, the picture's shape.
    var sharpestSize: CGSize { PrintResolution.largestSize(picture: picture.pixels, ppi: PrintQuality.printerPPI) }

    var sharpestFits: Bool { PrintLayout.fits(sharpestSize, on: layout.paper) }

    /// True when the frame is another shape than the picture.
    var frameReshapes: Bool {
        guard picture.pixels.height > 0, layout.box.height > 0 else { return false }
        let a = picture.pixels.width / picture.pixels.height, b = layout.box.width / layout.box.height
        return abs(a - b) / a > 0.01
    }

    var captionText: String {
        switch settings.caption {
        case .none: ""
        case .fileName: picture.name
        case .details: picture.details
        case .custom: settings.captionText
        }
    }

    /// Captions are this many points high, a little under the frame.
    static let captionSize: CGFloat = 8
    static let captionGap: CGFloat = 7

    /// Where the caption prints, or nil when there is none or no room under the picture.
    var captionRect: CGRect? {
        guard !captionText.isEmpty else { return nil }
        let r = layout.printedRect
        let h = Self.captionSize * 1.5
        let y = r.maxY + Self.captionGap
        guard y + h <= layout.printable.maxY + 0.5 else { return nil }
        let w = max(r.width, min(layout.printable.width, 360))
        let x = min(max(r.midX - w / 2, layout.printable.minX), layout.printable.maxX - w)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Changes

    func center() {
        withAnimation(Chrome.spring) {
            layout.center = layout.clamped(CGPoint(x: layout.printable.midX, y: layout.printable.midY))
            layout.anchor = CGPoint(x: 0.5, y: 0.5)
        }
    }

    /// The frame dragged to a size: a custom size from now on, the position kept.
    func resize(to size: CGSize, holding corner: Int) {
        layout = layout.resized(to: size, holding: corner)
        quietly = true
        settings.sizing = .custom(width: Double(size.width), height: Double(size.height))
        quietly = false
    }

    /// A typed size, kept on the paper.
    func setCustom(width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        let k = min(1, Double(layout.paper.width) / width, Double(layout.paper.height) / height)
        settings.sizing = .custom(width: width * k, height: height * k)
    }

    /// The whole picture as large as this printer reaches on this paper, the paper turned
    /// whichever way gives more, centred.
    func maximize() {
        let p = paper, pixels = picture.pixels
        let area = { (landscape: Bool) -> CGFloat in
            let sheet = PrintLayout.orient(p.size, landscape: landscape)
            let box = PrintLayout.box(for: .fitPage, picture: pixels,
                                      printable: PrintLayout.printable(p.printable, of: p.size, turned: sheet))
            return box.width * box.height
        }
        let wide = area(true), tall = area(false)
        let landscape = abs(wide - tall) < 1 ? pictureIsLandscape : wide > tall
        settings.orientation = landscape == pictureIsLandscape ? .auto : landscape ? .landscape : .portrait
        settings.sizing = .fitPage
        center()
    }

    func useSharpestSize() {
        settings.sizing = .custom(width: Double(sharpestSize.width), height: Double(sharpestSize.height))
    }

    private func changed(from old: PrintSettings) {
        prefs.printSettings = settings
        if settings.printerID != old.printerID { loadPapers() }
        guard !quietly else { return }
        let reshapes = settings.printerID != old.printerID || settings.paperID != old.paperID
            || settings.orientation != old.orientation || settings.sizing != old.sizing || settings.fill != old.fill
        if reshapes { withAnimation(Chrome.spring) { relayout() } }
    }

    private func loadPapers() {
        papers = Printers.papers(for: printer)
        guard !papers.contains(where: { $0.id == settings.paperID }) else { return }
        // The paper people print on where they live, if the printer has it.
        let wanted = Locale.current.measurementSystem == .us ? ["Letter", "na-letter"] : ["A4", "iso-a4"]
        settings.paperID = (papers.first { wanted.contains($0.id) } ?? papers.first { wanted.contains($0.name) } ?? papers.first)?.id
    }

    private func relayout() {
        let p = paper
        var sheet = PrintLayout.orient(p.size, landscape: landscape)
        var printable = PrintLayout.printable(p.printable, of: p.size, turned: sheet)
        if printer != nil {
            // The printer's own word on the turned sheet, which is what the print will use.
            let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
            Printers.configure(info, printer: printer, paper: p, landscape: landscape)
            let measured = Printers.sheet(info)
            if abs(measured.paper.width - sheet.width) < 2, abs(measured.paper.height - sheet.height) < 2 {
                (sheet, printable) = measured
            }
        }
        var sizing = settings.sizing
        var box = PrintLayout.box(for: sizing, picture: picture.pixels, printable: printable)
        if !PrintLayout.fits(box, on: sheet) {
            // Larger than this paper: the largest that fits, the same shape.
            let k = min(sheet.width / box.width, sheet.height / box.height)
            box = CGSize(width: box.width * k, height: box.height * k)
            sizing = .custom(width: Double(box.width), height: Double(box.height))
        }
        let fill: Bool = switch sizing {
        case .fitPage: false
        case .fillPage: true
        case .photo, .custom: settings.fill
        }
        layout = PrintLayout(paper: sheet, printable: printable, picture: picture.pixels, box: box, fill: fill)
        layout.center = layout.clamped(layout.center)
        guides = .init()
    }
}

// MARK: - The sheet

struct PrintSheetView: View {
    @ObservedObject var session: PrintSession

    var body: some View {
        HStack(spacing: 0) {
            PaperPreview(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    PrintSettingsColumn(session: session)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }
                Divider()
                footer
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .frame(width: 350)
        }
        .frame(width: 1060, height: 700)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.preparing {
                ProgressView().controlSize(.small)
                Text("Preparing the picture…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label(session.picture.edited ? L("Printed with its edits.") : L("Printed as it is in the file."),
                      systemImage: session.picture.edited ? "slider.horizontal.3" : "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Cancel") { session.onCancel?() }
                .keyboardShortcut(.cancelAction)
            Button("Print…") { session.onPrint?() }
                .keyboardShortcut(.defaultAction)
                .disabled(session.preparing)
        }
        .controlSize(.large)
    }
}

// MARK: - Paper preview

private struct PaperPreview: View {
    @ObservedObject var session: PrintSession
    @State private var moveStart: (center: CGPoint, anchor: CGPoint, crop: Bool)?
    @State private var resizeStart: CGSize?
    @State private var grab: Grab?
    @State private var hovering = false

    /// What a drag took hold of, decided where it started: one gesture for the whole sheet, so
    /// the corners and the picture never compete for it.
    private enum Grab: Equatable {
        case picture, corner(Int), nothing
    }
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let layout = session.layout
            let foot: CGFloat = 54
            let room = CGSize(width: geo.size.width - 64, height: geo.size.height - foot - 48)
            let k = max(0.01, min(room.width / max(layout.paper.width, 1), room.height / max(layout.paper.height, 1)))
            let sheet = CGRect(x: (geo.size.width - layout.paper.width * k) / 2,
                               y: (geo.size.height - foot - layout.paper.height * k) / 2,
                               width: layout.paper.width * k, height: layout.paper.height * k)
            let map = { (r: CGRect) in
                CGRect(x: sheet.minX + r.minX * k, y: sheet.minY + r.minY * k, width: r.width * k, height: r.height * k)
            }
            let frame = map(layout.frame)

            ZStack(alignment: .topLeading) {
                Color.clear
                // The sheet of paper.
                Rectangle()
                    .fill(Color.white)
                    .frame(width: sheet.width, height: sheet.height)
                    .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
                    .position(x: sheet.midX, y: sheet.midY)
                // What the printer cannot reach.
                if !session.paper.borderless {
                    let p = map(layout.printable)
                    Rectangle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                        .foregroundStyle(Color.black.opacity(0.18))
                        .frame(width: p.width, height: p.height)
                        .position(x: p.midX, y: p.midY)
                        .allowsHitTesting(false)
                }
                picture(frame: frame, whole: map(layout.pictureRect), printed: map(layout.printedRect), k: k)
                guides(sheet: sheet, k: k)
                if let c = session.captionRect {
                    let r = map(c)
                    Text(session.captionText)
                        .font(.system(size: max(PrintSession.captionSize * k, 3)))
                        .foregroundStyle(Color(white: 0.35))
                        .lineLimit(1)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }
                handles(frame: frame, k: k)
                if moveStart != nil || resizeStart != nil {
                    Text(PrintFormat.size(layout.printedRect.size, session.settings.unit))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                }
                caption(sheet: sheet)
                    .frame(width: geo.size.width - 40)
                    .position(x: geo.size.width / 2, y: geo.size.height - foot / 2 - 6)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in hover(phase, frame: frame) }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in dragged(drag, frame: frame, k: k) }
                    .onEnded { _ in
                        grab = nil
                        moveStart = nil
                        resizeStart = nil
                        withAnimation(.easeOut(duration: 0.2)) { session.guides = .init() }
                    }
            )
            .onTapGesture(count: 2) { p in if frame.contains(p) { session.center() } }
            .help(L("Drag to place it · ⌥-drag to choose what the crop keeps · double-click to centre"))
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                nudge(press.key, far: press.modifiers.contains(.shift))
                return .handled
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { focused = true }
    }

    // MARK: Picture

    private func picture(frame: CGRect, whole: CGRect, printed: CGRect, k: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let cg = session.picture.preview {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: whole.width, height: whole.height)
                    .position(x: whole.midX - frame.minX, y: whole.midY - frame.minY)
            } else {
                Rectangle().fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipped()
        .overlay {
            // The frame itself, when the picture sits inside it with paper around.
            if !session.layout.fill || hovering || moveStart != nil {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(hovering || moveStart != nil ? 0.9 : 0.35),
                                  style: StrokeStyle(lineWidth: 1, dash: session.layout.fill ? [] : [4, 3]))
            }
        }
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
    }

    private static let cornerReach: CGFloat = 11

    private func corners(of frame: CGRect) -> [CGPoint] {
        [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
         CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)]
    }

    /// The corner within reach of `p`, the picture under it, or nothing.
    private func target(at p: CGPoint, frame: CGRect) -> Grab {
        let near = corners(of: frame).enumerated()
            .map { (i: $0.offset, d: hypot($0.element.x - p.x, $0.element.y - p.y)) }
            .min { $0.d < $1.d }
        if let near, near.d <= Self.cornerReach { return .corner(near.i) }
        return frame.contains(p) ? .picture : .nothing
    }

    private func dragged(_ drag: DragGesture.Value, frame: CGRect, k: CGFloat) {
        if grab == nil { grab = target(at: drag.startLocation, frame: frame) }
        switch grab {
        case .picture: move(drag.translation, k: k)
        case .corner(let i): resize(corner: i, by: drag.translation, k: k)
        default: focused = true
        }
    }

    private func hover(_ phase: HoverPhase, frame: CGRect) {
        guard grab == nil else { return }
        switch phase {
        case .active(let p):
            let t = target(at: p, frame: frame)
            hovering = t != .nothing
            switch t {
            case .corner(let i):
                NSCursor.frameResize(position: i % 2 == 0 ? .topLeft : .topRight, directions: .all).set()
            case .picture: NSCursor.openHand.set()
            default: NSCursor.arrow.set()
            }
        case .ended:
            hovering = false
            NSCursor.arrow.set()
        }
    }

    private func move(_ t: CGSize, k: CGFloat) {
        focused = true
        let layout = session.layout
        if moveStart == nil {
            let overflow = layout.pictureRect.width - layout.frame.width > 0.5 || layout.pictureRect.height - layout.frame.height > 0.5
            moveStart = (layout.center, layout.anchor, NSEvent.modifierFlags.contains(.option) && layout.fill && overflow)
        }
        guard let start = moveStart else { return }
        if start.crop {
            // The picture slides under the frame, the opposite way the anchor counts.
            let over = CGSize(width: layout.pictureRect.width - layout.frame.width, height: layout.pictureRect.height - layout.frame.height)
            var a = start.anchor
            if over.width > 0.5 { a.x = min(max(start.anchor.x - t.width / k / over.width, 0), 1) }
            if over.height > 0.5 { a.y = min(max(start.anchor.y - t.height / k / over.height, 0), 1) }
            session.layout.anchor = a
        } else {
            let wanted = CGPoint(x: start.center.x + t.width / k, y: start.center.y + t.height / k)
            let snap = layout.snapped(wanted, tolerance: 5 / k)
            session.layout.center = snap.center
            session.guides = snap.guides
        }
    }

    private func nudge(_ key: KeyEquivalent, far: Bool) {
        let step = CGFloat(far ? 10 : 1) * PrintUnit.mm.points
        var c = session.layout.center
        switch key {
        case .leftArrow: c.x -= step
        case .rightArrow: c.x += step
        case .upArrow: c.y -= step
        default: c.y += step
        }
        session.layout.center = session.layout.clamped(c)
    }

    // MARK: Guides and handles

    @ViewBuilder
    private func guides(sheet: CGRect, k: CGFloat) -> some View {
        ForEach(Array(session.guides.vertical.enumerated()), id: \.offset) { _, x in
            Rectangle().fill(Color.accentColor)
                .frame(width: 1, height: sheet.height)
                .position(x: sheet.minX + x * k, y: sheet.midY)
                .allowsHitTesting(false)
        }
        ForEach(Array(session.guides.horizontal.enumerated()), id: \.offset) { _, y in
            Rectangle().fill(Color.accentColor)
                .frame(width: sheet.width, height: 1)
                .position(x: sheet.midX, y: sheet.minY + y * k)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func handles(frame: CGRect, k: CGFloat) -> some View {
        let corners = corners(of: frame)
        ForEach(0..<4, id: \.self) { i in
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .position(corners[i])
                .allowsHitTesting(false)
        }
    }

    private func resize(corner: Int, by t: CGSize, k: CGFloat) {
        focused = true
        let layout = session.layout
        if resizeStart == nil { resizeStart = layout.box }
        guard let start = resizeStart, start.width > 0, start.height > 0 else { return }
        let sx: CGFloat = corner == 0 || corner == 3 ? -1 : 1
        let sy: CGFloat = corner == 0 || corner == 1 ? -1 : 1
        var f = max((start.width + sx * t.width / k) / start.width, (start.height + sy * t.height / k) / start.height)
        // No smaller than an inch on its long side, no larger than the paper.
        f = max(f, 72 / max(start.width, start.height))
        f = min(f, layout.paper.width / start.width, layout.paper.height / start.height)
        session.resize(to: CGSize(width: start.width * f, height: start.height * f), holding: corner)
    }

    // MARK: Caption under the sheet

    private func caption(sheet: CGRect) -> some View {
        let s = session
        let unit = s.settings.unit
        return VStack(spacing: 3) {
            HStack(spacing: 6) {
                Text(s.paper.name).fontWeight(.semibold)
                Text("·")
                Text(PrintFormat.size(s.layout.paper, unit)).monospacedDigit()
                if s.paper.borderless {
                    Text("·")
                    Text("Borderless")
                }
                Text("·")
                Text(L("Print %@", PrintFormat.size(s.layout.printedRect.size, unit))).monospacedDigit()
            }
            .font(.callout)
            Text("Drag to place it · drag a corner to resize · ⌥-drag to choose the crop · arrows nudge")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - Settings column

private struct PrintSettingsColumn: View {
    @ObservedObject var session: PrintSession
    @State private var linked = true

    private var s: PrintSettings { session.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            printerSection
            sizeSection
            QualityPanel(session: session)
            outputSection
            captionSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Printer and paper

    private var printerSection: some View {
        section("Printer and paper", "printer.fill", [0x4285F4, 0x34A8F0]) {
            if session.printers.isEmpty {
                Text("No printer is set up on this Mac. Print… still makes a PDF, from the menu at the bottom of the next panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Printer", selection: $session.settings.printerID) {
                    ForEach(session.printers) { Text($0.name).tag(String?.some($0.id)) }
                }
            }
            Picker("Paper", selection: $session.settings.paperID) {
                ForEach(session.papers) { paper in
                    Text(paperTitle(paper)).tag(String?.some(paper.id))
                }
            }
            HStack {
                Picker("Orientation", selection: $session.settings.orientation) {
                    Label("Automatic", systemImage: "wand.and.rays").tag(PrintOrientation.auto)
                    Label("Portrait", systemImage: "rectangle.portrait").tag(PrintOrientation.portrait)
                    Label("Landscape", systemImage: "rectangle").tag(PrintOrientation.landscape)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help(L("Automatic turns the paper the way the picture is"))
                Spacer()
                Picker("", selection: $session.settings.unit) {
                    ForEach(PrintUnit.allCases) { Text($0.symbol).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    private func paperTitle(_ paper: Paper) -> String {
        let dims = paper.dimensions(s.unit)
        return paper.name.contains("×") || paper.name.contains(" x ") ? paper.name : "\(paper.name)  —  \(dims)"
    }

    // MARK: Size

    private var sizeSection: some View {
        section("Size on paper", "arrow.up.left.and.arrow.down.right", [0x34A853, 0x00ACC1]) {
            Picker("Size", selection: $session.settings.sizing) {
                Text("Fit the page").tag(PrintSizing.fitPage)
                Text("Fill the page").tag(PrintSizing.fillPage)
                Divider()
                ForEach(session.photoSizes, id: \.size) { entry in
                    Text(entry.fits ? entry.size.label : L("%@ — larger than the paper", entry.size.label))
                        .tag(PrintSizing.photo(entry.size))
                        .selectionDisabled(!entry.fits)
                }
                Divider()
                Text("Custom").tag(customTag)
            }
            dimensionFields
            if session.frameReshapes {
                Picker("", selection: $session.settings.fill) {
                    Text("Fill the frame").tag(true)
                    Text("Whole picture").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(s.fill ? L("The picture covers the frame; ⌥-drag it to choose what is cropped.")
                            : L("The whole picture, with paper showing on two sides of the frame."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { session.center() } label: { Label("Centre on the page", systemImage: "align.horizontal.center") }
                Button { session.maximize() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(L("Maximise area"))
                    .accessibilityLabel(L("Maximise area"))
                Spacer()
            }
            .controlSize(.small)
        }
    }

    /// The custom entry in the menu: the frame as it is now, so choosing it changes nothing.
    private var customTag: PrintSizing {
        if case .custom = s.sizing { return s.sizing }
        return .custom(width: Double(session.layout.box.width), height: Double(session.layout.box.height))
    }

    private var dimensionFields: some View {
        let unit = s.unit
        let box = session.layout.box
        let w = Binding<Double>(
            get: { Double(box.width) / unit.points },
            set: { v in
                let width = v * unit.points
                let height = linked ? width * Double(box.height / max(box.width, 1)) : Double(box.height)
                session.setCustom(width: width, height: height)
            })
        let h = Binding<Double>(
            get: { Double(box.height) / unit.points },
            set: { v in
                let height = v * unit.points
                let width = linked ? height * Double(box.width / max(box.height, 1)) : Double(box.width)
                session.setCustom(width: width, height: height)
            })
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...(unit == .mm ? 0 : 2)))
        return HStack(spacing: 6) {
            TextField("Width", value: w, format: format)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Button { linked.toggle() } label: {
                Image(systemName: linked ? "link" : "link.badge.plus")
                    .foregroundStyle(linked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(linked ? L("Width and height keep the frame's shape") : L("Width and height change on their own"))
            TextField("Height", value: h, format: format)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text(unit.symbol).foregroundStyle(.secondary)
            Spacer()
        }
        .monospacedDigit()
    }

    // MARK: Output

    private var outputSection: some View {
        section("Paper and colour", "paintpalette.fill", [0xEA4335, 0xA05CE0]) {
            Picker("Sharpening", selection: $session.settings.sharpening) {
                ForEach(PrintSharpening.allCases) { Text(L($0.title)).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Paper finish", selection: $session.settings.finish) {
                ForEach(PaperFinish.allCases) { Text(L($0.title)).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(s.sharpening == .off)
            Text("Ink spreads into paper and softens what the screen shows crisp; matte paper more than glossy. Sharpening is made for the paper and the resolution sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Rendering", selection: $session.settings.intent) {
                ForEach(PrintIntent.allCases) { Text(L($0.title)).tag($0) }
            }
            Text(L(s.intent.summary))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("In the next panel, choose the paper type and the best quality in the printer's own settings, and let the printer manage colours.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var captionSection: some View {
        section("Caption", "text.below.photo", [0x607D8B, 0x455A64]) {
            Picker("Caption", selection: $session.settings.caption) {
                ForEach(PrintCaption.allCases) { Text(L($0.title)).tag($0) }
            }
            if s.caption == .custom {
                TextField("Caption text", text: $session.settings.captionText)
            }
            if s.caption != .none, session.captionRect == nil, !session.captionText.isEmpty {
                Text("No room under the picture for a caption: make the print smaller or move it up.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(_ title: String, _ symbol: String, _ colors: [UInt32],
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SymbolTile(symbol: symbol, colors: colors.map { Color(hex: $0) }, size: 20)
                Text(L(title)).font(.headline)
            }
            content()
        }
    }
}

// MARK: - Quality

private struct QualityPanel: View {
    @ObservedObject var session: PrintSession

    var body: some View {
        let q = session.printQuality
        let unit = session.settings.unit
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SymbolTile(symbol: "sparkle.magnifyingglass", colors: [Color(hex: 0xFBBC04), Color(hex: 0xF57C3B)], size: 20)
                Text("Quality").font(.headline)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int((session.upscaling ? session.sentPPI : q.ppi).rounded()))")
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("ppi").foregroundStyle(.secondary)
                if session.upscaling {
                    Text(L("upscaled from %ld", Int(session.quality.ppi.rounded())))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Text(L(title(q.rating)))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(colour(q.rating)))
            }
            Meter(ppi: q.ppi, needed: q.neededPPI, colour: colour(q.rating))
            Text(verdict(q))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text(L("Sharpest at 300 ppi: up to %@", PrintFormat.size(session.sharpestSize, unit)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Use") { session.useSharpestSize() }
                    .controlSize(.small)
                    .disabled(!session.sharpestFits)
                    .help(session.sharpestFits ? L("Print at that size") : L("Larger than the paper"))
            }
            upscale
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.2), value: q.rating)
        .animation(.easeOut(duration: 0.2), value: session.upscaling)
    }

    @ViewBuilder
    private var upscale: some View {
        let q = session.quality
        let px = { (s: CGSize) in L("%ld × %ld px", Int(s.width), Int(s.height)) }
        if q.upscaleRecommended || session.settings.upscale && session.layout.ppi < PrintQuality.printerPPI {
            VStack(alignment: .leading, spacing: 6) {
                if q.upscaleRecommended {
                    Label(L("Upscaling recommended"), systemImage: "arrow.up.backward.and.arrow.down.forward.square.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x4285F4))
                    Text("The printer would enlarge these pixels itself, coarsely. Pictty can enlarge them first, to 300 ppi, with a fine Lanczos enlargement that keeps edges free of halos, then sharpen for the paper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $session.settings.upscale) {
                    Text(L("Upscale ×%@ to %ld ppi", String(format: "%.1f", session.upscaleFactor), Int(PrintQuality.printerPPI)))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                if let t = session.target, session.settings.upscale {
                    Text(L("Sent to the printer: %@", px(t)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0x4285F4).opacity(0.08)))
        } else if let t = session.target {
            Text(L("Sent at %ld ppi (%@): more is lost on any printer and only makes the job bigger.", Int(session.sentPPI.rounded()), px(t)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func title(_ r: PrintQuality.Rating) -> String {
        switch r {
        case .excellent: "Excellent"
        case .veryGood: "Very good"
        case .good: "Good"
        case .soft: "Slightly blurry"
        case .pixelated: "Low quality"
        }
    }

    private func colour(_ r: PrintQuality.Rating) -> Color {
        switch r {
        case .excellent: Color(hex: 0x34A853)
        case .veryGood: Color(hex: 0x7CB342)
        case .good: Color(hex: 0xF9A825)
        case .soft: Color(hex: 0xF57C3B)
        case .pixelated: Color(hex: 0xEA4335)
        }
    }

    private func verdict(_ q: PrintQuality) -> String {
        let unit = session.settings.unit
        let distance = unit == .inch ? L("%ld in", Int((q.viewingDistance / 25.4).rounded()))
                                     : L("%ld cm", Int((q.viewingDistance / 10).rounded()))
        return switch q.rating {
        case .excellent: L("As sharp as the eye can see from %@, where a print this size is looked at.", distance)
        case .veryGood: L("Sharp from %@; held closer, the finest detail is slightly blurry.", distance)
        case .good: L("Fine from a step further back than %@; up close it looks slightly blurry.", distance)
        case .soft: L("Slightly blurry even from %@. A smaller print would be sharper.", distance)
        case .pixelated: L("Too few pixels for this size: it will look blocky even from %@. Print it smaller.", distance)
        }
    }
}

/// How the picture's ppi stands against what the eye resolves from the viewing distance.
private struct Meter: View {
    let ppi: Double
    let needed: Double
    let colour: Color

    var body: some View {
        GeometryReader { geo in
            let full = needed * 1.5
            let x = min(ppi / full, 1) * geo.size.width
            let mark = needed / full * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(colour).frame(width: max(x, 6))
                Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1.5, height: 12).offset(x: mark - 0.75)
            }
        }
        .frame(height: 6)
        .help(L("The line is what the eye resolves from the viewing distance: %ld ppi", Int(needed.rounded())))
        .animation(.easeOut(duration: 0.2), value: ppi)
    }
}
