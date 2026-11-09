import CoreGraphics
import CoreImage
import Foundation

/// The brightness of one develop of a picture made to match another's: the sensor develop
/// (`SensorDevelop`) is scene-linear, darker and flatter than Apple's, and an untouched RAW is
/// shown as Apple develops it. So that the first slider moved does not change the picture's whole
/// tone, our develop takes Apple's tones: each brightness of ours is mapped to the brightness at the
/// same rank in Apple's (the two luminance distributions matched), and each pixel's colour scaled
/// by it. Ranks, not pixels, so the small differences of framing Apple's lens corrections make do
/// not matter; a ratio of luminance, so hues stay ours; past the ends, the ends' ratios, so the light
/// past white keeps its place above everything else.
///
/// Colour is left as the camera's matrix makes it (as darktable and RawTherapee have it):
/// Apple's rendering bends each channel its own way, and a matrix fitted to it greyed the colours.
public struct LookMatch: Sendable {
    /// Our luminance and Apple's at the same ranks, rising.
    let ours: [Float], theirs: [Float]

    static let ranks = 256

    /// The mapping from `ours` to `theirs`, both linear extended sRGB; read on copies about
    /// `side` pixels across.
    public static func fit(_ ours: CGImage, to theirs: CGImage, side: Int = 1024) -> LookMatch? {
        guard let pa = pixels(ours, side: side), let pb = pixels(theirs, side: side) else { return nil }
        let a = pa.map(\.y).filter { $0 > 1e-5 }, b = pb.map(\.y).filter { $0 > 1e-5 }
        guard a.count > ranks, b.count > ranks else { return nil }
        let qa = quantiles(a), qb = quantiles(b)
        // Rising in both, so the mapping keeps order: a brighter pixel stays brighter.
        var o: [Float] = [], t: [Float] = []
        for i in 0..<ranks where qa[i] > (o.last ?? 0) {
            o.append(qa[i]); t.append(max(qb[i], t.last ?? 0))
        }
        guard o.count >= 8 else { return nil }
        return LookMatch(ours: o, theirs: t)
    }

    /// The gain for a pixel of luminance `y`.
    @inline(__always) func gain(_ y: Float) -> Float {
        guard y > 0 else { return theirs[0] / ours[0] }
        if y <= ours[0] { return theirs[0] / ours[0] }
        if y >= ours[ours.count - 1] { return theirs[theirs.count - 1] / ours[ours.count - 1] }
        var lo = 0, hi = ours.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if ours[mid] <= y { lo = mid } else { hi = mid }
        }
        let t = (y - ours[lo]) / (ours[hi] - ours[lo])
        return (theirs[lo] + t * (theirs[hi] - theirs[lo])) / y
    }

    /// `image` (linear extended sRGB, half float, as `SensorDevelop` makes it) with the mapping.
    public func apply(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard var px = Self.halfFloats(image) else { return nil }
        let weights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        px.withUnsafeMutableBufferPointer { p in
            let p = p
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let c = SIMD3<Float>(Float(p[i]), Float(p[i + 1]), Float(p[i + 2]))
                    let out = c * gain((c * weights).sum())
                    p[i] = Float16(out.x); p[i + 1] = Float16(out.y); p[i + 2] = Float16(out.z)
                }
            }
        }
        return Self.image(px, w, h)
    }

    /// `image` made smaller, keeping its light past white (linear extended sRGB, half float):
    /// `Resampler` clips at white, which took a RAW's highlights out of its screen-sized copy and gave
    /// it another tone than the whole picture.
    public static func downscaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let ci = CIImage(cgImage: image)
        let sy = CGFloat(height) / CGFloat(image.height), sx = CGFloat(width) / CGFloat(image.width)
        guard let f = CIFilter(name: "CILanczosScaleTransform",
                               parameters: [kCIInputImageKey: ci, kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy]),
              let out = f.outputImage else { return nil }
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh])
        return context.createCGImage(out, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAh, colorSpace: space)
    }

    /// An HDR develop's headroom: where the brightest thousandth of its brightest channel begins,
    /// at least 1. Not its single brightest pixel: a neon's brightest photosite is a far cry from
    /// the same picture made smaller, where it is averaged with its neighbours, and the screen-sized
    /// edit and the whole one were given two different whites, two different pictures.
    public static func peak(_ image: CGImage) -> Float {
        guard let px = halfFloats(image) else { return 1 }
        return px.withUnsafeBufferPointer { p in
            LightEngine.peak(p.baseAddress!, width: image.width, height: image.height, rowFloats: image.width * 4, white: 1)
        }
    }

    // MARK: - Plumbing

    private static func quantiles(_ v: [Float]) -> [Float] {
        let s = v.sorted()
        return (0..<ranks).map { s[min(Int((Double($0) + 0.5) / Double(ranks) * Double(s.count)), s.count - 1)] }
    }

    /// The pixels of a copy about `side` across: linear luminance and colour.
    private static func pixels(_ image: CGImage, side: Int) -> [(y: Float, c: SIMD3<Float>)]? {
        let k = min(1, Double(side) / Double(max(image.width, image.height)))
        return pixels(image, width: max(1, Int(Double(image.width) * k)), height: max(1, Int(Double(image.height) * k)))
    }
    private static func pixels(_ image: CGImage, width w: Int, height h: Int) -> [(y: Float, c: SIMD3<Float>)]? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return (0..<(w * h)).map { i in
            let c = SIMD3<Float>(px[i * 4], px[i * 4 + 1], px[i * 4 + 2])
            return ((c * SIMD3(0.2126, 0.7152, 0.0722)).sum(), c)
        }
    }

    static func halfFloats(_ image: CGImage) -> [Float16]? {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        var px = [Float16](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? px : nil
    }

    static func image(_ px: [Float16], _ w: Int, _ h: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let provider = CGDataProvider(data: px.withUnsafeBytes { Data($0) } as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                           | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

