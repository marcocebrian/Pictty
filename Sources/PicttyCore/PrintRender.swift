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
    /// it: HDR brought into the paper's range, resampled with Lanczos to `size` when given, and
    /// sharpened for the paper at `ppi`, the resolution it is printed at.
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
            out = Resampler.render(picture, from: region, width: Int(size.width), height: Int(size.height))
        } else {
            out = picture.cropping(to: region.integral.intersection(bounds))
        }
        guard let out else { return nil }
        guard sharpening != .off else { return out }
        return sharpened(out, amount: sharpening.amount, radius: finish.radius * ppi / 300) ?? out
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
