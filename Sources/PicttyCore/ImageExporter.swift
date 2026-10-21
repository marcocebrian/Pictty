import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writing pictures: Save over the original and Save As in any format ImageIO can encode on this
/// Mac, with every setting in plain sight.
public enum ExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case jpeg, heic, avif, jpegxl, jpeg2000, png, tiff, exr

    public var id: String { rawValue }

    public var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heic: .heic
        case .avif: UTType("public.avif") ?? .heic
        case .jpegxl: UTType("public.jpeg-xl") ?? .jpeg
        case .jpeg2000: UTType("public.jpeg-2000") ?? .jpeg
        case .png: .png
        case .tiff: .tiff
        case .exr: UTType("com.ilm.openexr-image") ?? .tiff
        }
    }

    public var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .jpegxl: "JPEG XL"
        case .jpeg2000: "JPEG 2000"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .exr: "OpenEXR"
        }
    }

    public var fileExtension: String { type.preferredFilenameExtension ?? rawValue }

    public var isLossy: Bool { [.jpeg, .heic, .avif, .jpegxl, .jpeg2000].contains(self) }
    public var keepsAlpha: Bool { self != .jpeg }
    public var depths: [ExportDepth] {
        switch self {
        case .png, .jpeg2000: [.eight, .sixteen]
        case .tiff: [.eight, .sixteen, .float]
        case .exr: [.float]
        case .heic, .avif, .jpegxl: [.eight, .ten]
        case .jpeg: [.eight]
        }
    }
    /// Can carry HDR: a gain map, or the HDR pixels themselves.
    public var carriesHDR: Bool { [.heic, .avif, .jpeg, .jpegxl].contains(self) }
    /// Linear floating point light: HDR as it is, with no tone mapping or gain map.
    public var isSceneLinear: Bool { self == .exr }

    /// The formats this Mac can write, in menu order.
    public static var writable: [ExportFormat] {
        let ids = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return allCases.filter { ids.contains($0.type.identifier) }
    }

    /// The format a file already is, if Pictty can write it back.
    public init?(fileType: UTType) {
        guard let f = Self.writable.first(where: { fileType.conforms(to: $0.type) }) else { return nil }
        self = f
    }
}

public enum ExportDepth: String, CaseIterable, Identifiable, Codable, Sendable {
    case eight, ten, sixteen, float
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .eight: "8-bit"
        case .ten: "10-bit"
        case .sixteen: "16-bit"
        case .float: "32-bit float"
        }
    }
}

public enum ExportColorSpace: String, CaseIterable, Identifiable, Codable, Sendable {
    case original, sRGB, displayP3, adobeRGB, proPhoto, rec2020
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .original: "Same as the original"
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .adobeRGB: "Adobe RGB (1998)"
        case .proPhoto: "ProPhoto RGB"
        case .rec2020: "Rec. 2020"
        }
    }
    var name: CFString? {
        switch self {
        case .original: nil
        case .sRGB: CGColorSpace.sRGB
        case .displayP3: CGColorSpace.displayP3
        case .adobeRGB: CGColorSpace.adobeRGB1998
        case .proPhoto: CGColorSpace.rommrgb
        case .rec2020: CGColorSpace.itur_2020
        }
    }
}

public enum ExportMetadata: String, CaseIterable, Identifiable, Codable, Sendable {
    case all, withoutLocation, none
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "Keep all"
        case .withoutLocation: "Keep, without location"
        case .none: "Remove all"
        }
    }
}

public enum ExportHDR: String, CaseIterable, Identifiable, Codable, Sendable {
    case gainMap, hdr, sdr
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .gainMap: "SDR picture with an HDR gain map"
        case .hdr: "HDR pixels (ISO HDR)"
        case .sdr: "Tone-mapped to SDR"
        }
    }
}

public enum ExportCompression: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, lzw, packBits
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: "None"
        case .lzw: "LZW"
        case .packBits: "PackBits"
        }
    }
    var tiffValue: Int {
        switch self {
        case .none: 1
        case .lzw: 5
        case .packBits: 32773
        }
    }
}

public struct ExportOptions: Equatable, Codable, Sendable {
    public var format: ExportFormat = .jpeg
    /// 0…1, lossy formats.
    public var quality: Double = 0.9
    public var depth: ExportDepth = .eight
    public var colorSpace: ExportColorSpace = .original
    public var metadata: ExportMetadata = .all
    /// Longest side in pixels; nil keeps the size.
    public var longEdge: Int?
    public var progressive = false
    public var embedThumbnail = false
    public var compression: ExportCompression = .lzw
    public var hdr: ExportHDR = .gainMap
    /// What a JPEG puts behind transparent pixels.
    public var matteWhite = true
    /// Save over a JPEG: re-encode at the quality the original was made with, read from its tables.
    public var matchQuality = false

    public init() {}
}

public enum ImageExporter {
    public enum Failure: LocalizedError {
        case cannotCreate, cannotEncode, cannotConvert
        public var errorDescription: String? {
            switch self {
            case .cannotCreate: "The file could not be created."
            case .cannotEncode: "The picture could not be encoded."
            case .cannotConvert: "The picture could not be converted."
            }
        }
    }

    /// Writes `image` (already upright, any colour space) to `url`. Metadata is copied from
    /// `original` when the options keep it; the orientation tag is reset, because the pixels are
    /// upright now. Written beside the destination first and moved over it, so a failure never
    /// leaves half a file where a picture was.
    public static func write(_ image: CGImage, isHDR: Bool, original: URL?, to url: URL, options o: ExportOptions) throws {
        var picture = image
        if let edge = o.longEdge, edge > 0, max(image.width, image.height) > edge {
            let k = Double(edge) / Double(max(image.width, image.height))
            let w = max(1, Int((Double(image.width) * k).rounded())), h = max(1, Int((Double(image.height) * k).rounded()))
            guard let scaled = Resampler.render(image, from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                                width: w, height: h) else { throw Failure.cannotConvert }
            picture = scaled
        }

        let keepHDR = (isHDR && o.format.carriesHDR && o.hdr != .sdr) || o.format.isSceneLinear
        guard let converted = convert(picture, options: o, sourceSpace: image.colorSpace, keepHDR: keepHDR)
        else { throw Failure.cannotConvert }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-pictty-\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, o.format.type.identifier as CFString, 1, nil)
        else { throw Failure.cannotCreate }

        var props: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if o.format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = o.quality }
        if o.embedThumbnail { props[kCGImageDestinationEmbedThumbnail] = true }
        if o.format == .jpeg, o.progressive { props[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
        if o.format == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: o.compression.tiffValue] }
        if isHDR, o.format.carriesHDR {
            props[kCGImageDestinationEncodeRequest] = switch o.hdr {
            case .gainMap: kCGImageDestinationEncodeToISOGainmap
            case .hdr: kCGImageDestinationEncodeToISOHDR
            case .sdr: kCGImageDestinationEncodeToSDR
            }
        }

        if o.metadata != .none, let original, let src = CGImageSourceCreateWithURL(original as CFURL, nil),
           let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let mutable = CGImageMetadataCreateMutableCopy(meta) {
            CGImageMetadataSetValueMatchingImageProperty(mutable, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(mutable, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension,
                                                         converted.width as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(mutable, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension,
                                                         converted.height as CFNumber)
            if o.metadata == .withoutLocation { removeLocation(mutable) }
            CGImageDestinationAddImageAndMetadata(dest, converted, mutable, props as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, converted, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: temp)
            throw Failure.cannotEncode
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    /// How many bytes `image` takes encoded with `o`, measured by encoding it in memory (no
    /// metadata): a sample of the picture, for the file-size estimate.
    public static func encodedSize(_ image: CGImage, isHDR: Bool, options o: ExportOptions) -> Int? {
        let keepHDR = (isHDR && o.format.carriesHDR && o.hdr != .sdr) || o.format.isSceneLinear
        guard let converted = convert(image, options: o, sourceSpace: image.colorSpace, keepHDR: keepHDR) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, o.format.type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if o.format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = o.quality }
        if o.format == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: o.compression.tiffValue] }
        if isHDR, o.format.carriesHDR {
            props[kCGImageDestinationEncodeRequest] = switch o.hdr {
            case .gainMap: kCGImageDestinationEncodeToISOGainmap
            case .hdr: kCGImageDestinationEncodeToISOHDR
            case .sdr: kCGImageDestinationEncodeToSDR
            }
        }
        CGImageDestinationAddImage(dest, converted, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data.length : nil
    }

    /// Into the colour space, bit depth and alpha the options ask for.
    static func convert(_ image: CGImage, options o: ExportOptions, sourceSpace: CGColorSpace?, keepHDR: Bool) -> CGImage? {
        let w = image.width, h = image.height
        let depth = o.format.depths.contains(o.depth) ? o.depth : .eight
        let alpha = o.format.keepsAlpha && ImageDecoder.hasAlpha(image)

        var space: CGColorSpace?
        if o.format.isSceneLinear {
            space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        } else if keepHDR {
            space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        } else if let name = o.colorSpace.name {
            space = CGColorSpace(name: name)
        } else if let s = sourceSpace, s.model == .rgb, !CGColorSpaceUsesExtendedRange(s), !CGColorSpaceUsesITUR_2100TF(s) {
            space = s
        } else {
            space = CGColorSpace(name: CGColorSpace.displayP3)
        }
        guard let space else { return nil }

        let float = keepHDR || depth == .float
        let bits = float ? (depth == .float ? 32 : 16) : (depth == .eight ? 8 : 16)
        var info: UInt32 = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        if float { info |= CGBitmapInfo.floatComponents.rawValue }
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        if bits == 32 { info |= CGBitmapInfo.byteOrder32Little.rawValue }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bits, bytesPerRow: 0, space: space,
                                  bitmapInfo: info) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        if !alpha {
            ctx.setFillColor(o.matteWhite ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
            ctx.fill(rect)
        }
        ctx.draw(image, in: rect)
        guard let out = ctx.makeImage() else { return nil }
        if keepHDR, let headroom = Optional(image.contentHeadroom), headroom > 1 {
            return CGImageCreateCopyWithContentHeadroom(headroom, out) ?? out
        }
        return out
    }

    private static func removeLocation(_ meta: CGMutableImageMetadata) {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            if let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, prefix == "exif" || prefix == "exifEX" {
                let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
                if name.hasPrefix("GPS") { paths.append(path as String) }
            }
            return true
        }
        for p in paths { CGImageMetadataRemoveTagWithPath(meta, nil, p as CFString) }
    }
}

/// EXIF orientations as what they do to the stored picture to show it: a 2×2 matrix on y-down
/// coordinates. Turns and mirrors made on screen compose with the file's own orientation into
/// another of the eight, so they can be saved by changing one tag and no pixel.
public enum Orientation {
    typealias M = (Int, Int, Int, Int)  // a b / c d

    static let matrices: [Int: M] = [
        1: (1, 0, 0, 1), 2: (-1, 0, 0, 1), 3: (-1, 0, 0, -1), 4: (1, 0, 0, -1),
        5: (0, 1, 1, 0), 6: (0, -1, 1, 0), 7: (0, -1, -1, 0), 8: (0, 1, -1, 0),
    ]

    static func multiply(_ x: M, _ y: M) -> M {
        (x.0 * y.0 + x.1 * y.2, x.0 * y.1 + x.1 * y.3, x.2 * y.0 + x.3 * y.2, x.2 * y.1 + x.3 * y.3)
    }

    /// The orientation that shows the picture turned `quarterTurns` clockwise and then mirrored
    /// left to right, on top of `exif`.
    public static func compose(_ exif: Int, quarterTurns: Int, mirror: Bool) -> Int {
        var m = matrices[exif] ?? matrices[1]!
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) { m = multiply((0, -1, 1, 0), m) }
        if mirror { m = multiply((-1, 0, 0, 1), m) }
        return matrices.first { $0.value == m }?.key ?? 1
    }
}

extension ImageExporter {
    /// Turns and mirrors a file by rewriting its orientation tag alone: every pixel stays exactly as
    /// it was, and so does the rest of the metadata. False when the format cannot be copied that way;
    /// the caller then re-encodes.
    public static func reorient(_ url: URL, quarterTurns: Int, mirror: Bool) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
              CGImageSourceGetCount(src) == 1 else { return false }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let current = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let next = Orientation.compose(current, quarterTurns: quarterTurns, mirror: mirror)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-pictty-\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else { return false }
        let options = [kCGImageDestinationOrientation: next, kCGImageDestinationMergeMetadata: true] as CFDictionary
        guard CGImageDestinationCopyImageSource(dest, src, options, nil) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        // Copied, not re-encoded: the image data must be byte for byte the same size or more or less
        // so; a format that re-encodes on copy would show here as a different orientation not taken.
        guard let check = CGImageSourceCreateWithURL(temp as CFURL, nil),
              (CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1 == next
        else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    /// The pixels themselves turned `quarterTurns` clockwise, then mirrored left to right.
    public static func oriented(_ image: CGImage, quarterTurns: Int, mirror: Bool) -> CGImage? {
        let r = ((quarterTurns % 4) + 4) % 4
        guard r != 0 || mirror else { return image }
        let w = image.width, h = image.height
        let (ow, oh) = r % 2 == 0 ? (w, h) : (h, w)
        guard let space = image.colorSpace,
              let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
                                  space: space, bitmapInfo: image.bitmapInfo.rawValue)
                ?? CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 16, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        // Bottom-up coordinates: a clockwise turn on screen is a negative angle here.
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        if mirror { ctx.scaleBy(x: -1, y: 1) }
        ctx.rotate(by: -CGFloat(r) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        guard let out = ctx.makeImage() else { return nil }
        if image.contentHeadroom > 1 { return CGImageCreateCopyWithContentHeadroom(image.contentHeadroom, out) ?? out }
        return out
    }
}
