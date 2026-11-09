import Accelerate
import CoreGraphics
import Foundation

/// The lens corrections Apple's RAW engine makes, measured on one picture so the sensor develop
/// (which has none) can be given them. Apple develops the picture twice, with and without its
/// corrections; points matched between the two give the distortion, as a radial model about the
/// centre (what a lens's distortion is), and their brightness the vignetting. Applied to the
/// sensor develop, it takes Apple's geometry and light falloff, whatever the camera and lens; a
/// lens Apple has no profile for gives two identical renders, and no correction.
public struct LensMatch: Sendable {
    /// Where a point of the corrected picture lies in the uncorrected one, as a scale of its distance
    /// from the centre: `1 + k[0] r² + k[1] r⁴ + k[2] r⁶`, with `r` in half-diagonals.
    public let k: [Float]
    public let scale: Float
    /// The corrected picture's light over the uncorrected one's: `1 + v[0] r² + v[1] r⁴`.
    public let v: [Float]
    /// The matched points' spread from the model, in pixels of the measuring size.
    public let residual: Float
    public let points: Int
    /// Lateral chromatic aberration: each channel's own scale on top of the distortion,
    /// `1 + ca[c][0] + ca[c][1] r² + ca[c][2] r⁴` (red, green, blue). Lenses bend colours by
    /// slightly different amounts, which shows as red and blue fringes towards the corners.
    public var ca: [[Float]] = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]

    public init(k: [Float], scale: Float, v: [Float], residual: Float, points: Int,
                ca: [[Float]] = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]) {
        self.k = k; self.scale = scale; self.v = v; self.residual = residual; self.points = points; self.ca = ca
    }

    /// Nothing to correct.
    /// (No point moved by more than 0.15 % of its distance from the centre, the light by less than
    /// half a percent: what two identical develops measure as, and not worth a resampling.)
    public var isIdentity: Bool {
        stride(from: Float(0), through: 1, by: 0.05).allSatisfy { r in
            let r2 = r * r
            return abs(scale * (1 + r2 * (k[0] + r2 * (k[1] + r2 * k[2]))) - 1) < 0.0015
                && abs(r2 * (v[0] + r2 * v[1])) < 0.005
                && ca.allSatisfy { abs($0[0] + r2 * ($0[1] + r2 * $0[2])) < 0.0002 }
        }
    }

    /// From Apple's develop with (`corrected`) and without (`uncorrected`) its lens corrections,
    /// the same frame and size. Nil when too few points match.
    public static func measure(corrected: CGImage, uncorrected: CGImage) -> LensMatch? {
        guard corrected.width == uncorrected.width, corrected.height == uncorrected.height else { return nil }
        let side = 1024
        let k0 = Float(side) / Float(max(corrected.width, corrected.height))
        let w = Int(Float(corrected.width) * k0), h = Int(Float(corrected.height) * k0)
        guard let a = logLuma(corrected, w, h), let b = logLuma(uncorrected, w, h),
              let la = linearLuma(corrected, w, h), let lb = linearLuma(uncorrected, w, h) else { return nil }
        let cx = Float(w) / 2, cy = Float(h) / 2, half = (cx * cx + cy * cy).squareRoot()
        // Matches on a grid: a patch of the corrected picture found in the uncorrected one, first
        // on a half-size copy over a wide search, then here within two pixels of it.
        let hw = w / 2, hh = h / 2
        guard let ah = logLuma(corrected, hw, hh), let bh = logLuma(uncorrected, hw, hh) else { return nil }
        let patch = 7, search = 24
        var r2s: [Float] = [], ratios: [Float] = [], gains: [Float] = [], rs: [Float] = []
        let gx = 28, gy = 20
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: gx * gy) { n in
            let px = Int(Float(n % gx + 1) / Float(gx + 1) * Float(w)), py = Int(Float(n / gx + 1) / Float(gy + 1) * Float(h))
            guard let coarse = match(ah, bh, hw, hh, px / 2, py / 2, 5, start: (0, 0), range: search / 2),
                  let fine = match(a, b, w, h, px, py, patch, start: (Int((coarse.0 * 2).rounded()), Int((coarse.1 * 2).rounded())), range: 2)
            else { return }
            let (sx, sy) = fine
            let best = (Int(sx.rounded()), Int(sy.rounded()))
            let ux = Float(px) - cx, uy = Float(py) - cy
            let r = (ux * ux + uy * uy).squareRoot() / half
            guard r > 0.15 else { return }
            // The scale along the radius, from the shift's radial part.
            let radial = (ux * sx + uy * sy) / (ux * ux + uy * uy).squareRoot()
            let ratio = 1 + radial / (r * half)
            // The light: patch means, the corrected over the uncorrected at the matched place.
            var ma: Float = 0, mbl: Float = 0
            let bx = px + best.0, by = py + best.1
            for j in -patch...patch { for i in -patch...patch { ma += la[(py + j) * w + px + i]; mbl += lb[(by + j) * w + bx + i] } }
            lock.lock()
            r2s.append(r * r); ratios.append(ratio); rs.append(r)
            gains.append(mbl > 1e-4 ? ma / mbl : .nan)
            lock.unlock()
        }
        guard r2s.count >= 40 else { return nil }
        // ratio = scale · (1 + k1 r² + k2 r⁴ + k3 r⁶), fitted robustly: the worst tenth dropped twice.
        var keep = Array(0..<r2s.count)
        var c: [Float] = [1, 0, 0, 0]
        for _ in 0..<3 {
            c = fit(keep.map { r2s[$0] }, keep.map { ratios[$0] }, terms: 4)
            let res = keep.map { abs(poly(c, r2s[$0]) - ratios[$0]) }
            let cut = res.sorted()[Int(Double(res.count) * 0.9)]
            keep = zip(keep, res).filter { $0.1 <= cut }.map(\.0)
        }
        let scale = c[0]
        let k = [c[1] / scale, c[2] / scale, c[3] / scale]
        let residual = (keep.map { pow((poly(c, r2s[$0]) - ratios[$0]) * rs[$0] * half, 2) }.reduce(0, +) / Float(keep.count)).squareRoot()
        // Vignetting, normalised at the centre.
        let vi = keep.filter { gains[$0].isFinite && gains[$0] > 0 }
        var v: [Float] = [0, 0]
        if vi.count >= 20 {
            let g = fit(vi.map { r2s[$0] }, vi.map { gains[$0] }, terms: 3)
            v = [g[1] / g[0], g[2] / g[0]]
        }
        var lens = LensMatch(k: k, scale: scale, v: v, residual: residual, points: keep.count)
        if let ca = chromatic(corrected: corrected, uncorrected: uncorrected, lens) { lens.ca = ca }
        return lens
    }

    /// Each channel's scale past the distortion, matched channel by channel at the images' own
    /// size (fringes are a pixel or two; the luminance's measuring size is too coarse for them).
    /// Nil when too few points match.
    static func chromatic(corrected: CGImage, uncorrected: CGImage, _ lens: LensMatch) -> [[Float]]? {
        let w = corrected.width, h = corrected.height
        guard let pa = LookMatch.halfFloats(corrected), let pb = LookMatch.halfFloats(uncorrected) else { return nil }
        let cx = Float(w) / 2, cy = Float(h) / 2, half = (cx * cx + cy * cy).squareRoot()
        let gx = 40, gy = 28, patch = 6
        var result: [[Float]] = []
        func logChannel(_ p: [Float16], _ c: Int) -> [Float] {
            var out = [Float](repeating: 0, count: w * h)
            out.withUnsafeMutableBufferPointer { o in
                let o = o
                p.withUnsafeBufferPointer { p in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for i in (y * w)..<((y + 1) * w) { o[i] = log(max(Float(p[i * 4 + c]), 1e-4)) }
                    }
                }
            }
            return out
        }
        for c in 0..<3 {
            let a = logChannel(pa, c), b = logChannel(pb, c)
            var r2s: [Float] = [], deltas: [Float] = []
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: gx * gy) { n in
                let px = Int(Float(n % gx + 1) / Float(gx + 1) * Float(w)), py = Int(Float(n / gx + 1) / Float(gy + 1) * Float(h))
                let ux = Float(px) - cx, uy = Float(py) - cy
                let r2 = (ux * ux + uy * uy) / (half * half)
                guard r2 > 0.09 else { return }
                // Where the distortion alone puts it; the channel is searched for around there.
                let m = lens.scale * (1 + r2 * (lens.k[0] + r2 * (lens.k[1] + r2 * lens.k[2])))
                let start = (Int((ux * (m - 1)).rounded()), Int((uy * (m - 1)).rounded()))
                guard let (sx, sy) = match(a, b, w, h, px, py, patch, start: start, range: 3) else { return }
                let len = (ux * ux + uy * uy).squareRoot()
                let ratio = 1 + (ux * sx + uy * sy) / (len * len)
                lock.lock(); r2s.append(r2); deltas.append(ratio / m - 1); lock.unlock()
            }
            guard r2s.count >= 60 else { return nil }
            var keep = Array(0..<r2s.count)
            var f: [Float] = [0, 0, 0]
            for _ in 0..<3 {
                f = fit(keep.map { r2s[$0] }, keep.map { deltas[$0] }, terms: 3)
                let res = keep.map { abs(poly(f, r2s[$0]) - deltas[$0]) }
                let cut = res.sorted()[Int(Double(res.count) * 0.8)]
                keep = zip(keep, res).filter { $0.1 <= cut }.map(\.0)
            }
            result.append(f)
        }
        // Relative to green: the distortion's own fit already carries the common part.
        let g = result[1]
        return result.map { zip($0, g).map { $0 - $1 } }
    }

    /// The best shift of the patch of `a` at (px, py) in `b`, within `range` of `start`, and its SSDs.
static func match(_ a: [Float], _ b: [Float], _ w: Int, _ h: Int, _ px: Int, _ py: Int, _ p: Int,
               start: (Int, Int), range: Int) -> (Float, Float)? {
        let side = 2 * range + 1
        guard px - p - range + start.0 > 0, py - p - range + start.1 > 0,
              px + p + range + start.0 < w - 1, py + p + range + start.1 < h - 1, px - p > 0, py - p > 0,
              px + p < w - 1, py + p < h - 1 else { return nil }
        let cnt = Float((2 * p + 1) * (2 * p + 1))
        var ma: Float = 0, sq: Float = 0
        for j in -p...p { for i in -p...p { let t = a[(py + j) * w + px + i]; ma += t; sq += t * t } }
        ma /= cnt
        guard sq / cnt - ma * ma > 0.002 else { return nil }
        var ssd = [Float](repeating: .infinity, count: side * side)
        var best = (0, 0, Float.infinity)
        for dy in -range...range {
            for dx in -range...range {
                let ox = start.0 + dx, oy = start.1 + dy
                var mb: Float = 0
                for j in -p...p { for i in -p...p { mb += b[(py + oy + j) * w + px + ox + i] } }
                mb /= cnt
                var s: Float = 0
                for j in -p...p { for i in -p...p {
                    let d = (a[(py + j) * w + px + i] - ma) - (b[(py + oy + j) * w + px + ox + i] - mb)
                    s += d * d
                } }
                ssd[(dy + range) * side + dx + range] = s
                if s < best.2 { best = (dx, dy, s) }
            }
        }
        guard abs(best.0) < range, abs(best.1) < range else { return nil }
        func at(_ dx: Int, _ dy: Int) -> Float { ssd[(dy + range) * side + dx + range] }
        func vertex(_ m: Float, _ c: Float, _ q: Float) -> Float { let den = m - 2 * c + q; return den > 0 ? 0.5 * (m - q) / den : 0 }
        return (Float(start.0 + best.0) + vertex(at(best.0 - 1, best.1), best.2, at(best.0 + 1, best.1)),
                Float(start.1 + best.1) + vertex(at(best.0, best.1 - 1), best.2, at(best.0, best.1 + 1)))
    }

    /// `image` (linear extended sRGB, half float, uncorrected) given the corrections.
    public func apply(_ image: CGImage) -> CGImage? {
        guard let src = LookMatch.halfFloats(image) else { return nil }
        let w = image.width, h = image.height
        let cx = Float(w) / 2, cy = Float(h) / 2, half = (cx * cx + cy * cy).squareRoot()
        var out = [Float16](repeating: 1, count: w * h * 4)
        let (k, scale, v, ca) = (self.k, self.scale, self.v, self.ca)
        out.withUnsafeMutableBufferPointer { o in
            let o = o
            src.withUnsafeBufferPointer { s in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let ux = Float(x) + 0.5 - cx, uy = Float(y) + 0.5 - cy
                        let r2 = (ux * ux + uy * uy) / (half * half)
                        let m = scale * (1 + r2 * (k[0] + r2 * (k[1] + r2 * k[2])))
                        let gain = 1 + r2 * (v[0] + r2 * v[1])
                        let d = (y * w + x) * 4
                        for c in 0..<3 {
                            let mc = m * (1 + ca[c][0] + r2 * (ca[c][1] + r2 * ca[c][2]))
                            let fx = min(max(cx + ux * mc - 0.5, 0), Float(w - 1)), fy = min(max(cy + uy * mc - 0.5, 0), Float(h - 1))
                            let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
                            let tx = fx - Float(x0), ty = fy - Float(y0)
                            let top = Float(s[(y0 * w + x0) * 4 + c]) * (1 - tx) + Float(s[(y0 * w + x1) * 4 + c]) * tx
                            let bottom = Float(s[(y1 * w + x0) * 4 + c]) * (1 - tx) + Float(s[(y1 * w + x1) * 4 + c]) * tx
                            o[d + c] = Float16((top * (1 - ty) + bottom * ty) * gain)
                        }
                    }
                }
            }
        }
        return LookMatch.image(out, w, h)
    }

    // MARK: - Plumbing

    static func poly(_ c: [Float], _ x: Float) -> Float { c.reversed().reduce(0) { $0 * x + $1 } }

    /// Least squares for `y = Σ c[i] xⁱ`.
    static func fit(_ x: [Float], _ y: [Float], terms n: Int) -> [Float] {
        var ata = [Double](repeating: 0, count: n * n), aty = [Double](repeating: 0, count: n)
        for (xi, yi) in zip(x, y) {
            var p = [Double](repeating: 1, count: n)
            for i in 1..<n { p[i] = p[i - 1] * Double(xi) }
            for i in 0..<n { aty[i] += p[i] * Double(yi); for j in 0..<n { ata[i * n + j] += p[i] * p[j] } }
        }
        // Gaussian elimination.
        var m = ata, b = aty
        for i in 0..<n {
            var piv = i
            for r in i..<n where abs(m[r * n + i]) > abs(m[piv * n + i]) { piv = r }
            if piv != i { for j in 0..<n { m.swapAt(i * n + j, piv * n + j) }; b.swapAt(i, piv) }
            guard abs(m[i * n + i]) > 1e-12 else { return [1] + [Float](repeating: 0, count: n - 1) }
            for r in (i + 1)..<n {
                let f = m[r * n + i] / m[i * n + i]
                for j in i..<n { m[r * n + j] -= f * m[i * n + j] }
                b[r] -= f * b[i]
            }
        }
        var c = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = b[i]
            for j in (i + 1)..<n { s -= m[i * n + j] * c[j] }
            c[i] = s / m[i * n + i]
        }
        return c.map(Float.init)
    }

    static func linearLuma(_ image: CGImage, _ w: Int, _ h: Int) -> [Float]? {
        guard let small = LookMatch.downscaled(image, width: w, height: h), let px = LookMatch.halfFloats(small) else { return nil }
        return (0..<(w * h)).map { 0.2126 * Float(px[$0 * 4]) + 0.7152 * Float(px[$0 * 4 + 1]) + 0.0722 * Float(px[$0 * 4 + 2]) }
    }

    static func logLuma(_ image: CGImage, _ w: Int, _ h: Int) -> [Float]? {
        linearLuma(image, w, h).map { $0.map { log(max($0, 1e-4)) } }
    }
}
