import Accelerate
import CoreGraphics
import Foundation

/// A camera RAW from the sensor develop, with Apple's highlights. The sensor develop
/// (`SensorDevelop`) is cleaner: its learned network takes the noise out before any demosaic has
/// smeared it, and its shadows and textures are the best there are. Apple's develop has the best
/// highlights: where the sensor clipped no develop can know what was there, and Apple's recovery
/// fills it best. So the fine detail is always the sensor develop's, as a ratio to its own light
/// at the scale of a few pixels; that light is its own in the shadows and midtones and moves over
/// to Apple's in the bright regions and around what clipped, smoothly, at that coarse scale. Where
/// the sensor clipped there is no detail to give, and Apple's develop stays as it is. Blending the two
/// develops side by side instead (ours, Apple's in the clipped areas) showed as two renderings
/// meeting at the edge of every bright light.
///
/// Both must be the same frame pixel for pixel: Apple's without its lens corrections (the sensor
/// develop has none) and at the same size.
public enum DetailTransfer {
    /// The scale below which detail is the sensor develop's, in pixels (a Gaussian's sigma).
    public static let sigma: Float = 3
    /// Where Apple's light takes over, by the region's brightness (linear, white 1): none below
    /// `brightFrom`, all of it from `brightTo`.
    public static let brightFrom: Float = 0.45, brightTo: Float = 1.0

    /// `apple` and `sensor`: linear extended sRGB, the same size. `clipped`: where the sensor
    /// clipped, 0…1 per pixel, softened.
    public static func apply(apple: CGImage, sensor: CGImage, clipped: [Float]?) -> CGImage? {
        let w = apple.width, h = apple.height
        guard sensor.width == w, sensor.height == h, clipped.map({ $0.count == w * h }) ?? true,
              let a = LookMatch.halfFloats(apple), let s = LookMatch.halfFloats(sensor) else { return nil }
        // Per channel: Apple's local light, and the sensor develop's local light and pixels.
        var out = [Float16](repeating: 1, count: w * h * 4)
        let floor: Float = 0.002
        // Whose light: the sensor develop's in the shadows and midtones, where its network's
        // clean texture is the point (Apple's light there carries its noise as a coarse mottle),
        // Apple's in the bright regions and around what clipped, where its recovery is.
        var sensorLuma = [Float](repeating: 0, count: w * h)
        sensorLuma.withUnsafeMutableBufferPointer { l in
            let l = l
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    l[y * w + x] = 0.2126 * Float(s[i]) + 0.7152 * Float(s[i + 1]) + 0.0722 * Float(s[i + 2])
                }
            }
        }
        let smoothLuma = gaussian(gaussian(sensorLuma, w, h), w, h)
        let around = clipped.map { gaussian(gaussian($0, w, h), w, h) }
        var apples = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let u = min(max((smoothLuma[i] - brightFrom) / (brightTo - brightFrom), 0), 1)
            let v = min((around?[i] ?? 0) / 0.2, 1)
            let t = max(u, v)
            apples[i] = t * t * (3 - 2 * t)
        }
        for c in 0..<3 {
            var ac = [Float](repeating: 0, count: w * h), sc = ac
            ac.withUnsafeMutableBufferPointer { ap in sc.withUnsafeMutableBufferPointer { sp in
                let (ap, sp) = (ap, sp)
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w { let i = y * w + x; ap[i] = Float(a[i * 4 + c]); sp[i] = Float(s[i * 4 + c]) }
                }
            } }
            let aLow = gaussian(ac, w, h), sLow = gaussian(sc, w, h)
            out.withUnsafeMutableBufferPointer { o in
                let o = o
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let i = y * w + x
                        let ratio = min(max((max(sc[i], 0) + floor) / (max(sLow[i], 0) + floor), 0.2), 5)
                        var v = (sLow[i] + (aLow[i] - sLow[i]) * apples[i]) * ratio
                        if let clipped {
                            let u = min(clipped[i] / 0.35, 1)
                            if u > 0 { let t = u * u * (3 - 2 * u); v += (ac[i] - v) * t }
                        }
                        o[i * 4 + c] = Float16(v)
                    }
                }
            }
        }
        return LookMatch.image(out, w, h)
    }

    /// A Gaussian of `sigma`, separable, by Accelerate; edges extended.
    static func gaussian(_ v: [Float], _ w: Int, _ h: Int) -> [Float] {
        let r = Int((3 * sigma).rounded(.up))
        var k = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let sum = k.reduce(0, +); k = k.map { $0 / sum }
        var src = v, out = [Float](repeating: 0, count: w * h)
        src.withUnsafeMutableBytes { sb in out.withUnsafeMutableBytes { ob in
            var s = vImage_Buffer(data: sb.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var d = vImage_Buffer(data: ob.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            _ = vImageSepConvolve_PlanarF(&s, &d, nil, 0, 0, k, UInt32(k.count), k, UInt32(k.count), 0, 0,
                                          vImage_Flags(kvImageEdgeExtend))
        } }
        return out
    }
}
