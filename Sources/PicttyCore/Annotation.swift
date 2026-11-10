import CoreGraphics
import CoreText
import Foundation

/// One mark on the picture: a shape, text, a numbered step, or a region blurred, censored,
/// magnified or lit. Points are the picture's own 0…1 coordinates before the crop (top-left
/// origin, stored orientation), so a later crop keeps them on the same content.
public struct Annotation: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case arrow, rectangle, roundedRectangle, ellipse, text, step, highlighter, blur, censor, magnifier, spotlight
    }

    public var id = UUID()
    public var kind: Kind
    /// Start (arrow tail, a corner, the text's top-left, a step's centre, the magnified spot's centre).
    public var a: CGPoint
    /// End (arrow head, the opposite corner, the magnifier's loupe centre).
    public var b: CGPoint
    /// Arrow: how far its middle is pulled aside, in lengths of the arrow (0 is straight).
    public var bend: CGFloat = 0
    /// Highlighter: the stroke's points.
    public var points: [CGPoint] = []
    public var text = ""
    /// Censor: a solid bar instead of pixels.
    public var solid = false
    /// Magnifier: the magnified spot's radius, in shorter sides of the picture.
    public var radius: CGFloat = 0.06
    public var style = AnnotationStyle()

    public init(kind: Kind, a: CGPoint, b: CGPoint? = nil) {
        self.kind = kind
        self.a = a
        self.b = b ?? a
    }

    /// Each step's number: its place among the steps, in order. Deleting one renumbers the rest.
    public static func stepNumbers(_ items: [Annotation]) -> [UUID: Int] {
        var out: [UUID: Int] = [:], n = 0
        for item in items where item.kind == .step { n += 1; out[item.id] = n }
        return out
    }

    /// Kinds drawn from one corner to the other.
    public var isBox: Bool { [.rectangle, .roundedRectangle, .ellipse, .blur, .censor, .spotlight].contains(kind) }

    /// The box between `a` and `b`, in pixels.
    public func box(in space: AnnotationSpace) -> CGRect {
        let p = space.pixel(a), q = space.pixel(b)
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
    }

    /// The arrow's middle, pulled aside by `bend`: the curve's control point, in pixels.
    public func control(in space: AnnotationSpace) -> CGPoint {
        let p = space.pixel(a), q = space.pixel(b)
        let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
        let dx = q.x - p.x, dy = q.y - p.y, len = max((dx * dx + dy * dy).squareRoot(), 1e-6)
        // A quadratic's middle is halfway to its control point: twice the pull reaches `bend`.
        return CGPoint(x: mid.x - dy / len * bend * len * 2, y: mid.y + dx / len * bend * len * 2)
    }

    /// Points along the arrow's curve, in pixels.
    public func curve(in space: AnnotationSpace, steps: Int = 32) -> [CGPoint] {
        let p = space.pixel(a), q = space.pixel(b), c = control(in: space)
        return (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps), u = 1 - t
            return CGPoint(x: u * u * p.x + 2 * u * t * c.x + t * t * q.x, y: u * u * p.y + 2 * u * t * c.y + t * t * q.y)
        }
    }

    /// The text's pill, in pixels (measured the way it is drawn).
    public func textFrame(in space: AnnotationSpace) -> CGRect {
        let size = style.textSize(space.minSide)
        let lines = (text.isEmpty ? " " : text).components(separatedBy: "\n")
        let font = AnnotationStyle.font(size)
        let width = lines.map { line -> CGFloat in
            let attr = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
        }.max() ?? 0
        let origin = space.pixel(a)
        return CGRect(x: origin.x, y: origin.y, width: width + size * 0.8, height: CGFloat(lines.count) * size * 1.25 + size * 0.36)
    }

    /// The step's disc radius, in pixels.
    public func stepRadius(in space: AnnotationSpace) -> CGFloat { style.textSize(space.minSide) * 0.78 }

    /// The magnified spot and the loupe, in pixels.
    public func magnifier(in space: AnnotationSpace) -> (spot: CGPoint, r: CGFloat, loupe: CGPoint, R: CGFloat) {
        let r = radius * space.minSide
        return (space.pixel(a), r, space.pixel(b), r * 2)
    }

    /// Everything it covers, in pixels: for selection outlines.
    public func bounds(in space: AnnotationSpace) -> CGRect {
        switch kind {
        case .arrow:
            let pts = curve(in: space, steps: 12)
            return Self.enclosing(pts).insetBy(dx: -style.strokeWidth(space.minSide) * 3, dy: -style.strokeWidth(space.minSide) * 3)
        case .text: return textFrame(in: space)
        case .step:
            let c = space.pixel(a), r = stepRadius(in: space)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .highlighter:
            let w = style.strokeWidth(space.minSide) * 3
            return Self.enclosing(points.map(space.pixel)).insetBy(dx: -w, dy: -w)
        case .magnifier:
            let m = magnifier(in: space)
            return CGRect(x: m.spot.x - m.r, y: m.spot.y - m.r, width: 2 * m.r, height: 2 * m.r)
                .union(CGRect(x: m.loupe.x - m.R, y: m.loupe.y - m.R, width: 2 * m.R, height: 2 * m.R))
        default: return box(in: space)
        }
    }

    /// Whether `p` (pixels) touches it: outlines by their line, filled shapes and regions anywhere inside.
    public func hit(_ p: CGPoint, in space: AnnotationSpace, slop: CGFloat = 0) -> Bool {
        let tol = max(style.strokeWidth(space.minSide) * 1.5, space.minSide * 0.008) + slop
        switch kind {
        case .arrow: return Self.near(p, curve(in: space), tol)
        case .highlighter: return Self.near(p, points.map(space.pixel), tol + style.strokeWidth(space.minSide) * 1.5)
        case .rectangle, .roundedRectangle:
            let r = box(in: space)
            if style.filled { return r.insetBy(dx: -tol, dy: -tol).contains(p) }
            return r.insetBy(dx: -tol, dy: -tol).contains(p) && !r.insetBy(dx: tol, dy: tol).contains(p)
        case .ellipse:
            let r = box(in: space)
            let rx = max(r.width / 2, 1), ry = max(r.height / 2, 1)
            let d = (((p.x - r.midX) / rx) * ((p.x - r.midX) / rx) + ((p.y - r.midY) / ry) * ((p.y - r.midY) / ry)).squareRoot()
            return style.filled ? d <= 1 + tol / min(rx, ry) : abs(d - 1) * min(rx, ry) <= tol
        case .text: return textFrame(in: space).insetBy(dx: -tol, dy: -tol).contains(p)
        case .step:
            let c = space.pixel(a)
            return hypot(p.x - c.x, p.y - c.y) <= stepRadius(in: space) + tol
        case .magnifier:
            let m = magnifier(in: space)
            return hypot(p.x - m.spot.x, p.y - m.spot.y) <= m.r + tol || hypot(p.x - m.loupe.x, p.y - m.loupe.y) <= m.R + tol
        case .blur, .censor, .spotlight: return box(in: space).insetBy(dx: -tol, dy: -tol).contains(p)
        }
    }

    static func enclosing(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .zero }
        var r = CGRect(origin: f, size: .zero)
        for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    static func near(_ p: CGPoint, _ line: [CGPoint], _ tol: CGFloat) -> Bool {
        guard line.count > 1 else { return line.first.map { hypot(p.x - $0.x, p.y - $0.y) <= tol } ?? false }
        for i in 1..<line.count {
            let s = line[i - 1], e = line[i]
            let dx = e.x - s.x, dy = e.y - s.y, l2 = dx * dx + dy * dy
            let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - s.x) * dx + (p.y - s.y) * dy) / l2))
            if hypot(p.x - (s.x + t * dx), p.y - (s.y + t * dy)) <= tol { return true }
        }
        return false
    }
}

/// How a mark looks. Widths and text sizes are fractions of the picture's shorter side, so a mark
/// keeps its look through Enlarge and Image Size.
public struct AnnotationStyle: Equatable, Sendable {
    public struct RGBA: Equatable, Sendable {
        public var r: Double, g: Double, b: Double, a: Double
        public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
        public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        /// Light colours take dark text.
        public var isLight: Bool { 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6 }
    }

    /// Red, yellow, green, blue, white, black.
    public static let palette: [RGBA] = [RGBA(0.96, 0.26, 0.21), RGBA(1, 0.8, 0), RGBA(0.2, 0.78, 0.35), RGBA(0, 0.48, 1),
                                         RGBA(1, 1, 1), RGBA(0.08, 0.08, 0.08)]

    public enum Width: Int, CaseIterable, Sendable { case thin, regular, thick }

    public var colour = AnnotationStyle.palette[0]
    public var width = Width.regular
    public var filled = false
    public var shadow = true

    public init() {}

    public func strokeWidth(_ minSide: CGFloat) -> CGFloat { minSide * [0.004, 0.007, 0.012][width.rawValue] }
    public func textSize(_ minSide: CGFloat) -> CGFloat { minSide * [0.03, 0.042, 0.06][width.rawValue] }

    static func font(_ size: CGFloat) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
    }

    /// The colour that stands out most against `average` (what is under the mark): red, unless red
    /// would not show; then the palette colour farthest from it.
    public static func contrasting(average c: (r: Double, g: Double, b: Double)) -> RGBA {
        func distance(_ p: RGBA) -> Double { (p.r - c.r) * (p.r - c.r) + (p.g - c.g) * (p.g - c.g) + (p.b - c.b) * (p.b - c.b) }
        if distance(palette[0]) > 0.25 { return palette[0] }
        return palette[0..<4].max { distance($0) < distance($1) } ?? palette[0]
    }
}

/// Where the picture's 0…1 points (before the crop) land in the finished picture's pixels.
public struct AnnotationSpace: Equatable, Sendable {
    public var crop: CGRect
    public var size: CGSize

    public init(crop: CGRect, size: CGSize) { self.crop = crop; self.size = size }

    public var minSide: CGFloat { min(size.width, size.height) }

    public func pixel(_ u: CGPoint) -> CGPoint {
        CGPoint(x: (u.x - crop.minX) / crop.width * size.width, y: (u.y - crop.minY) / crop.height * size.height)
    }

    public func unit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / size.width * crop.width + crop.minX, y: p.y / size.height * crop.height + crop.minY)
    }
}
