// Print (⌘P): Pictty's own sheet for where the picture goes and how it is made ready, then the
// system's print panel for the printer's own settings (paper type, quality, copies, PDF).
// The picture printed is the one Save would write: every pixel, with the edits on screen.

import AppKit
import PicttyCore
import SwiftUI

extension ViewerWindowController {
    /// Developer hook: print straight into this PDF, with no panel (PICTTY_PRINT_PDF).
    static var printToPDF: URL? {
        ProcessInfo.processInfo.environment["PICTTY_PRINT_PDF"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    var canPrint: Bool {
        guard let item = model.current else { return false }
        return !model.isSaving && !model.cropping && canvas.shown(pane: 0)?.url == item.url
    }

    @objc func printPicture(_ sender: Any?) {
        guard canPrint, let item = model.current, let window, window.attachedSheet == nil,
              let shown = canvas.shown(pane: 0) else { return }
        let turn = orientationChange
        var size = shown.pixelSize
        if let turn, turn.quarterTurns % 2 == 1 { size = CGSize(width: size.height, height: size.width) }
        var preview = shown.preview ?? shown.full
        if let turn, let p = preview { preview = ImageExporter.oriented(p, quarterTurns: turn.quarterTurns, mirror: turn.mirror) }
        if shown.isHDR, let p = preview { preview = PrintRender.toneMapped(p) ?? p }
        let report = probes[item.url.path]?.report
        let details = [item.fileName, report?.capturedLine, report?.cameraLine, report?.exposureLine]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")

        let session = PrintSession(picture: .init(preview: preview, pixels: size, name: item.fileName, details: details,
                                                  edited: hasUnsavedEdits), prefs: prefs)
        let host = NSHostingController(rootView: PrintSheetView(session: session))
        let sheet = NSWindow(contentViewController: host)
        sheet.styleMask = [.titled]
        sheet.title = L("Print")
        session.onCancel = { [weak window, weak sheet] in
            guard let sheet else { return }
            window?.endSheet(sheet)
        }
        session.onPrint = { [weak self, weak session, weak sheet] in
            guard let self, let session, let sheet else { return }
            self.preparePrint(item.url, session: session, sheet: sheet)
        }
        printSession = session
        window.beginSheet(sheet) { [weak self] _ in self?.printSession = nil }
    }

    /// Every pixel rendered with the edits, cut to the printed part, enlarged or reduced to what
    /// the printer gets and sharpened for the paper; then the print panel.
    private func preparePrint(_ url: URL, session: PrintSession, sheet: NSWindow) {
        session.preparing = true
        let edits = editSnapshot(for: url)
        let layout = session.layout
        let settings = session.settings
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var ready: CGImage?
            if let (whole, isHDR) = Self.renderEdited(url, edits, progress: nil), let whole {
                // The layout was made on the picture's nominal size; the render may differ by a pixel or a RAW's develop.
                let kx = CGFloat(whole.width) / max(layout.picture.width, 1)
                let ky = CGFloat(whole.height) / max(layout.picture.height, 1)
                let v = layout.visiblePixels
                let visible = CGRect(x: v.minX * kx, y: v.minY * ky, width: v.width * kx, height: v.height * ky)
                let printed = layout.printedRect
                let ppi = Double(visible.width / (printed.width / 72))
                let target = PrintResolution.target(visible: visible.size, printed: printed.size, ppi: ppi, upscale: settings.upscale)
                let sent = target.map { Double($0.width / (printed.width / 72)) } ?? ppi
                ready = PrintRender.prepare(whole, isHDR: isHDR, visible: visible, size: target, ppi: sent,
                                            sharpening: settings.sharpening, finish: settings.finish)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    session.preparing = false
                    guard let ready else {
                        self.showToast(L("Not printed: the picture could not be rendered."), symbol: "exclamationmark.triangle", tone: .error)
                        return
                    }
                    self.window?.endSheet(sheet)
                    self.runPrint(ready, session: session, layout: layout)
                }
            }
        }
    }

    private func runPrint(_ image: CGImage, session: PrintSession, layout: PrintLayout) {
        guard let window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        Printers.configure(info, printer: session.printer, paper: session.paper, landscape: session.landscape)
        let view = PrintPageView(printable: Printers.sheet(info).printable, image: image, rect: layout.printedRect,
                                 intent: session.settings.intent.cg, caption: session.captionRect.map { ($0, session.captionText) })
        if let pdf = Self.printToPDF {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf
        }
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = session.picture.name
        op.showsProgressPanel = true
        op.printPanel.options = [.showsCopies, .showsPreview]
        if Self.printToPDF != nil {
            op.showsPrintPanel = false
            op.run()
        } else {
            op.showsPrintPanel = true
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }
}

/// What the printer reaches of one sheet, in points, drawn in the paper's own top-left coordinates:
/// the picture where the sheet put it and the caption under it.
final class PrintPageView: NSView {
    private let origin: CGPoint
    private let image: CGImage
    private let rect: CGRect
    private let intent: CGColorRenderingIntent
    private let caption: (rect: CGRect, text: String)?

    init(printable: CGRect, image: CGImage, rect: CGRect, intent: CGColorRenderingIntent, caption: (CGRect, String)?) {
        origin = printable.origin
        self.image = image
        self.rect = rect
        self.intent = intent
        self.caption = caption.map { (rect: $0.0, text: $0.1) }
        super.init(frame: CGRect(origin: .zero, size: printable.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: -origin.x, y: -origin.y)
        ctx.setRenderingIntent(intent)
        ctx.interpolationQuality = .high
        // Images draw bottom-up: flipped back over the picture's own rectangle.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()

        if let caption {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: caption.text, attributes: [
                .font: NSFont.systemFont(ofSize: PrintSession.captionSize),
                .foregroundColor: NSColor(white: 0.35, alpha: 1),
                .paragraphStyle: style,
            ]).draw(in: caption.rect)
        }
        ctx.restoreGState()
    }
}
