import CoreGraphics
import Foundation

/// Two things about a picture that set how far its detail can be pushed: how noisy it is, and
/// how soft its edges are. Both are measured on its own pixels, on a sample of rows, in the
/// encoded luminance the detail sliders work on.
public enum PictureMeasure {
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
