import CoreGraphics
import Foundation

/// Two things about a picture that set how far its detail can be pushed: how noisy it is, and
/// how soft its edges are. Both are measured on its own pixels, on a sample of rows, in the
/// encoded luminance the detail sliders work on.
public enum PictureMeasure {
    /// Noise read from the flattest parts of a luminance plane (encoded, 0…1), in 8-bit levels.
    ///
    /// Immerkær's operator (which cancels anything smooth or straight) is averaged over 16-pixel
    /// blocks; the 15th percentile of those blocks is the noise: in skin, sky and walls whatever
    /// varies is noise, while texture (foliage, fabric) only adds to the busier blocks. Near-black
    /// and blown blocks, where noise cannot show, are left out.
    public static func flatNoise(_ l: [Float], width w: Int, height h: Int) -> Float {
        let b = 16
        guard w > b + 2, h > b + 2 else { return 0 }
        var blocks: [Float] = []
        blocks.reserveCapacity((w / b) * (h / b))
        for by in 0..<((h - 2) / b) {
            for bx in 0..<((w - 2) / b) {
                var sum: Float = 0, mean: Float = 0
                for y in (by * b + 1)...(by * b + b) {
                    for x in (bx * b + 1)...(bx * b + b) {
                        let i = y * w + x
                        let n = l[i - w - 1] - 2 * l[i - w] + l[i - w + 1]
                            - 2 * (l[i - 1] - 2 * l[i] + l[i + 1])
                            + l[i + w - 1] - 2 * l[i + w] + l[i + w + 1]
                        sum += abs(n)
                        mean += l[i]
                    }
                }
                mean /= Float(b * b)
                if mean > 0.06, mean < 0.94 { blocks.append(sum / Float(b * b)) }
            }
        }
        guard blocks.count >= 8 else { return 0 }
        blocks.sort()
        return blocks[blocks.count * 15 / 100] * Float((Double.pi / 2).squareRoot()) / 6 * 255
    }

    /// Each `k` × `k` block of a plane averaged.
    public static func shrink(_ l: [Float], width w: Int, height h: Int, by k: Int) -> (plane: [Float], width: Int, height: Int) {
        let ow = max(1, w / k), oh = max(1, h / k)
        var out = [Float](repeating: 0, count: ow * oh)
        let n = Float(k * k)
        for y in 0..<oh {
            for x in 0..<ow {
                var s: Float = 0
                for j in 0..<k { let row = (y * k + j) * w + x * k; for i in 0..<k { s += l[row + i] } }
                out[y * ow + x] = s / n
            }
        }
        return (out, ow, oh)
    }

    /// A picture's noise at full, half and quarter size, in 8-bit levels: fine noise shows at full
    /// size and averages away below; coarse grain (from an editor, or an enlargement) grows instead.
    public static func noiseLevels(_ image: CGImage) -> (full: Float, half: Float, quarter: Float) {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) ?? CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data else { return (0, 0, 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let l = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: w * h))
        let half = shrink(l, width: w, height: h, by: 2)
        let quarter = shrink(half.plane, width: half.width, height: half.height, by: 2)
        return (flatNoise(l, width: w, height: h), flatNoise(half.plane, width: half.width, height: half.height),
                flatNoise(quarter.plane, width: quarter.width, height: quarter.height))
    }

    /// The scales coarse grain needs to be taken out at, coarsest first ([4, 2], [2] or none), from
    /// `noiseLevels`. Calibrated on seventeen photos: coarse grain read 0.5 / 1.2 / 2.1 levels;
    /// fine noise and clean pictures fall or hold as they shrink.
    public static func grainScales(_ n: (full: Float, half: Float, quarter: Float)) -> [Int] {
        guard n.half > 0.6, n.half / max(n.full, 0.05) > 1.4 else { return [] }
        return n.quarter > 0.8 && n.quarter / max(n.half, 0.05) > 1.3 ? [4, 2] : [2]
    }

    /// How much noise reduction a picture wants, 0…1, from `noiseLevels`: the strongest of the three
    /// readings, from about 0.7 levels (clean below) to about 2.5 (full strength).
    public static func denoiseAmount(_ n: (full: Float, half: Float, quarter: Float)) -> Double {
        let strongest = Double(max(n.full, n.half, n.quarter))
        let amount = min(max((strongest - 0.5) / 2, 0), 1)
        return amount < 0.1 ? 0 : (amount * 20).rounded() / 20
    }

    /// The same, for any picture: drawn into linear half floats first.
    public static func noiseAndBlur(_ image: CGImage) -> (noise: Float, blur: Float) {
        let w = image.width, h = image.height
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder16Little.rawValue) else { return (0.004, 1) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return (0.004, 1) }
        return noiseAndBlur(data.assumingMemoryBound(to: Float16.self), width: w, height: h, rowFloats: ctx.bytesPerRow / 2)
    }

    /// `pixels`: premultiplied linear RGBA half floats, `rowFloats` values per row.
    ///
    /// Noise: Immerkær's fast estimate (1996): the picture convolved with the difference of two
    /// Laplacians, which cancels anything smooth or straight and leaves the noise; the mean of its
    /// magnitude, scaled, is the standard deviation. Strong edges are left out, so a sharp,
    /// clean photo does not read as noisy.
    ///
    /// Blur: along sampled rows, every strong, isolated edge is walked to its plateaus on both
    /// sides; the distance between 10 % and 90 % of the step is its width, which for a Gaussian
    /// blur is 2.56 sigma. The median over the picture is its blur.
    public static func noiseAndBlur(_ pixels: UnsafePointer<Float16>, width w: Int, height h: Int,
                                    rowFloats: Int) -> (noise: Float, blur: Float) {
        guard w > 16, h > 16 else { return (0.004, 1) }
        func luma(_ x: Int, _ y: Int) -> Float {
            let p = pixels + y * rowFloats + x * 4
            let a = max(Float(p[3]), 1e-4)
            let lin = max((0.2126 * Float(p[0]) + 0.7152 * Float(p[1]) + 0.0722 * Float(p[2])) / a, 0)
            return lin <= 0.0031308 ? lin * 12.92 : 1.055 * pow(lin, 1 / 2.4) - 0.055
        }
        let step = max(1, h / 240)
        var row0 = [Float](repeating: 0, count: w), row1 = row0, row2 = row0
        var sum: Double = 0, count = 0
        var widths: [Float] = []
        for y in stride(from: 1, to: h - 1, by: step) {
            for x in 0..<w { row0[x] = luma(x, y - 1); row1[x] = luma(x, y); row2[x] = luma(x, y + 1) }
            for x in 1..<(w - 1) {
                let n = row0[x - 1] - 2 * row0[x] + row0[x + 1]
                    - 2 * (row1[x - 1] - 2 * row1[x] + row1[x + 1])
                    + row2[x - 1] - 2 * row2[x] + row2[x + 1]
                // Edges are not noise.
                let gx = abs(row1[x + 1] - row1[x - 1]), gy = abs(row2[x] - row0[x])
                if gx + gy < 0.08 { sum += Double(abs(n)); count += 1 }
            }
            // Edge widths on this row.
            var x = 2
            while x < w - 3 {
                let g = row1[x + 1] - row1[x - 1]
                guard abs(g) > 0.06, abs(g) >= abs(row1[x + 2] - row1[x]), abs(g) >= abs(row1[x] - row1[x - 2]) else { x += 1; continue }
                let rising = g > 0
                var l = x, r = x
                while l > 1, x - l < 12, rising ? row1[l - 1] < row1[l] : row1[l - 1] > row1[l] { l -= 1 }
                while r < w - 2, r - x < 12, rising ? row1[r + 1] > row1[r] : row1[r + 1] < row1[r] { r += 1 }
                let lo = row1[l], hi = row1[r], step = hi - lo
                if abs(step) > 0.15, r - l >= 2 {
                    func crossing(_ f: Float) -> Float {
                        let target = lo + f * step
                        for i in l..<r where (row1[i] - target) * (row1[i + 1] - target) <= 0 {
                            let d = row1[i + 1] - row1[i]
                            return Float(i) + (d == 0 ? 0 : (target - row1[i]) / d)
                        }
                        return Float(l)
                    }
                    widths.append(abs(crossing(0.9) - crossing(0.1)))
                }
                x = r + 1
            }
        }
        let noise = count > 0 ? Float(sum / Double(count)) * Float((Double.pi / 2).squareRoot()) / 6 : 0.004
        var blur: Float = 1
        if widths.count >= 20 {
            widths.sort()
            blur = widths[widths.count / 2] / 2.56
        }
        return (min(max(noise, 0.0005), 0.2), min(max(blur, 0.3), 4))
    }
}
