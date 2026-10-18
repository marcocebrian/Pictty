import Accelerate
import CoreGraphics

/// Exact-size Lanczos rendering of a region of an image, for the settled view.
///
/// While the picture moves, Core Animation filters it on the GPU (trilinear down, bilinear up).
/// Once it rests, the visible region is rendered here at exactly one output pixel per device
/// pixel, so the compositor shows it 1:1 with no further filtering. Trilinear blends two box-
/// filtered mip levels and goes soft between them; bilinear magnification is soft too. Lanczos
/// is sharp in both directions without the aliasing of a plain linear filter.
///
/// Separable: one horizontal and one vertical vImage shear pass, each with a fractional
/// translation, so the output lands on the source with sub-pixel precision rather than
/// rounded to whole crops.
public enum Resampler {
    public enum Kernel: Sendable {
        /// Lanczos3: sharp, no aliasing. The default.
        case lanczos
        /// Tent: exact bilinear, the look Pictty has always had above 300 %.
        case linear
    }

    /// Renders `rect` (continuous source-pixel coordinates, top-left origin) into a
    /// `width × height` image.
    ///
    /// Shrinking is done in linear light: the pixels are converted to linear half float by
    /// colour management, filtered there, and converted back. Averaging gamma-encoded values
    /// darkens fine high-contrast detail (a black and white checkerboard shrinks to 128 instead
    /// of the 188 the eye expects); averaging light does not. Enlarging stays in the encoded
    /// space, which is what looks right there. Deep or HDR sources stay half float in their
    /// own colour space with their content headroom; 8-bit sources come back 8-bit.
    public static func render(_ source: CGImage, from rect: CGRect, width: Int, height: Int,
                              kernel: Kernel = .lanczos, linearLight: Bool = true) -> CGImage? {
        guard width > 0, height > 0, rect.width > 0, rect.height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let sx = Double(width) / rect.width, sy = Double(height) / rect.height

        // Lanczos3 reaches 3 source pixels when enlarging and 3 output pixels (3/s source
        // pixels) when shrinking; beyond the image the edge is extended.
        let pad = ceil(3 / min(sx, sy, 1)) + 2
        let crop = rect.insetBy(dx: -pad, dy: -pad).integral.intersection(bounds)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1, let cropped = source.cropping(to: crop) else { return nil }

        let deep = source.bitsPerComponent > 8 || ImageDecoder.isHDR(source)
        let linear = linearLight && (sx < 1 || sy < 1)
        let half = deep || linear
        guard var work = Self.format(for: source, deep: half, linearized: linear),
              var src = try? vImage_Buffer(cgImage: cropped, format: work) else { return nil }
        defer { src.free() }
        let bpp = Int(work.bitsPerPixel)

        guard var mid = try? vImage_Buffer(width: width, height: Int(crop.height), bitsPerPixel: UInt32(bpp)) else { return nil }
        defer { mid.free() }
        guard var dst = try? vImage_Buffer(width: width, height: height, bitsPerPixel: UInt32(bpp)) else { return nil }

        // Horizontal: dst = src·s + t. Vertical is anchored at the bottom edge:
        // dst = H − s·(H − src) − t, so t = H·(1 − s) − T for a top-down offset T.
        let tx = Float((crop.minX - rect.minX) * sx)
        let ty = Float(Double(height) * (1 - sy) - (crop.minY - rect.minY) * sy)
        let hFilter = Filter(scale: Float(sx), kernel: kernel), vFilter = Filter(scale: Float(sy), kernel: kernel)
        let flags = vImage_Flags(kvImageEdgeExtend)

        let ok: Bool
        if half {
            var back: [Pixel_16F] = [0, 0, 0, 0]
            ok = vImageHorizontalShear_ARGB16F(&src, &mid, 0, 0, tx, 0, hFilter.ref, &back, flags) == kvImageNoError
                && vImageVerticalShear_ARGB16F(&mid, &dst, 0, 0, ty, 0, vFilter.ref, &back, flags) == kvImageNoError
        } else {
            var back: [Pixel_8] = [0, 0, 0, 0]
            ok = vImageHorizontalShear_ARGB8888(&src, &mid, 0, 0, tx, 0, hFilter.ref, &back, flags) == kvImageNoError
                && vImageVerticalShear_ARGB8888(&mid, &dst, 0, 0, ty, 0, vFilter.ref, &back, flags) == kvImageNoError
        }
        guard ok, var image = makeImage(&dst, format: &work) else { dst.free(); return nil }

        // An 8-bit source filtered in linear light goes back to its own 8-bit encoding, so the
        // settled render costs no more memory than before.
        if linear, !deep, var out = Self.format(for: source, deep: false, linearized: false),
           var back = try? vImage_Buffer(cgImage: image, format: out) {
            guard let encoded = makeImage(&back, format: &out) else { back.free(); return nil }
            image = encoded
        }
        if #available(macOS 15, *), source.contentHeadroom > 1 {
            return CGImageCreateCopyWithContentHeadroom(source.contentHeadroom, image) ?? image
        }
        return image
    }

    /// A resampling filter for one axis, freed with the value.
    private final class Filter {
        let ref: ResamplingFilter
        private let custom: UnsafeMutableRawPointer?

        init(scale: Float, kernel: Kernel) {
            switch kernel {
            case .lanczos:
                ref = vImageNewResamplingFilter(scale, vImage_Flags(kvImageNoFlags))
                custom = nil
            case .linear:
                let tent: @convention(c) (UnsafePointer<Float>?, UnsafeMutablePointer<Float>?, UInt, UnsafeMutableRawPointer?) -> Void = { x, y, n, _ in
                    guard let x, let y else { return }
                    for i in 0..<Int(n) { y[i] = max(0, 1 - abs(x[i])) }
                }
                let size = vImageGetResamplingFilterSize(scale, tent, 1, vImage_Flags(kvImageNoFlags))
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 16)
                vImageNewResamplingFilterForFunctionUsingBuffer(buffer, scale, tent, 1, nil, vImage_Flags(kvImageNoFlags))
                ref = ResamplingFilter(buffer)
                custom = buffer
            }
        }

        deinit {
            if let custom { custom.deallocate() } else { vImageDestroyResamplingFilter(ref) }
        }
    }

    /// RGBA in the source's own colour space when it is RGB (so colour management is
    /// unchanged), otherwise sRGB; `linearized` takes the same space without its transfer
    /// curve. Premultiplied only when the source has alpha.
    static func format(for source: CGImage, deep: Bool, linearized: Bool = false) -> vImage_CGImageFormat? {
        var space: CGColorSpace
        if let cs = source.colorSpace, cs.model == .rgb { space = cs }
        else if let cs = CGColorSpace(name: deep ? CGColorSpace.extendedSRGB : CGColorSpace.sRGB) { space = cs }
        else { return nil }
        if linearized, let lin = CGColorSpaceCreateExtendedLinearized(space) { space = lin }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(source.alphaInfo)
        let alpha = (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
        let info = deep ? alpha | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue : alpha
        return vImage_CGImageFormat(bitsPerComponent: deep ? 16 : 8, bitsPerPixel: deep ? 64 : 32,
                                    colorSpace: space, bitmapInfo: CGBitmapInfo(rawValue: info))
    }

    /// Hands the buffer to the image without a copy when vImage accepts the format, else copies.
    /// Either way `buffer` is owned by the result (or freed) afterwards.
    private static func makeImage(_ buffer: inout vImage_Buffer, format: inout vImage_CGImageFormat) -> CGImage? {
        var error = kvImageNoError
        if let image = vImageCreateCGImageFromBuffer(&buffer, &format, nil, nil, vImage_Flags(kvImageNoAllocate), &error) {
            return image.takeRetainedValue()
        }
        defer { buffer.free() }
        return vImageCreateCGImageFromBuffer(&buffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)?
            .takeRetainedValue()
    }
}

/// Where the settled render goes. Pure geometry so it can be tested without a window.
public enum RefineMath {
    /// The region to render, in the layer's own pixel grid (`layerPixels` is the whole picture
    /// at the current zoom, unrotated): the visible part plus `margin` of the pane on each side
    /// so small pans stay sharp, clipped to the picture, on whole pixels.
    public static func region(visible: CGRect, layerPixels: CGSize, margin: CGFloat) -> CGRect? {
        let m = CGSize(width: visible.width * margin, height: visible.height * margin)
        let r = visible.insetBy(dx: -m.width, dy: -m.height)
            .intersection(CGRect(origin: .zero, size: layerPixels)).integral
            .intersection(CGRect(origin: .zero, size: layerPixels))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        return r
    }

    /// The same region in source-image pixels, for a source of `sourcePixels` stretched over
    /// `layerPixels` (exactly what the compositor does with the base layer).
    public static func sourceRect(for region: CGRect, layerPixels: CGSize, sourcePixels: CGSize) -> CGRect {
        let kx = sourcePixels.width / layerPixels.width, ky = sourcePixels.height / layerPixels.height
        return CGRect(x: region.minX * kx, y: region.minY * ky, width: region.width * kx, height: region.height * ky)
    }

    /// True when the rendered region still covers what is on screen.
    public static func covers(_ region: CGRect, visible: CGRect, layerPixels: CGSize) -> Bool {
        let needed = visible.intersection(CGRect(origin: .zero, size: layerPixels))
        return needed.isNull || region.insetBy(dx: -0.5, dy: -0.5).contains(needed)
    }
}
