import CoreGraphics
import CoreImage

/// What Remove background puts behind the subject.
public enum BackgroundFill: Equatable, Sendable {
    case transparent, white, black
    /// Encoded sRGB, 0…1.
    case colour(Double, Double, Double)
    /// The picture's own background, blurred: a portrait look.
    case blurred
}

/// The subject over its new background: `mask` (grey, white = subject, any size: it is stretched to
/// the picture) chooses, pixel by pixel, between the picture and the fill.
public enum BackgroundComposite {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func apply(_ image: CGImage, mask: CGImage, fill: BackgroundFill) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let picture = CIImage(cgImage: image)
        let extent = picture.extent
        var m = CIImage(cgImage: mask)
        if m.extent.size != extent.size {
            m = m.transformed(by: CGAffineTransform(scaleX: extent.width / m.extent.width, y: extent.height / m.extent.height))
        }
        let background: CIImage
        switch fill {
        case .transparent: background = CIImage(color: .clear).cropped(to: extent)
        case .white: background = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: space) ?? .white).cropped(to: extent)
        case .black: background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, colorSpace: space) ?? .black).cropped(to: extent)
        case let .colour(r, g, b):
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            background = CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: srgb) ?? .gray).cropped(to: extent)
        case .blurred:
            let radius = max(2, 0.015 * max(extent.width, extent.height))
            background = picture.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        }
        let out = picture.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: m,
        ])
        let deep = image.bitsPerComponent > 8
        return context.createCGImage(out, from: extent, format: deep ? .RGBAh : .RGBA8, colorSpace: space)
    }
}
