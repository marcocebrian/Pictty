import CoreGraphics
import CoreML
import Foundation
import PicttyCore

/// Noise reduction by NAFNet (Chen et al. 2022, MIT licence), a convolutional network trained on
/// real smartphone noise (SIDD), run by Core ML on the GPU in 512-pixel tiles.
///
/// The network knows pixel-sized noise. Grain that is coarser (film grain added in an editor, or a
/// noisy picture that was enlarged) looks like texture to it at full size, so the picture is first
/// measured: noise that averages away when the picture is halved is fine; noise that grows instead
/// is coarse. Coarse grain is taken out at the scale where it is pixel-sized again (half, quarter),
/// coarsest first, by removing only what the network removed there, enlarged back; the full-size
/// pass then takes the fine noise. Detail at full size is never smoothed by the smaller passes'
/// enlargement because only their residual (the noise they found) comes back up.
///
/// The network diverges on very dark tiles (a mean below about 0.06 encoded): it answers with a
/// bright, coloured lattice instead of the picture. So a dark tile is first lifted by a curve that
/// can be undone exactly, y = x(1 + a)/(1 + ax), until its mean is 0.15, and lowered again after;
/// a tile that still comes back far from what went in is run once more, lifted further, and if it
/// still does, it is left as it was rather than spoilt.
///
/// Tiles overlap by 64 pixels and are blended across the overlap: the network averages over each
/// tile (its channel attention), so cut-and-paste tiles could show seams. About 2.6 s for 12
/// megapixels on an M5 Pro, plus a quarter for a half-size pass. HDR pictures are not offered it.
final class NeuralDenoiser: @unchecked Sendable {
    static let shared = NeuralDenoiser()

    private static let tile = 512, overlap = 64
    private let lock = NSLock()
    private var loaded: MLModel?
    private var warm = false

    /// The compiled network in the app, if this build has it.
    private let url: URL? = Bundle.main.url(forResource: "Denoise", withExtension: "mlmodelc")

    var isAvailable: Bool { url != nil }

    private var model: MLModel? {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        guard let url else { return nil }
        let config = MLModelConfiguration()
        // Measured: the GPU is three times faster than the Neural Engine for this network.
        config.computeUnits = .cpuAndGPU
        loaded = try? MLModel(contentsOf: url, configuration: config)
        return loaded
    }

    /// Loads the network and runs it once on an empty tile, in the background: Core ML's first
    /// prediction on the GPU sets itself up (over a second), and that is better spent while the
    /// Adjust panel is being looked at than when Noise reduction is asked for.
    func warmUp() {
        lock.lock()
        guard !warm, url != nil else { lock.unlock(); return }
        warm = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let t = Self.tile
            guard let model = self.model,
                  let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: t), NSNumber(value: t)], dataType: .float16),
                  let features = try? MLDictionaryFeatureProvider(dictionary: ["input": input]) else { return }
            let start = CFAbsoluteTimeGetCurrent()
            _ = try? model.prediction(from: features)
            timingMark(String(format: "denoiser warmed up in %.0f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000))
        }
    }

    /// An RGB picture as three planes of encoded values, 0…1.
    private struct Planes {
        var w: Int, h: Int
        var r: [Float], g: [Float], b: [Float]

        init(w: Int, h: Int) {
            self.w = w; self.h = h
            r = [Float](repeating: 0, count: w * h); g = r; b = r
        }

        /// Each `k` × `k` block averaged.
        func shrunk(by k: Int) -> Planes {
            var out = Planes(w: max(1, w / k), h: max(1, h / k))
            let n = Float(k * k)
            for y in 0..<out.h {
                for x in 0..<out.w {
                    var sr: Float = 0, sg: Float = 0, sb: Float = 0
                    for j in 0..<k {
                        let row = (y * k + j) * w + x * k
                        for i in 0..<k { sr += r[row + i]; sg += g[row + i]; sb += b[row + i] }
                    }
                    let o = y * out.w + x
                    out.r[o] = sr / n; out.g[o] = sg / n; out.b[o] = sb / n
                }
            }
            return out
        }

        var luma: [Float] { (0..<(w * h)).map { 0.2126 * r[$0] + 0.7152 * g[$0] + 0.0722 * b[$0] } }
    }

    /// `image` denoised, the same size and colour space; nil if it cannot be (or `cancelled` says so).
    /// `progress` hears how far it is, 0…1, after every tile, on the calling thread.
    /// `coarse`: the screen-sized picture and what this denoiser made of it. A larger picture then
    /// takes its coarse noise from there, enlarged, and only its own finest noise at full size: the
    /// grain was judged once, on the picture as it shows, and is not judged again differently.
    func denoise(_ image: CGImage, coarse: (original: CGImage, denoised: CGImage)? = nil,
                 progress: ((Double) -> Void)? = nil, cancelled: () -> Bool = { false }) -> CGImage? {
        guard let model else { return nil }
        let w = image.width, h = image.height
        let own = image.colorSpace.flatMap { $0.model == .rgb && !CGColorSpaceUsesExtendedRange($0) ? $0 : nil }
        guard let space = own ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // In: encoded RGB as floats, 0…1, in the picture's own colour space.
        var pixels = [Float](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var planes = Planes(w: w, h: h)
        for i in 0..<(w * h) {
            let a = max(pixels[i * 4 + 3], 1e-4)
            planes.r[i] = pixels[i * 4] / a; planes.g[i] = pixels[i * 4 + 1] / a; planes.b[i] = pixels[i * 4 + 2] / a
        }

        var scales: [Int] = []
        if let coarse, coarse.original.width < w, let residual = Self.residual(coarse, space: space) {
            // What the screen-sized pass took out, enlarged and taken out here.
            Self.subtract(residual, from: &planes)
            timingMark("denoise: coarse noise from the screen-sized pass")
        } else {
            let l = planes.luma
            let half = PictureMeasure.shrink(l, width: w, height: h, by: 2)
            let quarter = PictureMeasure.shrink(half.plane, width: half.width, height: half.height, by: 2)
            let levels = (full: PictureMeasure.flatNoise(l, width: w, height: h),
                          half: PictureMeasure.flatNoise(half.plane, width: half.width, height: half.height),
                          quarter: PictureMeasure.flatNoise(quarter.plane, width: quarter.width, height: quarter.height))
            scales = PictureMeasure.grainScales(levels)
        }
        timingMark("denoise: grain scales \(scales.isEmpty ? "fine only" : scales.map { "1/\($0)" }.joined(separator: ", "))")
        // Progress in tiles, across every pass.
        let total = ([1] + scales).reduce(0) { $0 + Self.tileCount(w / $1, h / $1) }
        var done = 0
        let tick = { done += 1; progress?(Double(done) / Double(max(total, 1))) }
        progress?(0)

        // Coarse grain first, at the scale where it is pixel-sized: only what the network took out
        // there comes back up, enlarged, and is taken out here.
        for k in scales {
            if cancelled() { return nil }
            let small = planes.shrunk(by: k)
            guard let clean = run(model, small, tick: tick, cancelled: cancelled) else { return nil }
            var residual = small
            for i in 0..<(small.w * small.h) {
                residual.r[i] -= clean.r[i]; residual.g[i] -= clean.g[i]; residual.b[i] -= clean.b[i]
            }
            Self.subtract(residual, from: &planes)
        }
        // Then the fine noise, at full size.
        guard let clean = run(model, planes, tick: tick, cancelled: cancelled) else { return nil }

        // Out: alpha as it was, premultiplied again.
        for i in 0..<(w * h) {
            let a = pixels[i * 4 + 3]
            pixels[i * 4] = min(max(clean.r[i], 0), 1) * a
            pixels[i * 4 + 1] = min(max(clean.g[i], 0), 1) * a
            pixels[i * 4 + 2] = min(max(clean.b[i], 0), 1) * a
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// `p` minus `residual` enlarged to its size, bilinear, centres aligned.
    private static func subtract(_ residual: Planes, from p: inout Planes) {
        let sx = Float(residual.w) / Float(p.w), sy = Float(residual.h) / Float(p.h)
        let rw = residual.w
        for y in 0..<p.h {
            let fy = min(max((Float(y) + 0.5) * sy - 0.5, 0), Float(residual.h - 1))
            let y0 = Int(fy), y1 = min(y0 + 1, residual.h - 1), ty = fy - Float(y0)
            for x in 0..<p.w {
                let fx = min(max((Float(x) + 0.5) * sx - 0.5, 0), Float(rw - 1))
                let x0 = Int(fx), x1 = min(x0 + 1, rw - 1), tx = fx - Float(x0)
                let i00 = y0 * rw + x0, i01 = y0 * rw + x1, i10 = y1 * rw + x0, i11 = y1 * rw + x1
                let w00 = (1 - tx) * (1 - ty), w01 = tx * (1 - ty), w10 = (1 - tx) * ty, w11 = tx * ty
                let i = y * p.w + x
                p.r[i] -= residual.r[i00] * w00 + residual.r[i01] * w01 + residual.r[i10] * w10 + residual.r[i11] * w11
                p.g[i] -= residual.g[i00] * w00 + residual.g[i01] * w01 + residual.g[i10] * w10 + residual.g[i11] * w11
                p.b[i] -= residual.b[i00] * w00 + residual.b[i01] * w01 + residual.b[i10] * w10 + residual.b[i11] * w11
            }
        }
    }

    /// The screen-sized picture minus what the denoiser made of it: the noise it found.
    private static func residual(_ pair: (original: CGImage, denoised: CGImage), space: CGColorSpace) -> Planes? {
        guard pair.original.width == pair.denoised.width, pair.original.height == pair.denoised.height,
              let a = planes(of: pair.original, space: space), let b = planes(of: pair.denoised, space: space) else { return nil }
        var out = a
        for i in 0..<(a.w * a.h) { out.r[i] -= b.r[i]; out.g[i] -= b.g[i]; out.b[i] -= b.b[i] }
        return out
    }

    private static func planes(of image: CGImage, space: CGColorSpace) -> Planes? {
        let w = image.width, h = image.height
        var px = [Float](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var p = Planes(w: w, h: h)
        for i in 0..<(w * h) {
            let a = max(px[i * 4 + 3], 1e-4)
            p.r[i] = px[i * 4] / a; p.g[i] = px[i * 4 + 1] / a; p.b[i] = px[i * 4 + 2] / a
        }
        return p
    }

    private static func origins(_ size: Int) -> [Int] {
        let t = tile, stride = tile - 2 * overlap
        guard size > t else { return [0] }
        var out = Array(Swift.stride(from: 0, to: size - t, by: stride))
        out.append(size - t)
        return out
    }

    private static func tileCount(_ w: Int, _ h: Int) -> Int { origins(max(w, 1)).count * origins(max(h, 1)).count }

    /// The network over `p`, tile by tile, blended across the overlaps.
    private func run(_ model: MLModel, _ p: Planes, tick: () -> Void, cancelled: () -> Bool) -> Planes? {
        let t = Self.tile, o = Self.overlap, w = p.w, h = p.h, plane = t * t
        var out = Planes(w: w, h: h)
        var weight = [Float](repeating: 0, count: w * h)
        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: t), NSNumber(value: t)], dataType: .float16) else { return nil }
        // A weight that rises across the overlap, so neighbouring tiles fade into each other.
        let ramp: [Float] = (0..<t).map { i in min(1, (Float(min(i, t - 1 - i)) + 1) / Float(o)) }
        for y0 in Self.origins(h) {
            for x0 in Self.origins(w) {
                if cancelled() { return nil }
                defer { tick() }
                // The tile; past the picture's edges (small pictures), mirrored.
                var tileIn = [Float](repeating: 0, count: plane * 3)
                for ty in 0..<t {
                    var sy = y0 + ty
                    if sy >= h { sy = max(0, 2 * h - 2 - sy) }
                    for tx in 0..<t {
                        var sx = x0 + tx
                        if sx >= w { sx = max(0, 2 * w - 2 - sx) }
                        let s = sy * w + sx, q = ty * t + tx
                        tileIn[q] = p.r[s]; tileIn[plane + q] = p.g[s]; tileIn[2 * plane + q] = p.b[s]
                    }
                }
                let mean = tileIn.reduce(0, +) / Float(tileIn.count)
                var tileOut = tileIn
                for target: Float in [0.15, 0.3] {
                    guard let attempt = predict(model, input, tileIn, lift: Self.lift(mean: mean, to: target)) else { return nil }
                    // Noise is a few hundredths at most; a tile that moved on average by more went wrong.
                    var moved: Float = 0
                    for i in 0..<tileIn.count { moved += abs(attempt[i] - tileIn[i]) }
                    if moved / Float(tileIn.count) < 0.04 { tileOut = attempt; break }
                    timingMark(String(format: "denoise: tile at %d,%d diverged (mean %.3f, lifted to %.2f)", x0, y0, mean, target))
                }
                for ty in 0..<t where y0 + ty < h {
                    // Tiles at the picture's edge do not fade out towards it.
                    let wy = (y0 == 0 && ty < o) || (y0 + t >= h && ty >= t - o) ? 1 : ramp[ty]
                    for tx in 0..<t where x0 + tx < w {
                        let wx = (x0 == 0 && tx < o) || (x0 + t >= w && tx >= t - o) ? 1 : ramp[tx]
                        let wgt = wx * wy, q = ty * t + tx, d = (y0 + ty) * w + x0 + tx
                        out.r[d] += tileOut[q] * wgt
                        out.g[d] += tileOut[plane + q] * wgt
                        out.b[d] += tileOut[2 * plane + q] * wgt
                        weight[d] += wgt
                    }
                }
            }
        }
        for i in 0..<(w * h) {
            let k = 1 / max(weight[i], 1e-6)
            out.r[i] *= k; out.g[i] *= k; out.b[i] *= k
        }
        return out
    }

    /// The curve's `a` that lifts a tile whose mean is `mean` to `target`; 0 for a tile bright enough.
    private static func lift(mean: Float, to target: Float) -> Float {
        guard mean < target else { return 0 }
        return min((target - mean) / (max(mean, 0.002) * (1 - target)), 64)
    }

    /// One tile through the network, planar RGB in and out, lifted by y = x(1 + a)/(1 + ax) on the
    /// way in and lowered by its inverse on the way out.
    private func predict(_ model: MLModel, _ input: MLMultiArray, _ tile: [Float], lift a: Float) -> [Float]? {
        let n = tile.count
        let inPtr = input.dataPointer.bindMemory(to: Float16.self, capacity: n)
        for i in 0..<n {
            let x = min(max(tile[i], 0), 1)
            inPtr[i] = Float16(a > 0 ? x * (1 + a) / (1 + a * x) : tile[i])
        }
        guard let result = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input])),
              let res = result.featureValue(for: "output")?.multiArrayValue else { return nil }
        let outPtr = res.dataPointer.bindMemory(to: Float16.self, capacity: n)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let y = Float(outPtr[i])
            if a > 0 {
                let c = min(max(y, 0), 1)
                out[i] = c / (1 + a - a * c)
            } else {
                out[i] = y
            }
        }
        return out
    }
}
