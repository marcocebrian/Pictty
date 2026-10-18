import CoreGraphics
import Foundation
import ImageIO

public final class DecodedImage: @unchecked Sendable {
    public let url: URL
    public let image: CGImage
    /// Oriented size of the original image in pixels (independent of the decoded resolution).
    public let pixelSize: CGSize
    public let isFull: Bool
    public let frameCount: Int
    /// Pixels above SDR white (PQ/HLG, gain map, extended range): show with EDR.
    public let isHDR: Bool
    /// Set for SVG: the source every sharp raster is drawn from.
    public let vector: VectorImage?
    /// The camera's own preview inside a RAW, shown while the real develop runs.
    public let isEmbedded: Bool
    /// Every pixel of a picture larger than a GPU texture, for the settled render only.
    public let isDetail: Bool

    init(url: URL, image: CGImage, pixelSize: CGSize, isFull: Bool, frameCount: Int, vector: VectorImage? = nil,
         isEmbedded: Bool = false, isDetail: Bool = false) {
        self.url = url; self.image = image; self.pixelSize = pixelSize
        self.isFull = isFull; self.frameCount = frameCount; self.vector = vector; self.isEmbedded = isEmbedded
        self.isDetail = isDetail
        isHDR = ImageDecoder.isHDR(image)
        // Some decoders hand back RGBA for files with no transparency at all (an iPhone AVIF
        // is one, and its header does not say). The file has the last word; when it is silent,
        // the alpha values themselves are checked once.
        if !ImageDecoder.hasAlpha(image) {
            hasAlpha = false
        } else if vector != nil {
            hasAlpha = true
        } else if let declared = ImageDecoder.declaresAlpha(url) {
            hasAlpha = declared
        } else {
            hasAlpha = !ImageDecoder.isOpaque(image)
        }
    }

    /// Has an alpha channel worth honouring.
    public let hasAlpha: Bool

    public var cost: Int { image.bytesPerRow * image.height }
}

/// ImageIO decoding. ImageIO routes HEIC/AVIF/JPEG to the hardware decoders where available
/// and handles RAW through Apple's RAW engine.
public enum ImageDecoder {
    /// The GPU's largest texture side. The picture Core Animation shows is never larger; past
    /// it, `detail` decodes every pixel for the settled render, which draws the visible region.
    public static let maxTexture = 16384

    /// True when the full decode had to be capped, so `detail` has more to give.
    public static func needsDetail(_ pixelSize: CGSize) -> Bool {
        max(pixelSize.width, pixelSize.height) > CGFloat(maxTexture)
    }

    /// The whole picture, uncapped. Hundreds of megapixels can mean gigabytes; only asked for
    /// when the zoom shows more than the capped decode holds.
    public static func detail(_ url: URL) -> DecodedImage? {
        guard let src = source(url), let (size, frames) = info(src) else { return nil }
        let longest = Int(max(size.width, size.height))
        guard let img = decode(src, maxPixel: longest, allowEmbedded: false) else { return nil }
        return DecodedImage(url: url, image: img, pixelSize: size, isFull: true, frameCount: frames, isDetail: true)
    }

    static func source(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    public static func info(_ src: CGImageSource) -> (size: CGSize, frames: Int)? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return (o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h), CGImageSourceGetCount(src))
    }

    public static func hasAlpha(_ img: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(img.alphaInfo)
    }

    /// What the file itself says about transparency, from its header; nil when it does not say.
    static func declaresAlpha(_ url: URL) -> Bool? {
        guard let src = source(url),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return p[kCGImagePropertyHasAlpha] as? Bool
    }

    /// True when every alpha value of an 8-bit RGBA image is fully opaque. Other layouts are
    /// not checked and count as not opaque, so their alpha is honoured.
    static func isOpaque(_ img: CGImage) -> Bool {
        guard img.bitsPerComponent == 8, img.bitsPerPixel == 32,
              let data = img.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let little = img.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        let index: Int
        switch img.alphaInfo {
        case .premultipliedLast, .last: index = little ? 0 : 3
        case .premultipliedFirst, .first: index = little ? 3 : 0
        default: return false
        }
        let count = min(CFDataGetLength(data), img.bytesPerRow * img.height)
        for row in 0..<img.height {
            let start = row * img.bytesPerRow
            guard start + img.width * 4 <= count else { return false }
            var i = start + index
            let end = start + img.width * 4
            while i < end {
                if bytes[i] != 255 { return false }
                i += 4
            }
        }
        return true
    }

    public static func isHDR(_ img: CGImage) -> Bool {
        if #available(macOS 15, *), img.contentHeadroom > 1 { return true }
        guard let cs = img.colorSpace else { return false }
        return CGColorSpaceUsesITUR_2100TF(cs) || CGColorSpaceUsesExtendedRange(cs)
    }

    /// `hdr` asks ImageIO to apply gain maps and keep HDR range; SDR files decode unchanged.
    static func decode(_ src: CGImageSource, maxPixel: Int, allowEmbedded: Bool, hdr: Bool = true) -> CGImage? {
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            allowEmbedded ? kCGImageSourceCreateThumbnailFromImageIfAbsent
                          : kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        if hdr { opts[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// First image, sized for the screen. A RAW's first image is the camera's embedded preview,
    /// which is instant; `developed` follows with the real thing.
    /// Images close to screen size are decoded once at full resolution (`isFull`).
    public static func preview(_ url: URL, maxPixel: Int, backing: CGFloat = 2) -> DecodedImage? {
        if ImageFormats.isVector(url) { return vector(url, maxPixel: maxPixel, backing: backing) }
        guard let src = source(url), let (size, frames) = info(src) else { return nil }
        let longest = Int(max(size.width, size.height))
        if ImageFormats.isRaw(url) {
            if let img = decode(src, maxPixel: maxPixel, allowEmbedded: true) {
                return DecodedImage(url: url, image: img, pixelSize: size, isFull: false, frameCount: frames, isEmbedded: true)
            }
        } else if longest <= maxPixel * 3 / 2 {
            return full(url, src: src, size: size, frames: frames)
        }
        guard let img = decode(src, maxPixel: maxPixel, allowEmbedded: false) else { return nil }
        return DecodedImage(url: url, image: img, pixelSize: size, isFull: false, frameCount: frames)
    }

    /// SVG: one raster of the whole picture for the GPU, plus the vector for sharp renders.
    /// There is no "full" decode; the settled render draws straight from the vector.
    static func vector(_ url: URL, maxPixel: Int, backing: CGFloat) -> DecodedImage? {
        guard let v = VectorImage(url: url) else { return nil }
        let size = v.pixelSize(backing: backing)
        guard let img = v.raster(maxPixel: min(maxPixel, Int(max(size.width, size.height)))) else { return nil }
        return DecodedImage(url: url, image: img, pixelSize: size, isFull: true, frameCount: 1, vector: v)
    }

    /// A RAW developed by Apple's RAW engine at screen size: the real picture, not the camera's preview.
    public static func developed(_ url: URL, maxPixel: Int) -> DecodedImage? {
        guard let src = source(url), let (size, frames) = info(src),
              let img = decode(src, maxPixel: maxPixel, allowEmbedded: false) else { return nil }
        return DecodedImage(url: url, image: img, pixelSize: size, isFull: false, frameCount: frames)
    }

    public static func full(_ url: URL) -> DecodedImage? {
        if ImageFormats.isVector(url) { return vector(url, maxPixel: maxTexture, backing: 2) }
        guard let src = source(url), let (size, frames) = info(src) else { return nil }
        return full(url, src: src, size: size, frames: frames)
    }

    static func full(_ url: URL, src: CGImageSource, size: CGSize, frames: Int) -> DecodedImage? {
        let longest = min(Int(max(size.width, size.height)), maxTexture)
        guard let img = decode(src, maxPixel: longest, allowEmbedded: false) else { return nil }
        return DecodedImage(url: url, image: img, pixelSize: size, isFull: true, frameCount: frames)
    }

    /// Small thumbnail; embedded EXIF/RAW thumbnails are fine here.
    public static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        if ImageFormats.isVector(url) { return VectorImage(url: url)?.raster(maxPixel: maxPixel) }
        guard let src = source(url) else { return nil }
        return decode(src, maxPixel: maxPixel, allowEmbedded: true, hdr: false)
    }
}
