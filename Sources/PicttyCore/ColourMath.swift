import CoreGraphics
import Foundation
import simd

/// White balance and colour grading maths, on the CPU: what the GPU gets is a 3×3 matrix and three
/// colour vectors.
///
/// White balance is a chromatic adaptation (CAT02, von Kries in a sharpened cone space) from the
/// light the picture is assumed to have been taken under to the light it is shown under. The
/// sliders move that assumed light: Temperature along the Planckian locus (×2 or ÷2 of 6504 K at
/// the ends), Tint across it (±0.02 Δuv). At zero both lights are the same and the matrix is the
/// identity.
public enum ColourMath {
    // MARK: Planckian locus (Krystek 1985, CIE 1960 uv, 1000–15000 K)

    static func locus(_ t: Double) -> SIMD2<Double> {
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        return SIMD2(u, v)
    }

    /// Unit normal to the locus at `t`, pointing above it (greener, Δuv > 0).
    static func normal(_ t: Double) -> SIMD2<Double> {
        let d = locus(t * 1.001) - locus(t * 0.999)
        let n = simd_normalize(SIMD2(d.y, -d.x))
        return n.y < 0 ? -n : n
    }

    /// D65 sits a little above the locus.
    static let duvD65 = 0.0032
    static let baseKelvin = 6504.0
    static let tintSpan = 0.02

    /// The light the sliders say the picture was taken under, as CIE 1960 uv.
    static func assumedWhite(temperature: Double, tint: Double) -> SIMD2<Double> {
        let t = min(max(baseKelvin * pow(2, temperature), 1500), 15000)
        return locus(t) + normal(t) * (duvD65 + tint * tintSpan)
    }

    static func xyz(uv: SIMD2<Double>) -> SIMD3<Double> {
        let d = 2 * uv.x - 8 * uv.y + 4
        let x = 3 * uv.x / d, y = 2 * uv.y / d
        return SIMD3(x / y, 1, (1 - x - y) / y)
    }

    static func uv(xyz: SIMD3<Double>) -> SIMD2<Double> {
        let d = xyz.x + 15 * xyz.y + 3 * xyz.z
        return SIMD2(4 * xyz.x / d, 6 * xyz.y / d)
    }

    // Linear sRGB ↔ XYZ (D65), and CAT02. simd matrices are column-major: columns are given.
    static let rgbToXYZ = simd_double3x3(columns: (SIMD3(0.4124564, 0.2126729, 0.0193339),
                                                   SIMD3(0.3575761, 0.7151522, 0.1191920),
                                                   SIMD3(0.1804375, 0.0721750, 0.9503041)))
    static let xyzToRGB = rgbToXYZ.inverse
    static let cat02 = simd_double3x3(rows: [SIMD3(0.7328, 0.4296, -0.1624),
                                             SIMD3(-0.7036, 1.6975, 0.0061),
                                             SIMD3(0.0030, 0.0136, 0.9834)])

    /// The linear sRGB matrix that white-balances for the sliders' values.
    public static func whiteBalance(temperature: Double, tint: Double) -> simd_double3x3 {
        if temperature == 0, tint == 0 { return matrix_identity_double3x3 }
        let from = cat02 * xyz(uv: assumedWhite(temperature: temperature, tint: tint))
        let to = cat02 * xyz(uv: assumedWhite(temperature: 0, tint: 0))
        let scale = simd_double3x3(diagonal: to / from)
        return xyzToRGB * cat02.inverse * scale * cat02 * rgbToXYZ
    }

    /// The slider values that make `neutral` (linear sRGB, the colour of something that should be
    /// grey) come out grey. Clamped to the sliders' range.
    public static func whiteBalance(neutral: SIMD3<Double>) -> (temperature: Double, tint: Double) {
        guard neutral.x > 0, neutral.y > 0, neutral.z > 0 else { return (0, 0) }
        let target = uv(xyz: rgbToXYZ * neutral)
        // The temperature whose locus point is nearest, by golden section on log T; then Δuv.
        var lo = log(1500.0), hi = log(15000.0)
        let g = (sqrt(5.0) - 1) / 2
        func distance(_ lt: Double) -> Double { simd_distance(locus(exp(lt)), target) }
        for _ in 0..<60 {
            let a = hi - g * (hi - lo), b = lo + g * (hi - lo)
            if distance(a) < distance(b) { hi = b } else { lo = a }
        }
        let t = exp((lo + hi) / 2)
        let duv = simd_dot(target - locus(t), normal(t))
        return (min(max(log2(t / baseKelvin), -1), 1), min(max((duv - duvD65) / tintSpan, -1), 1))
    }

    // MARK: Colour grading

    /// A direction of colour with no brightness of its own, for a hue (degrees): added to a pixel in
    /// proportion to its light, it tints without lightening or darkening. Every hue has the same length.
    public static func gradeVector(_ s: ColourShift) -> SIMD3<Double> {
        guard s.amount > 0 else { return .zero }
        let h = (s.hue / 60).truncatingRemainder(dividingBy: 6)
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let c: SIMD3<Double> = switch Int(h) {
        case 0: SIMD3(1, x, 0)
        case 1: SIMD3(x, 1, 0)
        case 2: SIMD3(0, 1, x)
        case 3: SIMD3(0, x, 1)
        case 4: SIMD3(x, 0, 1)
        default: SIMD3(1, 0, x)
        }
        // The hue's encoded colour into linear light, then minus its own luminance.
        let linear = SIMD3(c.x, c.y, c.z).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let y = simd_dot(linear, SIMD3(0.2126, 0.7152, 0.0722))
        let d = linear / max(y, 1e-6) - 1
        return simd_normalize(d) * s.amount * 0.55
    }

    // MARK: Auto white balance

    /// Estimates the light a picture was taken under, as linear sRGB.
    ///
    /// Grey points (Huo et al. 2006): pixels already close to neutral are the best witnesses of the
    /// light, so the estimate starts from all of them, white-balances, and asks again with a
    /// tighter idea of "close to neutral", eight times. Blown pixels (they say nothing about the
    /// light) and near-black ones (noise) never vote. If too few grey points are left, the answer
    /// falls back to Shades of Grey (Finlayson and Trezzi 2004, p = 6), which leans on the brighter
    /// pixels without trusting the single brightest one.
    public static func estimateIlluminant(_ image: CGImage) -> SIMD3<Double>? {
        let px = linearPixels(image, maxSide: 384)
        guard !px.isEmpty else { return nil }
        let usable = px.filter { max($0.x, $0.y, $0.z) < 0.92 && simd_dot($0, SIMD3(0.2126, 0.7152, 0.0722)) > 0.012 }
        guard usable.count > 64 else { return nil }

        var gains = SIMD3<Double>(1, 1, 1)
        var estimate: SIMD3<Double>?
        for i in 0..<8 {
            let threshold = 0.32 - Double(i) * 0.025
            var sum = SIMD3<Double>.zero, n = 0
            for p in usable {
                let q = p * gains
                let y = simd_dot(q, SIMD3(0.299, 0.587, 0.114))
                let u = -0.147 * q.x - 0.289 * q.y + 0.436 * q.z
                let v = 0.615 * q.x - 0.515 * q.y - 0.100 * q.z
                if (abs(u) + abs(v)) / y < threshold { sum += p; n += 1 }
            }
            guard n >= max(usable.count / 200, 32) else { break }
            let m = sum / Double(n)
            estimate = m
            gains = SIMD3(m.y / m.x, 1, m.y / m.z)
        }
        if let estimate { return estimate / estimate.max() }

        var acc = SIMD3<Double>.zero
        for p in usable { acc += SIMD3(pow(p.x, 6), pow(p.y, 6), pow(p.z, 6)) }
        let m = SIMD3(pow(acc.x, 1.0 / 6), pow(acc.y, 1.0 / 6), pow(acc.z, 1.0 / 6))
        return m.max() > 0 ? m / m.max() : nil
    }

    /// The average colour of a small square of a picture, linear sRGB: what the eyedropper reads.
    /// `point` is in the picture's own 0…1 coordinates, top-left origin.
    public static func sample(_ image: CGImage, at point: CGPoint, radius: Int = 3) -> SIMD3<Double>? {
        let x = Int(point.x * CGFloat(image.width)), y = Int(point.y * CGFloat(image.height))
        let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2 + 1, height: radius * 2 + 1)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, let crop = image.cropping(to: rect) else { return nil }
        let px = linearPixels(crop, maxSide: 64)
        guard !px.isEmpty else { return nil }
        return px.reduce(.zero, +) / Double(px.count)
    }

    /// Pixels as linear sRGB, colour-managed, shrunk to `maxSide`.
    static func linearPixels(_ image: CGImage, maxSide: Int) -> [SIMD3<Double>] {
        let k = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return [] }
        var data = [Float](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return [] }
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(w * h)
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 0.5 {
            let a = Double(data[i + 3])
            out.append(SIMD3(Double(data[i]) / a, Double(data[i + 1]) / a, Double(data[i + 2]) / a))
        }
        return out
    }
}

private extension SIMD3 where Scalar == Double {
    func map(_ f: (Double) -> Double) -> SIMD3<Double> { SIMD3(f(x), f(y), f(z)) }
}
