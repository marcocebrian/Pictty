import Accelerate
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
    /// The same pixels already in the display's colour space, for the screen alone (see
    /// `ImageDecoder.matched`); everything that measures colour keeps `image`.
    public private(set) var display: CGImage?

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

    public var cost: Int { image.bytesPerRow * image.height + (display.map { $0.bytesPerRow * $0.height } ?? 0) }

    /// The same decode, under another spelling of the same file's URL.
    public func with(url other: URL) -> DecodedImage {
        let d = DecodedImage(url: other, image: image, pixelSize: pixelSize, isFull: isFull, frameCount: frameCount, vector: vector,
                             isEmbedded: isEmbedded, isDetail: isDetail)
        d.display = display
        return d
    }

    /// Prepares `display` for a screen in `space`, before the decode is handed over.
    public func matchDisplay(to space: CGColorSpace?) {
        guard let space else { return }
        display = ImageDecoder.matched(image, to: space)
    }
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

    /// The GPU-sized full made from `detail`'s pixels in memory instead of from the file a second
    /// time: 0.3 s for a 200-megapixel map, where decoding it again at a size that is no exact
    /// fraction takes 1.2 s. nil for pixels vImage cannot scale as they are (deep, HDR, or with
    /// unpremultiplied alpha); the file is decoded again for those.
    public static func reduced(_ detail: DecodedImage) -> DecodedImage? {
        let img = detail.image
        let longest = max(img.width, img.height)
        let alpha = img.alphaInfo
        guard longest > maxTexture, img.bitsPerComponent == 8, img.bitsPerPixel == 32, !isHDR(img),
              alpha != .last, alpha != .first, let space = img.colorSpace,
              let data = img.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let k = Double(maxTexture) / Double(longest)
        let w = max(1, Int((Double(img.width) * k).rounded())), h = max(1, Int((Double(img.height) * k).rounded()))
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bytes), height: vImagePixelCount(img.height),
                                width: vImagePixelCount(img.width), rowBytes: img.bytesPerRow)
        guard let out = CFDataCreateMutable(nil, w * 4 * h) else { return nil }
        CFDataSetLength(out, w * 4 * h)
        guard let outBytes = CFDataGetMutableBytePtr(out) else { return nil }
        var dst = vImage_Buffer(data: outBytes, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        // Lanczos3, vImage's default, on every core; it does not care which byte is which channel.
        guard vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              let provider = CGDataProvider(data: out),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: img.bitmapInfo, provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        return DecodedImage(url: detail.url, image: image, pixelSize: detail.pixelSize, isFull: true, frameCount: detail.frameCount)
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

    /// An 8-bit SDR picture converted to the display's own colour space and the GPU's own pixel
    /// layout, off the main thread. Core Animation would otherwise do that conversion itself, on the
    /// CPU, on the main thread, while committing the frame: about 55 ms for 12 megapixels, all of
    /// it before the picture can appear. nil when there is nothing to gain (deep or HDR pictures,
    /// or a picture already in that space).
    public static func matched(_ img: CGImage, to space: CGColorSpace) -> CGImage? {
        guard img.bitsPerComponent == 8, img.bitsPerPixel == 32, !isHDR(img), let own = img.colorSpace,
              own.model == .rgb, own != space else { return nil }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(img.alphaInfo)
        let info = CGBitmapInfo.byteOrder32Little.rawValue
            | (opaque ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.premultipliedFirst).rawValue
        let w = img.width, h = img.height, rowBytes = w * 4
        // In bands, one per core: colour conversion runs on one core per draw, and 12 megapixels
        // on one core take 60 ms where eight bands take a fraction of it.
        guard let data = CFDataCreateMutable(nil, rowBytes * h) else { return nil }
        CFDataSetLength(data, rowBytes * h)
        guard let base = CFDataGetMutableBytePtr(data) else { return nil }
        let bands = max(1, min(ProcessInfo.processInfo.activeProcessorCount, h / 64))
        let bandHeight = (h + bands - 1) / bands
        nonisolated(unsafe) let buffer = base
        DispatchQueue.concurrentPerform(iterations: bands) { i in
            let top = i * bandHeight, rows = min(bandHeight, h - top)
            guard rows > 0, let slice = img.cropping(to: CGRect(x: 0, y: top, width: w, height: rows)),
                  let ctx = CGContext(data: buffer + top * rowBytes, width: w, height: rows, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: space, bitmapInfo: info) else { return }
            ctx.setBlendMode(.copy)
            ctx.draw(slice, in: CGRect(x: 0, y: 0, width: w, height: rows))
        }
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
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

    /// First image. A picture that fits a GPU texture is decoded whole at once (`isFull`): what
    /// shows first is every pixel, and zooming in has nothing left to load. Only a picture larger
    /// than that (a 200-megapixel map) shows a screen-sized decode first, while every pixel loads
    /// behind it. A RAW's first image is the camera's embedded preview, which is instant;
    /// `developed` follows with the real thing.
    public static func preview(_ url: URL, maxPixel: Int, backing: CGFloat = 2) -> DecodedImage? {
        if ImageFormats.isVector(url) { return vector(url, maxPixel: maxPixel, backing: backing) }
        guard let src = source(url), let (size, frames) = info(src) else { return nil }
        if ImageFormats.isRaw(url) {
            if let img = decode(src, maxPixel: maxPixel, allowEmbedded: true) {
                return DecodedImage(url: url, image: img, pixelSize: size, isFull: false, frameCount: frames, isEmbedded: true)
            }
        } else if !needsDetail(size) {
            return full(url, src: src, size: size, frames: frames)
        }
        // An exact half, quarter or eighth comes straight out of a JPEG's own transform and costs
        // about half a full decode; any other size is a full decode and a resample on top, twice
        // as slow. The smallest such fraction that still covers the screen, when there is one.
        let longest = Int(max(size.width, size.height))
        var target = maxPixel
        var fraction = longest
        while fraction % 2 == 0, fraction / 2 >= maxPixel { fraction /= 2 }
        if fraction < longest { target = fraction }
        guard let img = decode(src, maxPixel: target, allowEmbedded: false) else { return nil }
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
