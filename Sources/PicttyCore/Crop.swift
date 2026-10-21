import CoreGraphics
import Foundation

/// A crop, kept in the file's own pixels: a rectangle in 0…1 coordinates of the stored picture
/// (top-left origin, before any turn or mirror), and a radius for each of its corners. Turning the
/// picture afterwards turns the crop with it.
public struct CropBox: Equatable, Sendable {
    public var rect: CGRect
    /// Each corner's radius as a share of the crop's shorter side (0…0.5), in stored order:
    /// top-left, top-right, bottom-right, bottom-left.
    public var radii: [Double]

    public init(rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), radii: [Double] = [0, 0, 0, 0]) {
        self.rect = rect
        self.radii = radii
    }

    public var isRounded: Bool { radii.contains { $0 > 0 } }
    public var isWhole: Bool { rect.equalTo(CGRect(x: 0, y: 0, width: 1, height: 1)) && !isRounded }

    /// The crop in pixels of a stored picture `size`, whole pixels, never empty.
    public func pixelRect(in size: CGSize) -> CGRect {
        let x0 = (rect.minX * size.width).rounded(), y0 = (rect.minY * size.height).rounded()
        let x1 = (rect.maxX * size.width).rounded(), y1 = (rect.maxY * size.height).rounded()
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    /// The size the cropped picture has, in pixels of a stored picture `size`.
    public func croppedSize(_ size: CGSize) -> CGSize { pixelRect(in: size).size }

    /// `image` (a stored-orientation picture of any resolution) cropped, its corners rounded into
    /// transparency.
    public func apply(to image: CGImage) -> CGImage? {
        let r = pixelRect(in: CGSize(width: image.width, height: image.height))
        guard let cropped = image.cropping(to: r) else { return nil }
        guard isRounded else { return cropped }
        let w = cropped.width, h = cropped.height
        let float = cropped.bitsPerComponent > 8 || ImageDecoder.isHDR(cropped)
        let space = float ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! : (cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if float { info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: float ? 16 : 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        // Bottom-up here: the stored top-left corner is the context's top-left, at maxY.
        ctx.addPath(Self.path(CGRect(x: 0, y: 0, width: w, height: h), radii: radii.map { $0 * Double(min(w, h)) }, flipped: true))
        ctx.clip()
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        if cropped.contentHeadroom > 1 { return CGImageCreateCopyWithContentHeadroom(cropped.contentHeadroom, out) ?? out }
        return out
    }

    /// A rectangle with its own radius at each corner (top-left, top-right, bottom-right, bottom-left
    /// on screen). `flipped`: the coordinates are bottom-up, as in a Core Graphics context.
    public static func path(_ r: CGRect, radii raw: [Double], flipped: Bool = false) -> CGPath {
        let limit = min(r.width, r.height) / 2
        let c = raw.map { min(CGFloat($0), limit) } + Array(repeating: 0, count: max(0, 4 - raw.count))
        // Corners in drawing order, as (point, radius); "top" is maxY when flipped.
        let top = flipped ? r.maxY : r.minY, bottom = flipped ? r.minY : r.maxY
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + c[0], y: top))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: top), tangent2End: CGPoint(x: r.maxX, y: bottom), radius: c[1])
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: bottom), tangent2End: CGPoint(x: r.minX, y: bottom), radius: c[2])
        p.addArc(tangent1End: CGPoint(x: r.minX, y: bottom), tangent2End: CGPoint(x: r.minX, y: top), radius: c[3])
        p.addArc(tangent1End: CGPoint(x: r.minX, y: top), tangent2End: CGPoint(x: r.maxX, y: top), radius: c[0])
        p.closeSubpath()
        return p
    }
}

/// Between the stored picture and the one on screen: a quarter-turn count (clockwise) and a mirror,
/// acting on 0…1 coordinates.
public struct Orient: Equatable, Sendable {
    public var quarterTurns: Int
    public var mirror: Bool

    public init(quarterTurns: Int = 0, mirror: Bool = false) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.mirror = mirror
    }

    /// Stored → on screen. Turned first, then mirrored, as the canvas does.
    public func display(_ u: CGPoint) -> CGPoint {
        var c = CGPoint(x: u.x - 0.5, y: u.y - 0.5)
        for _ in 0..<quarterTurns { c = CGPoint(x: -c.y, y: c.x) }
        if mirror { c.x = -c.x }
        return CGPoint(x: c.x + 0.5, y: c.y + 0.5)
    }

    /// On screen → stored.
    public func stored(_ u: CGPoint) -> CGPoint {
        var c = CGPoint(x: u.x - 0.5, y: u.y - 0.5)
        if mirror { c.x = -c.x }
        for _ in 0..<quarterTurns { c = CGPoint(x: c.y, y: -c.x) }
        return CGPoint(x: c.x + 0.5, y: c.y + 0.5)
    }

    public func display(_ r: CGRect) -> CGRect { Self.bounds(display(r.origin), display(CGPoint(x: r.maxX, y: r.maxY))) }
    public func stored(_ r: CGRect) -> CGRect { Self.bounds(stored(r.origin), stored(CGPoint(x: r.maxX, y: r.maxY))) }

    public static func bounds(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Which stored corner (0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left) shows at
    /// on-screen corner `i`.
    public func storedCorner(_ i: Int) -> Int {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let s = stored(corners[i])
        return corners.firstIndex { abs($0.x - s.x) < 0.01 && abs($0.y - s.y) < 0.01 } ?? i
    }

    /// Radii in on-screen corner order, from stored order.
    public func displayRadii(_ stored: [Double]) -> [Double] { (0..<4).map { stored[storedCorner($0)] } }

    /// Radii in stored order, from on-screen order.
    public func storedRadii(_ display: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 4)
        for i in 0..<4 { out[storedCorner(i)] = display[i] }
        return out
    }
}

/// Aspect ratios for the crop menu, grouped the way people look for them.
public struct CropRatio: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Width over height as named (a portrait ratio is below 1); nil is free, 0 the picture's own. The crop toolbar swaps it.
    public let value: Double?
    public let detail: String

    public static let free = CropRatio(id: "free", name: "Free", value: nil, detail: "")
    public static let original = CropRatio(id: "original", name: "Original", value: 0, detail: "")

    public static let groups: [(title: String, ratios: [CropRatio])] = [
        ("", [free, original]),
        ("Common", [
            CropRatio(id: "1:1", name: "Square", value: 1, detail: "1:1"),
            CropRatio(id: "3:2", name: "3:2", value: 3.0 / 2, detail: "35 mm"),
            CropRatio(id: "4:3", name: "4:3", value: 4.0 / 3, detail: "Micro Four Thirds, iPad"),
            CropRatio(id: "5:4", name: "5:4", value: 5.0 / 4, detail: "8 × 10 in"),
            CropRatio(id: "16:9", name: "16:9", value: 16.0 / 9, detail: "HD, 4K"),
            CropRatio(id: "16:10", name: "16:10", value: 16.0 / 10, detail: "Mac displays"),
            CropRatio(id: "2:1", name: "2:1", value: 2, detail: "Univisium"),
            CropRatio(id: "21:9", name: "21:9", value: 21.0 / 9, detail: "Ultrawide, cinema"),
        ]),
        ("Social", [
            CropRatio(id: "ig-square", name: "Instagram post", value: 1, detail: "1080 × 1080"),
            CropRatio(id: "ig-portrait", name: "Instagram portrait", value: 4.0 / 5, detail: "1080 × 1350"),
            CropRatio(id: "ig-landscape", name: "Instagram landscape", value: 1.91, detail: "1080 × 566"),
            CropRatio(id: "stories", name: "Stories, Reels, TikTok, Shorts", value: 9.0 / 16, detail: "1080 × 1920"),
            CropRatio(id: "youtube", name: "YouTube thumbnail", value: 16.0 / 9, detail: "1280 × 720"),
            CropRatio(id: "x-post", name: "X post", value: 16.0 / 9, detail: "1600 × 900"),
            CropRatio(id: "x-header", name: "X header", value: 3, detail: "1500 × 500"),
            CropRatio(id: "fb-cover", name: "Facebook cover", value: 820.0 / 312, detail: "820 × 312"),
            CropRatio(id: "linkedin", name: "LinkedIn banner", value: 4, detail: "1584 × 396"),
            CropRatio(id: "pinterest", name: "Pinterest pin", value: 2.0 / 3, detail: "1000 × 1500"),
        ]),
        ("Screens", [
            CropRatio(id: "iphone", name: "iPhone wallpaper", value: 9.0 / 19.5, detail: "1179 × 2556"),
            CropRatio(id: "ipad", name: "iPad wallpaper", value: 3.0 / 4, detail: "2048 × 2732"),
            CropRatio(id: "mac", name: "Mac desktop", value: 16.0 / 10, detail: "2880 × 1800"),
            CropRatio(id: "4k", name: "4K and HD screens", value: 16.0 / 9, detail: "3840 × 2160"),
            CropRatio(id: "watch", name: "Apple Watch face", value: 396.0 / 484, detail: "396 × 484"),
        ]),
        ("Print", [
            CropRatio(id: "a4", name: "A4, A3, A5", value: 1 / 2.0.squareRoot(), detail: "ISO 216"),
            CropRatio(id: "letter", name: "US Letter", value: 8.5 / 11, detail: "8.5 × 11 in"),
            CropRatio(id: "4x6", name: "4 × 6 in", value: 4.0 / 6, detail: "10 × 15 cm"),
            CropRatio(id: "5x7", name: "5 × 7 in", value: 5.0 / 7, detail: "13 × 18 cm"),
            CropRatio(id: "8x10", name: "8 × 10 in", value: 8.0 / 10, detail: "20 × 25 cm"),
        ]),
    ]

    public static let all: [CropRatio] = groups.flatMap(\.ratios)

    public static func with(id: String) -> CropRatio { all.first { $0.id == id } ?? free }
}
