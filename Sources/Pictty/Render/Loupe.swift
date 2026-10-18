import AppKit
import PicttyCore
import QuartzCore

/// The ⌥ loupe: the picture's own pixels under the pointer, magnified without smoothing, with
/// the centre pixel's colour.
@MainActor
final class Loupe {
    static let grid = 15
    static let diameter: CGFloat = 150

    /// The colour under the pointer, sRGB.
    struct Sample: Equatable {
        var red: Int, green: Int, blue: Int
        var x: Int, y: Int
        var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    }

    let root = CALayer()
    private let lens = CALayer()
    private let pixels = CALayer()
    private let crosshair = CALayer()
    private let label = CATextLayer()
    private(set) var sample: Sample?

    init() {
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                                        "hidden": NSNull(), "string": NSNull(), "frame": NSNull()]
        for l in [root, lens, pixels, crosshair, label] { l.actions = none }
        root.isHidden = true
        root.zPosition = 20
        root.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter + 34)

        lens.frame = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        lens.cornerRadius = Self.diameter / 2
        lens.masksToBounds = true
        lens.borderWidth = 2.5
        lens.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        lens.backgroundColor = NSColor.black.cgColor

        pixels.frame = lens.bounds
        pixels.magnificationFilter = .nearest
        pixels.contentsGravity = .resize
        lens.addSublayer(pixels)

        let cell = Self.diameter / CGFloat(Self.grid)
        crosshair.frame = CGRect(x: (Self.diameter - cell) / 2, y: (Self.diameter - cell) / 2, width: cell, height: cell)
        crosshair.borderWidth = 1.5
        crosshair.borderColor = NSColor.white.cgColor
        crosshair.shadowOpacity = 0.8
        crosshair.shadowRadius = 1.5
        crosshair.shadowOffset = .zero
        lens.addSublayer(crosshair)

        // The lens's shadow lives on the root, which does not clip.
        root.shadowOpacity = 0.55
        root.shadowRadius = 12
        root.shadowOffset = CGSize(width: 0, height: 4)
        root.shadowPath = CGPath(ellipseIn: lens.frame, transform: nil)
        root.addSublayer(lens)

        label.frame = CGRect(x: -20, y: Self.diameter + 8, width: Self.diameter + 40, height: 22)
        label.alignmentMode = .center
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.fontSize = 11
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = NSColor(white: 0.06, alpha: 0.82).cgColor
        label.cornerRadius = 11
        label.isWrapped = false
        root.addSublayer(label)
    }

    func hide() {
        root.isHidden = true
        sample = nil
    }

    /// Shows the pixels of `source` around (`x`, `y`), in `source`'s own pixels, at `point`.
    func show(_ source: CGImage, x: Int, y: Int, original: CGPoint, at point: CGPoint, in bounds: CGRect, scale: CGFloat) {
        let n = Self.grid
        let half = n / 2
        let crop = CGRect(x: x - half, y: y - half, width: n, height: n)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }
        ctx.interpolationQuality = .none
        // Bottom-up context: the source's row y lands at n-1-(y-crop.minY).
        let inside = crop.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        if !inside.isNull, let part = source.cropping(to: inside) {
            ctx.draw(part, in: CGRect(x: inside.minX - crop.minX, y: crop.maxY - inside.maxY,
                                      width: inside.width, height: inside.height))
        }
        guard let image = ctx.makeImage() else { return }
        // The centre pixel, unpremultiplied.
        let o = (half * n + half) * 4
        let a = max(1, Int(data[o + 3]))
        let un = { (v: UInt8) in min(255, Int(v) * 255 / a) }
        let s = Sample(red: un(data[o]), green: un(data[o + 1]), blue: un(data[o + 2]), x: Int(original.x), y: Int(original.y))
        sample = s

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.contentsScale = scale
        label.contentsScale = scale
        pixels.contents = image
        let text = data[o + 3] == 0 ? L("transparent · %ld, %ld", s.x, s.y)
            : "\(s.red) \(s.green) \(s.blue)  \(s.hex)  ·  \(s.x), \(s.y)"
        label.string = text
        // As wide as the text needs (five-digit coordinates do not fit the lens), centred under it.
        let width = max(Self.diameter, ceil((text as NSString).size(
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]).width) + 22)
        label.frame = CGRect(x: (Self.diameter - width) / 2, y: Self.diameter + 8, width: width, height: 22)
        // Up and to the right of the pointer, kept inside the window.
        var origin = CGPoint(x: point.x + 24, y: point.y - Self.diameter - 24)
        if origin.x + Self.diameter > bounds.maxX - 8 { origin.x = point.x - Self.diameter - 24 }
        if origin.y < bounds.minY + 8 { origin.y = point.y + 24 }
        root.frame = CGRect(origin: origin, size: root.bounds.size)
        root.isHidden = false
        CATransaction.commit()
    }
}
