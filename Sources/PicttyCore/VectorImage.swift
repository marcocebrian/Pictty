import AppKit
import CoreGraphics

/// An SVG, kept as a vector. AppKit parses it natively; every raster of it is drawn fresh at the
/// exact size asked for, so it is sharp at any zoom rather than resampled.
public final class VectorImage: @unchecked Sendable {
    /// The SVG representation itself. Drawing it directly is several times faster than going
    /// through `NSImage`, and never comes from a cached bitmap of another size.
    private let rep: NSImageRep
    /// Intrinsic size in CSS pixels.
    public let size: CGSize
    private let lock = NSLock()

    public init?(url: URL) {
        guard let image = NSImage(contentsOf: url), let rep = image.representations.first,
              rep.size.width > 0, rep.size.height > 0 else { return nil }
        self.rep = rep
        size = rep.size
    }

    /// The picture's pixel size for zoom purposes: one CSS pixel per point, as a browser shows it
    /// on this display, so "Actual Size" matches the web.
    public func pixelSize(backing: CGFloat) -> CGSize {
        CGSize(width: (size.width * backing).rounded(), height: (size.height * backing).rounded())
    }

    /// Draws `rect` of a `canvas`-sized raster of the picture (top-left coordinates) into a
    /// `width × height` image. Transparent where the SVG is.
    public func render(_ rect: CGRect, of canvas: CGSize, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, canvas.width > 0, canvas.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sx = CGFloat(width) / rect.width, sy = CGFloat(height) / rect.height
        // Bottom-up CG space: the picture's full raster sits at -rect.origin, flipped.
        let full = CGRect(x: -rect.minX * sx, y: -(canvas.height - rect.maxY) * sy,
                          width: canvas.width * sx, height: canvas.height * sy)
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        lock.lock()
        defer { lock.unlock() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        rep.draw(in: full)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// The whole picture, longest side `maxPixel`.
    public func raster(maxPixel: Int) -> CGImage? {
        let k = CGFloat(maxPixel) / max(size.width, size.height)
        let w = max(1, Int((size.width * k).rounded())), h = max(1, Int((size.height * k).rounded()))
        return render(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)), of: CGSize(width: w, height: h), width: w, height: h)
    }
}
