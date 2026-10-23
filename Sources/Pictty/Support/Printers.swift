// The printers this Mac knows and the papers each one takes, with the margins it cannot print in,
// read through Core Printing so the sizes are the printer's own (borderless papers included).
// With no printer at all, the common papers stand in, so a PDF can still be made.

import AppKit
import ApplicationServices
import PicttyCore

struct Printer: Identifiable, Hashable {
    /// The queue's identifier.
    let id: String
    let name: String
    let isDefault: Bool
}

struct Paper: Identifiable, Hashable {
    /// The printer's name for it (its PPD name), or the size's own for the stand-ins.
    let id: String
    let name: String
    /// In points, portrait.
    let size: CGSize
    /// What the printer reaches, in points from the top-left, portrait.
    let printable: CGRect

    /// Prints to the edges.
    var borderless: Bool { printable.insetBy(dx: -1, dy: -1).contains(CGRect(origin: .zero, size: size)) }

    /// "21 × 29.7 cm" or "8.5 × 11 in".
    func dimensions(_ unit: PrintUnit) -> String {
        "\(PrintFormat.number(size.width, unit)) × \(PrintFormat.number(size.height, unit)) \(unit.symbol)"
    }
}

enum Printers {
    static func all() -> [Printer] {
        var list: Unmanaged<CFArray>?
        guard PMServerCreatePrinterList(nil, &list) == noErr, let array = list?.takeRetainedValue() else { return [] }
        return elements(array).compactMap { printer in
            guard let id = PMPrinterGetID(printer) as String?,
                  let name = PMPrinterGetName(printer) as String? else { return nil }
            return Printer(id: id, name: name, isDefault: PMPrinterIsDefault(printer))
        }
    }

    /// The papers `printer` takes, in its own order; the common ones when there is no printer.
    static func papers(for printer: Printer?) -> [Paper] {
        guard let printer else { return standIns }
        return withPrinter(printer) { pm in
            var list: Unmanaged<CFArray>?
            guard PMPrinterGetPaperList(pm, &list) == noErr, let array = list?.takeUnretainedValue() else { return [] }
            var seen = Set<String>()
            return elements(array).compactMap { paper -> Paper? in
                guard let id = paperID(paper), seen.insert(id).inserted else { return nil }
                var w = 0.0, h = 0.0
                var m = PMPaperMargins(top: 0, left: 0, bottom: 0, right: 0)
                guard PMPaperGetWidth(paper, &w) == noErr, PMPaperGetHeight(paper, &h) == noErr, w > 0, h > 0 else { return nil }
                PMPaperGetMargins(paper, &m)
                var localized: Unmanaged<CFString>?
                PMPaperCreateLocalizedName(paper, pm, &localized)
                let name = localized?.takeRetainedValue() as String? ?? id
                return Paper(id: id, name: name, size: CGSize(width: w, height: h),
                             printable: CGRect(x: m.left, y: m.top, width: w - m.left - m.right, height: h - m.top - m.bottom))
            }
        } ?? standIns
    }

    /// `info` set to print on `paper` in `printer`, turned `landscape`, with no margins of its own:
    /// the page view covers the whole sheet, so a point on it is a point on the paper.
    static func configure(_ info: NSPrintInfo, printer: Printer?, paper: Paper, landscape: Bool) {
        if let printer, let ns = NSPrinter(name: printer.name) { info.printer = ns }
        var applied = false
        if let printer {
            applied = withPrinter(printer) { pm -> Bool in
                var list: Unmanaged<CFArray>?
                guard PMPrinterGetPaperList(pm, &list) == noErr, let array = list?.takeUnretainedValue(),
                      let match = elements(array).first(where: { paperID($0) == paper.id })
                else { return false }
                var format: PMPageFormat?
                guard PMCreatePageFormatWithPMPaper(&format, match) == noErr,
                      let format else { return false }
                defer { PMRelease(PMObject(format)) }
                PMCopyPageFormat(format, OpaquePointer(info.pmPageFormat()))
                info.updateFromPMPageFormat()
                return true
            } ?? false
        }
        if !applied { info.paperSize = paper.size }
        info.orientation = landscape ? .landscape : .portrait
        // AppKit starts the page where the printer can reach, whatever the margins say; margins
        // equal to the printer's own make that explicit, and PrintPageView covers just that area.
        let r = info.imageablePageBounds, paper = info.paperSize
        info.leftMargin = r.minX
        info.bottomMargin = r.minY
        info.rightMargin = paper.width - r.maxX
        info.topMargin = paper.height - r.maxY
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.scalingFactor = 1
    }

    /// Core Printing's arrays hold its own opaque objects, which Swift cannot bridge.
    private static func elements(_ array: CFArray) -> [OpaquePointer] {
        (0..<CFArrayGetCount(array)).compactMap { CFArrayGetValueAtIndex(array, $0).map { OpaquePointer($0) } }
    }

    /// The sheet as `info` has it, turned, and what the printer reaches on it, from the top-left.
    static func sheet(_ info: NSPrintInfo) -> (paper: CGSize, printable: CGRect) {
        let r = info.imageablePageBounds, paper = info.paperSize
        return (paper, CGRect(x: r.minX, y: paper.height - r.maxY, width: r.width, height: r.height))
    }

    private static func paperID(_ paper: PMPaper) -> String? {
        var ppd: Unmanaged<CFString>?
        if PMPaperGetPPDPaperName(paper, &ppd) == noErr, let name = ppd?.takeUnretainedValue() as String?, !name.isEmpty { return name }
        var id: Unmanaged<CFString>?
        return PMPaperGetID(paper, &id) == noErr ? id?.takeUnretainedValue() as String? : nil
    }

    private static func withPrinter<T>(_ printer: Printer, _ body: (PMPrinter) -> T) -> T? {
        guard let pm = PMPrinterCreateFromPrinterID(printer.id as CFString) else { return nil }
        defer { PMRelease(PMObject(pm)) }
        return body(pm)
    }

    /// When there is no printer: the papers most people print photos on, a quarter inch of margin.
    static let standIns: [Paper] = [
        ("iso-a4", "A4", 595.28, 841.89), ("na-letter", "US Letter", 612, 792), ("iso-a3", "A3", 841.89, 1190.55),
        ("iso-a5", "A5", 419.53, 595.28), ("na-legal", "US Legal", 612, 1008), ("tabloid", "Tabloid", 792, 1224),
        ("photo-10x15", "10 × 15 cm", 283.46, 425.2), ("photo-13x18", "13 × 18 cm", 368.5, 510.24),
        ("photo-4x6", "4 × 6 in", 288, 432), ("photo-5x7", "5 × 7 in", 360, 504), ("photo-8x10", "8 × 10 in", 576, 720),
    ].map { Paper(id: $0.0, name: $0.1, size: CGSize(width: $0.2, height: $0.3),
                  printable: CGRect(x: 18, y: 18, width: $0.2 - 36, height: $0.3 - 36)) }
}

/// Lengths for people.
enum PrintFormat {
    /// Points in `unit`, to a sensible precision: "29.7", "8.5", "210".
    static func number(_ points: CGFloat, _ unit: PrintUnit) -> String {
        let v = Double(points) / unit.points
        let decimals = unit == .mm ? 0 : (unit == .inch ? 2 : 1)
        let f = NumberFormatter()
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = decimals
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        return f.string(from: v as NSNumber) ?? String(format: "%.\(decimals)f", v)
    }

    /// "15 × 10 cm".
    static func size(_ s: CGSize, _ unit: PrintUnit) -> String {
        "\(number(s.width, unit)) × \(number(s.height, unit)) \(unit.symbol)"
    }
}
