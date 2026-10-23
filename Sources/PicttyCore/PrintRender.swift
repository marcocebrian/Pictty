import Accelerate
import CoreGraphics
import CoreImage
import Foundation

/// Sharpening for the paper, applied last, at the resolution sent to the printer. Ink spreads into
/// the paper and softens what the screen shows crisp; matte paper spreads it more than glossy.
public enum PrintSharpening: String, CaseIterable, Identifiable, Codable, Sendable {
    case off, low, standard, high
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .standard: "Standard"
        case .high: "High"
        }
    }
    var amount: Double {
        switch self {
        case .off: 0
        case .low: 0.35
        case .standard: 0.6
        case .high: 0.95
        }
    }
}

public enum PaperFinish: String, CaseIterable, Identifiable, Codable, Sendable {
    case glossy, matte
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .glossy: "Glossy"
        case .matte: "Matte"
        }
    }
    /// The radius at 300 ppi, in pixels: the size of a dot's spread.
    var radius: Double { self == .glossy ? 1.0 : 1.6 }
}

/// The picture made ready for paper.
public enum PrintRender {
    /// The printed part of `image` (`visible`, in its pixels, top-left origin) as the printer gets
    /// it: HDR brought into the paper's range, resampled with Lanczos to `size` when given (an
    /// enlargement with its halos held back, see `enlarged`), and sharpened for the paper at
    /// `ppi`, the resolution it is printed at.
    public static func prepare(_ image: CGImage, isHDR: Bool, visible: CGRect, size: CGSize?, ppi: Double,
                               sharpening: PrintSharpening, finish: PaperFinish) -> CGImage? {
        var picture = image
        // Paper has no headroom: highlights above white are rolled into it, not clipped.
        if isHDR || ImageDecoder.isHDR(image), let sdr = toneMapped(image) { picture = sdr }
        let bounds = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        let region = visible.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }

        let out: CGImage?
        if let size, size.width >= 1, size.height >= 1 {
            let (w, h) = (Int(size.width), Int(size.height))
            out = CGFloat(w) > region.width ? enlarged(picture, from: region, width: w, height: h)
                                            : Resampler.render(picture, from: region, width: w, height: h)
        } else {
            out = picture.cropping(to: region.integral.intersection(bounds))
        }
        guard var out else { return nil }
        if sharpening != .off { out = sharpened(out, amount: sharpening.amount, radius: finish.radius * ppi / 300) ?? out }
        return onPaperRange(out)
    }

    /// `image` as 16-bit whole numbers held to 0…1. Half float can carry values past white (a
    /// sharpened highlight); paper has nothing past white, and printer drivers expect whole numbers.
    static func onPaperRange(_ image: CGImage) -> CGImage {
        guard image.bitmapInfo.contains(.floatComponents) else { return image }
        var space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if CGColorSpaceUsesExtendedRange(space), let named = space.name {
            // Extended spaces are their standard ones carried past 0…1.
            let standard: [CFString: CFString] = [CGColorSpace.extendedSRGB: CGColorSpace.sRGB,
                                                  CGColorSpace.extendedDisplayP3: CGColorSpace.displayP3]
            if let s = standard[named].flatMap({ CGColorSpace(name: $0) }) { space = s }
        }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let info = (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return image }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// How far an enlarged pixel's overshoot is pulled back into its neighbours' range: most of the
    /// way, so edges keep Lanczos' crispness without its halo.
    static let antiRinging: Float = 0.8

    /// `region` of `image` enlarged to `width` × `height` for paper: Lanczos 3 in half float, so
    /// nothing is rounded between its passes, and then each output pixel held near the range of
    /// the four source pixels it falls between. Lanczos overshoots beside a hard edge (a light or
    /// dark line along it); enlarging makes that line wide enough to see on paper and sharpening
    /// would double it. Inside the range, gradients and texture are left exactly as Lanczos drew them.
    static func enlarged(_ image: CGImage, from region: CGRect, width: Int, height: Int) -> CGImage? {
        guard let up = Resampler.render(image, from: region, width: width, height: height, halfFloat: true),
              let format = Resampler.format(for: image, deep: true) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = region.insetBy(dx: -2, dy: -2).integral.intersection(bounds)
        guard let cropped = image.cropping(to: crop),
              var src = try? vImage_Buffer(cgImage: cropped, format: format) else { return up }
        defer { src.free() }
        guard var dst = try? vImage_Buffer(cgImage: up, format: format) else { return up }
        defer { dst.free() }

        let sw = Int(src.width), sh = Int(src.height)
        let sRow = src.rowBytes / 2, dRow = dst.rowBytes / 2
        let sp = src.data.bindMemory(to: Float16.self, capacity: sRow * sh)
        let dp = dst.data.bindMemory(to: Float16.self, capacity: dRow * height)
        let kx = Double(region.width) / Double(width), ky = Double(region.height) / Double(height)
        let ox = Double(region.minX - crop.minX), oy = Double(region.minY - crop.minY)
        // Where each output column falls in the source: the two pixels around it.
        let cols: [(Int, Int)] = (0..<width).map { x in
            let f = ox + (Double(x) + 0.5) * kx - 0.5
            let a = min(max(Int(f.rounded(.down)), 0), sw - 1)
            return (a, min(a + 1, sw - 1))
        }
        let strength = antiRinging
        let bands = 16
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            for y in (height * band / bands)..<(height * (band + 1) / bands) {
                let f = oy + (Double(y) + 0.5) * ky - 0.5
                let a = min(max(Int(f.rounded(.down)), 0), sh - 1), b = min(a + 1, sh - 1)
                let r0 = sp + a * sRow, r1 = sp + b * sRow, out = dp + y * dRow
                for x in 0..<width {
                    let (c0, c1) = (cols[x].0 * 4, cols[x].1 * 4)
                    for c in 0..<3 {
                        let p00 = Float(r0[c0 + c]), p01 = Float(r0[c1 + c]), p10 = Float(r1[c0 + c]), p11 = Float(r1[c1 + c])
                        let lo = min(min(p00, p01), min(p10, p11)), hi = max(max(p00, p01), max(p10, p11))
                        let v = Float(out[x * 4 + c])
                        let held = min(max(v, lo), hi)
                        out[x * 4 + c] = Float16(v + (held - v) * strength)
                    }
                }
            }
        }
        return (try? dst.createCGImage(format: format)) ?? up
    }

    /// An unsharp mask in the picture's own colour space and depth.
    static func sharpened(_ image: CGImage, amount: Double, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIUnsharpMask")
        filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(max(radius, 0.5), forKey: kCIInputRadiusKey)
        filter?.setValue(amount, forKey: kCIInputIntensityKey)
        guard let result = filter?.outputImage?.cropped(to: input.extent) else { return nil }
        let deep = image.bitsPerComponent > 8
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(result, from: input.extent, format: deep ? .RGBA16 : .RGBA8, colorSpace: space)
    }

    /// HDR rolled into SDR, in Display P3 at 16 bits.
    public static func toneMapped(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIToneMapHeadroom")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(max(Float(image.contentHeadroom), 1), forKey: "inputSourceHeadroom")
        filter?.setValue(Float(1), forKey: "inputTargetHeadroom")
        guard let result = filter?.outputImage, let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        return context.createCGImage(result, from: input.extent, format: .RGBA16, colorSpace: p3)
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])
}
