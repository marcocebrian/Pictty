import CoreGraphics
import Foundation

// Printing: where the picture goes on the paper, how big, and whether it has the pixels for it.
// Pure geometry and arithmetic, so it can be tested without a printer. Everything physical is in
// points (1/72 inch), the unit paper sizes come in; pictures are in pixels; rectangles have their
// origin at the top-left of the paper.

public enum PrintUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case cm, inch, mm

    public var id: String { rawValue }

    /// Points in one of these.
    public var points: Double {
        switch self {
        case .cm: 72 / 2.54
        case .inch: 72
        case .mm: 72 / 25.4
        }
    }

    public var symbol: String {
        switch self {
        case .cm: "cm"
        case .inch: "in"
        case .mm: "mm"
        }
    }

    /// Centimetres, or inches where people measure in inches.
    public static func standard(for locale: Locale = .current) -> PrintUnit {
        locale.measurementSystem == .us ? .inch : .cm
    }
}

/// A photo-print size, as labs sell them: short side by long side.
public struct PhotoSize: Hashable, Codable, Sendable {
    public let short: Double
    public let long: Double
    public let unit: PrintUnit

    public init(_ short: Double, _ long: Double, _ unit: PrintUnit) {
        self.short = short
        self.long = long
        self.unit = unit
    }

    /// In points, landscape.
    public var points: CGSize { CGSize(width: long * unit.points, height: short * unit.points) }

    public var label: String { "\(Self.number(short)) × \(Self.number(long)) \(unit.symbol)" }

    static func number(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x)
    }

    public static let metric: [PhotoSize] = [
        (9, 13), (10, 15), (13, 18), (15, 20), (18, 24), (20, 25), (20, 30), (24, 30), (30, 40), (30, 45),
        (40, 50), (40, 60), (50, 70), (60, 90),
    ].map { PhotoSize($0.0, $0.1, .cm) }

    public static let imperial: [PhotoSize] = [
        (3.5, 5), (4, 6), (5, 7), (6, 8), (8, 10), (8, 12), (11, 14), (12, 16), (12, 18), (16, 20), (16, 24),
        (20, 30), (24, 36),
    ].map { PhotoSize($0.0, $0.1, .inch) }

    /// The sizes people buy where `unit` is used.
    public static func standard(for unit: PrintUnit) -> [PhotoSize] { unit == .inch ? imperial : metric }
}

/// How big the print is.
public enum PrintSizing: Hashable, Codable, Sendable {
    /// The whole picture, as large as the printable area allows.
    case fitPage
    /// The printable area covered, the picture cropped to it.
    case fillPage
    /// A photo-print size, turned the way the picture is.
    case photo(PhotoSize)
    /// A frame of any size, in points, as typed or dragged.
    case custom(width: Double, height: Double)
}

/// The picture on a page.
public struct PrintLayout: Equatable, Sendable {
    /// The paper in the chosen orientation, in points.
    public var paper: CGSize
    /// What the printer can reach, in points from the paper's top-left.
    public var printable: CGRect
    /// The picture, upright, in pixels.
    public var picture: CGSize
    /// The print's frame on the paper, in points.
    public var box: CGSize
    /// The frame's centre on the paper, in points.
    public var center: CGPoint
    /// The picture covers the frame, cropped (true), or fits inside it whole (false).
    public var fill: Bool
    /// Which part shows when the picture is cropped: 0 is the left or top edge, 1 the right or bottom.
    public var anchor: CGPoint

    public init(paper: CGSize, printable: CGRect, picture: CGSize, box: CGSize, center: CGPoint? = nil, fill: Bool,
                anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.paper = paper
        self.printable = printable
        self.picture = picture
        self.box = box
        self.center = center ?? CGPoint(x: printable.midX, y: printable.midY)
        self.fill = fill
        self.anchor = anchor
    }

    public var frame: CGRect {
        CGRect(x: center.x - box.width / 2, y: center.y - box.height / 2, width: box.width, height: box.height)
    }

    /// Where the whole picture lands, in points: larger than the frame when it is cropped, and
    /// centred in it (or not, by `anchor`).
    public var pictureRect: CGRect {
        let f = frame
        guard picture.width > 0, picture.height > 0, f.width > 0, f.height > 0 else { return f }
        let k = fill ? max(f.width / picture.width, f.height / picture.height)
                     : min(f.width / picture.width, f.height / picture.height)
        let w = picture.width * k, h = picture.height * k
        let ax = fill ? anchor.x : 0.5, ay = fill ? anchor.y : 0.5
        return CGRect(x: f.minX - (w - f.width) * ax, y: f.minY - (h - f.height) * ay, width: w, height: h)
    }

    /// The part of the picture on paper, in its pixels (top-left origin).
    public var visiblePixels: CGRect {
        let p = pictureRect, shown = p.intersection(frame)
        guard !shown.isNull, p.width > 0, p.height > 0 else { return .zero }
        let kx = picture.width / p.width, ky = picture.height / p.height
        return CGRect(x: (shown.minX - p.minX) * kx, y: (shown.minY - p.minY) * ky,
                      width: shown.width * kx, height: shown.height * ky)
    }

    /// The part of the frame the picture covers, in points.
    public var printedRect: CGRect { pictureRect.intersection(frame) }

    /// Pixels per inch on paper.
    public var ppi: Double {
        let r = printedRect
        guard !r.isNull, r.width > 0 else { return 0 }
        return Double(visiblePixels.width / (r.width / 72))
    }

    // MARK: Sizes

    /// The frame for `sizing`: turned the way the picture is (or square, for a square picture).
    public static func box(for sizing: PrintSizing, picture: CGSize, printable: CGRect) -> CGSize {
        guard picture.width > 0, picture.height > 0 else { return printable.size }
        let landscape = picture.width >= picture.height
        switch sizing {
        case .fitPage:
            let k = min(printable.width / picture.width, printable.height / picture.height)
            return CGSize(width: picture.width * k, height: picture.height * k)
        case .fillPage:
            return printable.size
        case .photo(let size):
            let p = size.points
            return landscape ? p : CGSize(width: p.height, height: p.width)
        case .custom(let width, let height):
            return CGSize(width: width, height: height)
        }
    }

    /// The paper turned the way that suits the picture: landscape for a wide one.
    public static func orient(_ paper: CGSize, landscape: Bool) -> CGSize {
        (paper.width > paper.height) == landscape ? paper : CGSize(width: paper.height, height: paper.width)
    }

    /// The printable area of `paper` (given portrait, top-left origin) once the paper is turned to
    /// `turned`. A quarter turn counter-clockwise: the top margin becomes the left one.
    public static func printable(_ rect: CGRect, of paper: CGSize, turned: CGSize) -> CGRect {
        guard turned != paper else { return rect }
        return CGRect(x: rect.minY, y: paper.width - rect.maxX, width: rect.height, height: rect.width)
    }

    /// True when a frame this size fits on the paper.
    public static func fits(_ box: CGSize, on paper: CGSize) -> Bool {
        box.width <= paper.width + 0.5 && box.height <= paper.height + 0.5
    }

    // MARK: Placing

    /// `point` as a centre that keeps the frame on the paper, and inside the printable area when
    /// it is small enough to be.
    public func clamped(_ point: CGPoint) -> CGPoint {
        func axis(_ v: CGFloat, _ half: CGFloat, _ lo: CGFloat, _ hi: CGFloat, _ plo: CGFloat, _ phi: CGFloat) -> CGFloat {
            if hi - lo >= half * 2 { return min(max(v, lo + half), hi - half) }
            if phi - plo >= half * 2 { return min(max(v, plo + half), phi - half) }
            return (plo + phi) / 2
        }
        return CGPoint(x: axis(point.x, box.width / 2, printable.minX, printable.maxX, 0, paper.width),
                       y: axis(point.y, box.height / 2, printable.minY, printable.maxY, 0, paper.height))
    }

    /// Lines a dragged frame clicks onto.
    public struct Guides: Equatable, Sendable {
        public var vertical: [CGFloat] = []
        public var horizontal: [CGFloat] = []
        public init(vertical: [CGFloat] = [], horizontal: [CGFloat] = []) {
            self.vertical = vertical
            self.horizontal = horizontal
        }
    }

    /// `point` moved onto the printable area's centre lines or its edges when within `tolerance`
    /// points of them, with the lines it touched, then clamped.
    public func snapped(_ point: CGPoint, tolerance: CGFloat) -> (center: CGPoint, guides: Guides) {
        var p = point
        var guides = Guides()
        let hw = box.width / 2, hh = box.height / 2
        // Centre first, then the frame's edges on the printable edges.
        let xs: [(target: CGFloat, line: CGFloat)] = [(printable.midX, printable.midX),
                                                      (printable.minX + hw, printable.minX), (printable.maxX - hw, printable.maxX)]
        let ys: [(target: CGFloat, line: CGFloat)] = [(printable.midY, printable.midY),
                                                      (printable.minY + hh, printable.minY), (printable.maxY - hh, printable.maxY)]
        if let x = xs.first(where: { abs(point.x - $0.target) <= tolerance }) { p.x = x.target; guides.vertical.append(x.line) }
        if let y = ys.first(where: { abs(point.y - $0.target) <= tolerance }) { p.y = y.target; guides.horizontal.append(y.line) }
        return (clamped(p), guides)
    }

    /// The frame resized to `size` with the corner opposite `corner` held still (0 top-left,
    /// 1 top-right, 2 bottom-right, 3 bottom-left), then clamped.
    public func resized(to size: CGSize, holding corner: Int) -> PrintLayout {
        let f = frame
        let anchor: CGPoint = switch corner {
        case 0: CGPoint(x: f.maxX, y: f.maxY)
        case 1: CGPoint(x: f.minX, y: f.maxY)
        case 2: CGPoint(x: f.minX, y: f.minY)
        default: CGPoint(x: f.maxX, y: f.minY)
        }
        var out = self
        out.box = size
        let sx: CGFloat = corner == 0 || corner == 3 ? -1 : 1
        let sy: CGFloat = corner == 0 || corner == 1 ? -1 : 1
        out.center = out.clamped(CGPoint(x: anchor.x + sx * size.width / 2, y: anchor.y + sy * size.height / 2))
        return out
    }
}

// MARK: - Quality

/// Whether the picture has the pixels for the size it is printed at.
public struct PrintQuality: Equatable, Sendable {
    public enum Rating: Int, Comparable, Sendable {
        case pixelated, soft, good, veryGood, excellent
        public static func < (a: Rating, b: Rating) -> Bool { a.rawValue < b.rawValue }
    }

    /// Pixels per inch on paper.
    public let ppi: Double
    /// How far away a print this size is looked at, in millimetres: its diagonal, and never
    /// closer than reading distance.
    public let viewingDistance: Double
    /// What the eye can resolve from there: one pixel per arc minute.
    public let neededPPI: Double
    public let rating: Rating

    /// The resolution printers work at; the driver enlarges anything below it, and less finely.
    public static let printerPPI = 300.0
    /// Below this the printer's own enlargement starts to show.
    public static let upscaleBelow = 240.0

    public init(ppi: Double, printed: CGSize) {
        self.ppi = ppi
        let diagonal = Double(hypot(printed.width, printed.height)) * 25.4 / 72
        viewingDistance = max(300, diagonal)
        // One arc minute: 25.4 / (d · tan(1/60°)) pixels per inch at d millimetres.
        neededPPI = 25.4 / (viewingDistance * tan(Double.pi / 180 / 60))
        let r = ppi / neededPPI
        rating = switch r {
        case 1...: .excellent
        case 0.75..<1: .veryGood
        case 0.5..<0.75: .good
        case 0.33..<0.5: .soft
        default: .pixelated
        }
    }

    /// True when enlarging in Pictty before printing would give a better print than letting the
    /// printer do it.
    public var upscaleRecommended: Bool { ppi > 0 && ppi < Self.upscaleBelow }
}

/// What Pictty sends to the printer: how many pixels across the printed part of the picture.
public enum PrintResolution {
    /// The most pixels Pictty will make for one print (a 60 × 90 cm print at 300 ppi is 75 MP).
    public static let maxPixels = 160_000_000.0
    /// Sharper than any printer resolves; more pixels only make the job bigger.
    public static let maxPPI = 600.0

    /// The pixel size to render the printed part at: enlarged to the printer's resolution when
    /// `upscale` is on and it has fewer, shrunk when it has far more than any printer can use,
    /// and otherwise left as it is (nil).
    public static func target(visible: CGSize, printed: CGSize, ppi: Double, upscale: Bool) -> CGSize? {
        guard visible.width > 0, visible.height > 0, printed.width > 0, ppi > 0 else { return nil }
        var wanted: Double?
        if upscale, ppi < PrintQuality.printerPPI { wanted = PrintQuality.printerPPI }
        if ppi > maxPPI { wanted = maxPPI }
        guard var goal = wanted else { return nil }
        // Kept within the pixel budget.
        let inches = Double(printed.width * printed.height) / (72 * 72)
        goal = min(goal, (maxPixels / inches).squareRoot())
        // Enlarging by a few percent only adds a resample; shrinking always saves.
        guard goal > ppi * 1.1 || ppi > maxPPI else { return nil }
        let k = goal / ppi
        return CGSize(width: (Double(visible.width) * k).rounded(), height: (Double(visible.height) * k).rounded())
    }

    /// The largest print (in points, the picture's shape) at `ppi`.
    public static func largestSize(picture: CGSize, ppi: Double) -> CGSize {
        CGSize(width: picture.width / ppi * 72, height: picture.height / ppi * 72)
    }
}
