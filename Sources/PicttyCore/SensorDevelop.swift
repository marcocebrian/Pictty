import CLibRaw
import CoreGraphics
import CoreML
import Foundation

/// A camera RAW developed from its sensor mosaic: LibRaw reads the photosites, and a learned
/// network (GPL 3.0 or later; Models/README.md) demosaics and denoises them in one pass, before the noise has been smeared by a demosaic. What
/// comes out is linear light in extended sRGB, unclipped, the same kind of picture Apple's develop
/// gives Pictty's engine; everything after it (exposure, white balance, Highlights and the rest) is
/// the engine's, as for any picture.
///
/// The steps, as the network was trained for them: levels normalised to 0…1 per filter colour; the frame's own
/// noise measured as a line in level (`NoiseModel.estimate`); the white balance's gains; the
/// variance-stabilising transform the network was trained in; the network over tiles with a margin,
/// mirrored at the edges without changing the Bayer phase; the transform undone. Then the camera's
/// matrix into sRGB.
///
/// Nothing is clipped at white: after the gains a channel goes past 1 where the sensor did not
/// saturate, and that light is what Highlights brings back. Where the sensor did saturate, the
/// photosite is reconstructed before the network sees it (`reconstructHighlights`, darktable's
/// "inpaint opposed"): a blown lamp keeps the colour of its light and shape in its brightest part,
/// instead of turning magenta or flat white.
///
/// Any step that cannot be done throws, and the caller develops with Apple's engine instead.
public enum SensorDevelop {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable, notBayer(String), noModel, network(String)

        public var description: String {
            switch self {
            case .unreadable: "LibRaw cannot read the file"
            case .notBayer(let why): "not a 2×2 Bayer mosaic (\(why))"
            case .noModel: "the network is not here"
            case .network(let why): "the network failed: \(why)"
            }
        }
    }

    /// The network's tile, in photosites, and the margin around it that is computed and dropped.
    /// The Core ML model takes this one shape: (1024 + 2 × 96) / 2 = 608 packed.
    static let tile = 1024, margin = 96
    static let packedSide = (tile + 2 * margin) / 2

    /// The network, loaded once.
    private static let modelLock = NSLock()
    private static var loadedModels: [URL: MLModel] = [:]

    private static func model(at url: URL) throws -> MLModel {
        modelLock.lock(); defer { modelLock.unlock() }
        if let m = loadedModels[url] { return m }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            let m = try MLModel(contentsOf: url, configuration: config)
            loadedModels[url] = m
            return m
        } catch {
            throw Failure.network("\(error)")
        }
    }

    // MARK: - The mosaic

    /// A Bayer mosaic as the network takes it.
    struct Mosaic {
        /// Levels normalised to 0…1 per filter colour, the white balance not yet applied.
        var samples: [Float]
        let width: Int, height: Int
        /// Where the 2×2 pattern reads R G / G B.
        let dx: Int, dy: Int
        /// The white balance as shot, green 1.
        let gains: SIMD3<Float>
        /// White-balanced camera RGB to linear sRGB, by rows.
        let camToSRGB: [SIMD3<Float>]
        /// LibRaw's orientation: 0 none, 3 half a turn, 5 a quarter anticlockwise, 6 clockwise.
        let flip: Int
        /// The normalised level at which the sensor saturates (LibRaw's linearity limit).
        let saturation: Float

        /// The filter colour (0 red, 1 green, 2 blue) at a sample.
        @inline(__always) func colour(_ x: Int, _ y: Int) -> Int {
            let px = (x + dx) & 1, py = (y + dy) & 1
            return py == 0 ? (px == 0 ? 0 : 1) : (px == 0 ? 1 : 2)
        }
    }

    static func read(_ url: URL) throws -> Mosaic {
        guard let raw = url.withUnsafeFileSystemRepresentation({ $0.flatMap { pictty_libraw_open($0) } }) else {
            throw Failure.unreadable
        }
        defer { pictty_libraw_close(raw) }
        let d = raw.pointee
        guard d.idata.colors == 3, d.idata.filters != 0, d.idata.filters != 9, let image = d.rawdata.raw_image else {
            throw Failure.notBayer("colours \(d.idata.colors), filters \(d.idata.filters)")
        }
        let s = d.sizes
        let visibleW = Int(s.width), visibleH = Int(s.height)
        // The default crop the camera means (what Apple's develop shows too), when there is one.
        var cx = 0, cy = 0, cw = visibleW, ch = visibleH
        let inset = s.raw_inset_crops.0
        if inset.cwidth > 0, inset.cheight > 0, Int(inset.cleft) + Int(inset.cwidth) <= visibleW,
           Int(inset.ctop) + Int(inset.cheight) <= visibleH {
            cx = Int(inset.cleft); cy = Int(inset.ctop); cw = Int(inset.cwidth); ch = Int(inset.cheight)
        }
        // The pattern, from LibRaw's colour of each of the four positions: it must be R, G, G, B.
        var lr = [[Int]](repeating: [0, 0], count: 2)
        for y in 0..<2 { for x in 0..<2 { lr[y][x] = Int(pictty_libraw_color(raw, Int32(cy + y), Int32(cx + x))) } }
        let rgb = lr.map { $0.map { $0 == 3 ? 1 : $0 } }
        guard let (dx, dy) = [(0, 0), (1, 0), (0, 1), (1, 1)].first(where: { ox, oy in
            rgb[oy][ox] == 0 && rgb[oy][1 - ox] == 1 && rgb[1 - oy][ox] == 1 && rgb[1 - oy][1 - ox] == 2
        }) else { throw Failure.notBayer("pattern \(lr)") }

        // Black per filter position (and LibRaw's repeating black pattern, when it has one), white.
        let c = d.color
        let patternSize = Int(pictty_libraw_cblack(raw, 4)) * Int(pictty_libraw_cblack(raw, 5))
        let cblack = (0..<(6 + min(patternSize, 4096))).map { pictty_libraw_cblack(raw, Int32($0)) }
        let maximum = Float(c.maximum)
        let linearMax = withUnsafeBytes(of: c.linear_max) { Array($0.bindMemory(to: UInt32.self)) }
        let pitch = Int(s.raw_pitch) / 2, top = Int(s.top_margin), left = Int(s.left_margin)
        let patternH = Int(cblack[4]), patternW = Int(cblack[5])
        func black(_ row: Int, _ col: Int, _ colour: Int) -> Float {
            var b = Float(c.black) + Float(cblack[colour])
            if patternH > 0, patternW > 0 { b += Float(cblack[6 + (row % patternH) * patternW + col % patternW]) }
            return b
        }
        var blacks = [[Float]](repeating: [0, 0], count: 2)
        for y in 0..<2 { for x in 0..<2 { blacks[y][x] = black(cy + y, cx + x, lr[y][x]) } }
        let anyBlack = blacks.joined().max() ?? 0
        // Saturation: LibRaw's linearity limit where it knows one, else 98 % of the range.
        let limit = linearMax.filter { $0 > 0 }.min().map { Float($0) } ?? maximum
        let saturation = min(max((limit - anyBlack) / max(maximum - anyBlack, 1), 0.5), 1)
        guard maximum > anyBlack else { throw Failure.unreadable }

        var samples = [Float](repeating: 0, count: cw * ch)
        let patterned = patternH > 0 && patternW > 0
        samples.withUnsafeMutableBufferPointer { out in
            let o = out
            DispatchQueue.concurrentPerform(iterations: ch) { y in
                let row = cy + y
                let src = image + (row + top) * pitch + left + cx
                for x in 0..<cw {
                    let b = patterned ? black(row, cx + x, lr[y & 1][x & 1]) : blacks[y & 1][x & 1]
                    let v = (Float(src[x]) - b) / (maximum - b)
                    o[y * cw + x] = min(max(v, 0), 1)
                }
            }
        }

        // The white balance as shot: LibRaw's camera multipliers, else its daylight ones.
        let cam = withUnsafeBytes(of: c.cam_mul) { Array($0.bindMemory(to: Float.self)) }
        let pre = withUnsafeBytes(of: c.pre_mul) { Array($0.bindMemory(to: Float.self)) }
        let mul = cam[0] > 0 && cam[1] > 0 && cam[2] > 0 ? cam : pre
        guard mul[1] > 0 else { throw Failure.unreadable }
        let gains = SIMD3<Float>(mul[0] / mul[1], 1, mul[2] / mul[1])
        // rgb_cam is 3 × 4: white-balanced camera RGB (and a fourth colour, unused) to linear sRGB.
        let m = withUnsafeBytes(of: c.rgb_cam) { Array($0.bindMemory(to: Float.self)) }
        let camToSRGB = (0..<3).map { r in SIMD3<Float>(m[r * 4], m[r * 4 + 1], m[r * 4 + 2]) }
        return Mosaic(samples: samples, width: cw, height: ch, dx: dx, dy: dy, gains: gains, camToSRGB: camToSRGB,
                      flip: Int(s.flip), saturation: saturation)
    }

    // MARK: - Noise

    /// Variance as a line in level per channel, `a x + b` .
    struct NoiseModel {
        var a = SIMD3<Float>(repeating: 0), b = SIMD3<Float>(repeating: 0)

        /// The same data with each channel multiplied by its gain: `g a y + g² b`.
        func afterGains(_ g: SIMD3<Float>) -> NoiseModel { NoiseModel(a: g * a, b: g * g * b) }
    }

    /// The estimate from the mosaic itself (`estimate_noise`, for Bayer): in 16 × 16 blocks,
    /// per filter colour, the squared residual of each sample against the mean of its four
    /// same-colour neighbours two away (1.25 times the variance for white noise); the blocks binned
    /// by level, evenly in its square root; in each bin the quietest quarter, corrected for picking
    /// it; and a line through the bins weighted by their blocks. Clipped blocks are left out.
    static func estimateNoise(_ m: Mosaic) -> NoiseModel {
        let block = 16, bins = 32, minBlocksPerBin = 8, minSamples = 32
        let clip: Float = 0.98, residualGain: Float = 1.25
        let w = m.width, h = m.height
        guard w >= block + 4, h >= block + 4 else { return NoiseModel() }
        let rows = Array(stride(from: 2, through: h - 2 - block, by: block))
        var perRow = [[[(Float, Float, Int)]]](repeating: [], count: rows.count)
        m.samples.withUnsafeBufferPointer { s in
            perRow.withUnsafeMutableBufferPointer { out in
                let o = out
                DispatchQueue.concurrentPerform(iterations: rows.count) { r in
                    let by = rows[r]
                    var found = [[(Float, Float, Int)]](repeating: [], count: 3 * bins)
                    for bx in stride(from: 2, through: w - 2 - block, by: block) {
                        var sum = [Double](repeating: 0, count: 3), sq = sum, n = [0, 0, 0]
                        var clipped = false
                        blockLoop: for y in by..<(by + block) {
                            for x in bx..<(bx + block) {
                                let i = y * w + x, v = s[i]
                                if v >= clip { clipped = true; break blockLoop }
                                let c = m.colour(x, y)
                                let r = v - (s[i - 2] + s[i + 2] + s[i - 2 * w] + s[i + 2 * w]) * 0.25
                                sum[c] += Double(v); sq[c] += Double(r * r); n[c] += 1
                            }
                        }
                        if clipped { continue }
                        for c in 0..<3 where n[c] >= minSamples {
                            let mean = Float(sum[c] / Double(n[c]))
                            let variance = Float(sq[c] / Double(n[c])) / residualGain
                            let bin = min(Int(max(mean, 0).squareRoot() * Float(bins)), bins - 1)
                            found[c * bins + bin].append((mean, variance, n[c]))
                        }
                    }
                    o[r] = found
                }
            }
        }
        var model = NoiseModel()
        for c in 0..<3 {
            var points: [(Double, Double, Double)] = []
            for bin in 0..<bins {
                var blocks = perRow.flatMap { $0.isEmpty ? [] : $0[c * bins + bin] }
                guard blocks.count >= minBlocksPerBin else { continue }
                blocks.sort { $0.1 < $1.1 }
                let quiet = blocks.prefix(max(blocks.count / 4, 2))
                let count = Double(quiet.count)
                let mean = quiet.reduce(0) { $0 + Double($1.0) } / count
                let variance = quiet.reduce(0) { $0 + Double($1.1) } / count
                let samples = Double(quiet.reduce(0) { $0 + $1.2 }) / count
                // The quietest quarter of unbiased estimates averages 1 − 1.271 √(2/n) of the truth.
                let bias = 1 - 1.271 * (2 / samples).squareRoot()
                points.append((mean, variance / max(bias, 0.5), Double(blocks.count)))
            }
            let (a, b) = weightedLine(points)
            model.a[c] = Float(a); model.b[c] = Float(b)
        }
        return model
    }

    /// Least squares of variance on level, weighted, held to a slope and a foot of 0 or more.
    static func weightedLine(_ points: [(Double, Double, Double)]) -> (Double, Double) {
        var sw = 0.0, swx = 0.0, swy = 0.0, swxx = 0.0, swxy = 0.0
        for (x, y, w) in points { sw += w; swx += w * x; swy += w * y; swxx += w * x * x; swxy += w * x * y }
        guard sw > 0 else { return (0, 0) }
        let det = sw * swxx - swx * swx
        var a: Double, b: Double
        if points.count >= 2, abs(det) > 1e-18 {
            a = (sw * swxy - swx * swy) / det
            b = (swxx * swy - swx * swxy) / det
        } else {
            a = 0; b = swy / sw
        }
        if a < 0 { a = 0; b = swy / sw }
        if b < 0 { b = 0; a = swxx > 0 ? swxy / swxx : 0 }
        return (a, b)
    }

    /// The generalised Anscombe transform that gives noise `a x + b` unit variance, shifted to 0
    /// at 0, and its algebraic inverse for a clean estimate.
    struct Vst {
        let a: Float, s0: Float

        init(a: Float, b: Float) {
            // A silent channel is given the faintest read noise, so the network sees a finite picture.
            let (a, b) = a <= 0 && b <= 0 ? (Float(0), Float(1e-8)) : (a, b)
            self.a = a
            s0 = (3 / 8 * a * a + b).squareRoot()
        }

        @inline(__always) func forward(_ x: Float) -> Float { 2 * x / ((a * x + s0 * s0).squareRoot() + s0) }
        @inline(__always) func inverse(_ d: Float) -> Float { a * d * d / 4 + d * s0 }
    }

    // MARK: - The develop

    /// The whole picture developed: linear extended sRGB, half float, upright. `progress` hears
    /// 0…1 after each tile.
    public static func develop(_ url: URL, model modelURL: URL?, progress: ((Double) -> Void)? = nil,
                               cancelled: () -> Bool = { false }) throws -> CGImage {
        try developed(url, model: modelURL, progress: progress, cancelled: cancelled).image
    }

    /// The develop, and where the sensor clipped (`clipped`, 0…1 per pixel of it, upright, softened
    /// over a few pixels; nil when nothing did): what no develop can know, and Apple's takes over.
    public static func developed(_ url: URL, model modelURL: URL?, progress: ((Double) -> Void)? = nil,
                                 cancelled: () -> Bool = { false }) throws -> (image: CGImage, clipped: [Float]?) {
        guard let modelURL else { throw Failure.noModel }
        let network = try model(at: modelURL)
        var m = try read(url)
        let noise = estimateNoise(m)
        // The white balance, and nothing clipped: past 1 is light for Highlights.
        let (w, h, dx, dy, gains) = (m.width, m.height, m.dx, m.dy, m.gains)
        m.samples.withUnsafeMutableBufferPointer { s in
            let s = s
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let px = (x + dx) & 1, py = (y + dy) & 1
                    s[y * w + x] *= gains[py == 0 ? (px == 0 ? 0 : 1) : (px == 0 ? 1 : 2)]
                }
            }
        }
        let share = clippedShare(m)
        reconstructHighlights(&m)
        let model = noise.afterGains(m.gains)
        let vst = (0..<3).map { Vst(a: model.a[$0], b: model.b[$0]) }
        let rgb = try runNetwork(network, m, vst, progress: progress, cancelled: cancelled)
        let image = try picture(rgb, m)
        guard let share else { return (image, nil) }
        var soft = share
        for _ in 0..<2 { soft = boxBlur(soft, m.width, m.height, radius: 2) }
        return (image, oriented(soft, m))
    }

    /// The network over the mosaic, tile by tile: interleaved white-balanced camera RGB.
    static func runNetwork(_ network: MLModel, _ m: Mosaic, _ vst: [Vst], progress: ((Double) -> Void)?,
                           cancelled: () -> Bool) throws -> [Float] {
        let w = m.width, h = m.height, side = tile + 2 * margin, half = packedSide
        guard w >= 4, h >= 4 else { throw Failure.notBayer("too small") }
        func fold(_ i: Int, _ n: Int) -> Int {
            // A reflection about the edge sample keeps the Bayer phase: −1 reads 1, n reads n − 2.
            let period = 2 * (n - 1)
            var i = ((i % period) + period) % period
            if i >= n { i = period - i }
            return i
        }
        var out = [Float](repeating: 0, count: w * h * 3)
        guard let input = try? MLMultiArray(shape: [1, 4, NSNumber(value: half), NSNumber(value: half)], dataType: .float32) else {
            throw Failure.network("no input array")
        }
        let origins = { (n: Int, phase: Int) -> [Int] in Array(stride(from: -2 * phase, to: n, by: tile)) }
        let ys = origins(h, m.dy), xs = origins(w, m.dx)
        var done = 0
        try m.samples.withUnsafeBufferPointer { s in
            try out.withUnsafeMutableBufferPointer { o in
                for ty in ys {
                    for tx in xs {
                        if cancelled() { throw Failure.network("cancelled") }
                        // The tile's window in sample coordinates, starting on an R.
                        let yIn = ty + m.dy - margin, xIn = tx + m.dx - margin
                        let packed = input.dataPointer.bindMemory(to: Float.self, capacity: 4 * half * half)
                        DispatchQueue.concurrentPerform(iterations: side) { yy in
                            let sy = fold(yIn + yy, h)
                            for xx in 0..<side {
                                let sx = fold(xIn + xx, w)
                                let v = max(s[sy * w + sx], 0)
                                let (c, plane) = yy & 1 == 0 ? (xx & 1 == 0 ? (0, 0) : (1, 1)) : (xx & 1 == 0 ? (1, 2) : (2, 3))
                                packed[plane * half * half + (yy / 2) * half + xx / 2] = vst[c].forward(v)
                            }
                        }
                        let result: MLFeatureProvider
                        do {
                            result = try network.prediction(from: MLDictionaryFeatureProvider(dictionary: ["packed": input]))
                        } catch {
                            throw Failure.network("\(error)")
                        }
                        guard let rgb = result.featureValue(for: "rgb")?.multiArrayValue, rgb.count == 3 * side * side else {
                            throw Failure.network("no output")
                        }
                        let r = rgb.dataPointer.bindMemory(to: Float.self, capacity: 3 * side * side)
                        if let why = implausible(packed, r, side: side) { throw Failure.network(why) }
                        // The tile's core: what the margin does not cover.
                        DispatchQueue.concurrentPerform(iterations: side - 2 * margin) { k in
                            let yy = margin + k, sy = yIn + yy
                            guard sy >= 0, sy < h else { return }
                            for xx in margin..<(side - margin) {
                                let sx = xIn + xx
                                guard sx >= 0, sx < w else { continue }
                                let i = (sy * w + sx) * 3
                                for c in 0..<3 { o[i + c] = vst[c].inverse(r[c * side * side + yy * side + xx]) }
                            }
                        }
                        done += 1
                        progress?(Double(done) / Double(ys.count * xs.count))
                    }
                }
            }
        }
        return out
    }

    /// Why a tile's answer cannot be right (the reference check): not finite, or further from its input
    /// on average than a denoiser moves it (the noise is unit variance in this space), allowing a
    /// twentieth of the tile's range for what a demosaic moves between neighbours.
    static func implausible(_ packed: UnsafePointer<Float>, _ rgb: UnsafePointer<Float>, side: Int) -> String? {
        let half = side / 2
        var sum = 0.0, n = 0
        var lo = Float.infinity, hi = -Float.infinity
        for yy in margin..<(side - margin) {
            for xx in margin..<(side - margin) {
                let (c, plane) = yy & 1 == 0 ? (xx & 1 == 0 ? (0, 0) : (1, 1)) : (xx & 1 == 0 ? (1, 2) : (2, 3))
                let input = packed[plane * half * half + (yy / 2) * half + xx / 2]
                let out = rgb[c * side * side + yy * side + xx]
                if !out.isFinite { return "a value of \(out)" }
                sum += Double(abs(out - input)); n += 1
                lo = min(lo, input); hi = max(hi, input)
            }
        }
        let mean = sum / Double(max(n, 1))
        return mean > 3 + 0.05 * Double(max(hi - lo, 0)) ? String(format: "a tile %.1f units from its input", mean) : nil
    }

    /// Clipped photosites rebuilt before the demosaic: darktable's "inpaint opposed" (Hanno Schwalm,
    /// with garagecoder and Iain of the G'MIC team; GPL 3.0 or later). A clipped
    /// photosite is estimated by the other two colours of its 3 × 3, averaged in cube-root space, plus
    /// a per-colour offset measured on the unclipped photosites just outside the clipped areas (the
    /// colour of the light there), and never below what it read. A neighbourhood clipped all through
    /// has nothing to go by: it goes to neutral, above the ceiling everything else is held to, so a
    /// neon's letters stand out of their glow. Then everything is
    /// held to that brightest clip, but the cores clipped all through.
    static func reconstructHighlights(_ m: inout Mosaic) {
        let magic: Float = 0.987, lowClip: Float = 0.2, minVotes = 100
        let w = m.width, h = m.height
        let clips = m.gains * (m.saturation * magic)
        let (pdx, pdy) = (m.dx, m.dy)
        @inline(__always) func colour(_ x: Int, _ y: Int) -> Int {
            let px = (x + pdx) & 1, py = (y + pdy) & 1
            return py == 0 ? (px == 0 ? 0 : 1) : (px == 0 ? 1 : 2)
        }
        // Clipped, per colour, on a grid of 3 × 3 blocks.
        let mw = (w + 2) / 3, mh = (h + 2) / 3
        var mask = [UInt8](repeating: 0, count: mw * mh)
        var clipped = 0
        m.samples.withUnsafeBufferPointer { s in
            for y in 0..<h {
                for x in 0..<w where s[y * w + x] >= clips[colour(x, y)] {
                    mask[(y / 3) * mw + x / 3] |= 1 << colour(x, y)
                    clipped += 1
                }
            }
        }
        guard clipped > 0 else { return }
        // Dilated by about three blocks (the 3 × 3, then a ring to three with the corners cut), to
        // find the photosites just outside.
        // (The 7 × 7 without its four corners: 45 offsets.)
        var ring: [(Int, Int)] = []
        for dy in -3...3 { for dx in -3...3 where !(abs(dx) == 3 && abs(dy) == 3) { ring.append((dx, dy)) } }
        var dilated = mask
        mask.withUnsafeBufferPointer { mk in
            dilated.withUnsafeMutableBufferPointer { d in
                let d = d
                DispatchQueue.concurrentPerform(iterations: mh) { by in
                    for bx in 0..<mw where bx >= 3 && by >= 3 && bx < mw - 3 && by < mh - 3 {
                        var bits: UInt8 = 0
                        for (dx, dy) in ring { bits |= mk[(by + dy) * mw + bx + dx] }
                        d[by * mw + bx] = bits
                    }
                }
            }
        }
        // The opposed average at a photosite, and whether its whole 3 × 3 was clipped.
        func refavg(_ s: UnsafeBufferPointer<Float>, _ x: Int, _ y: Int, _ c: Int) -> (Float, Bool) {
            var sum = SIMD3<Float>(repeating: 0), cnt = SIMD3<Float>(repeating: 0)
            var all = true
            for ny in max(y - 1, 0)...min(y + 1, h - 1) {
                for nx in max(x - 1, 0)...min(x + 1, w - 1) {
                    let k = colour(nx, ny), v = s[ny * w + nx]
                    all = all && v >= clips[k]
                    sum[k] += max(v, 0); cnt[k] += 1
                }
            }
            let mean = SIMD3<Float>((0..<3).map { cnt[$0] > 0 ? cbrt(sum[$0] / cnt[$0]) : 0 })
            let root = c == 0 ? 0.5 * (mean.y + mean.z) : c == 1 ? 0.5 * (mean.x + mean.z) : 0.5 * (mean.x + mean.y)
            return (root * root * root, all)
        }
        // The colour of the light around the clipped areas: per colour, what unclipped photosites
        // near them read against what the opposed average would have guessed.
        var rowSums = [SIMD3<Double>](repeating: .zero, count: h), rowVotes = [SIMD3<Int>](repeating: .zero, count: h)
        m.samples.withUnsafeBufferPointer { s in
            dilated.withUnsafeBufferPointer { d in
                rowSums.withUnsafeMutableBufferPointer { rs in
                    rowVotes.withUnsafeMutableBufferPointer { rv in
                        let (rs, rv) = (rs, rv)
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            var sums = SIMD3<Double>.zero, votes = SIMD3<Int>.zero
                            for x in 0..<w {
                                let c = colour(x, y), v = s[y * w + x]
                                guard v > lowClip * clips[c], v < clips[c], d[(y / 3) * mw + x / 3] & (1 << c) != 0 else { continue }
                                sums[c] += Double(v - refavg(s, x, y, c).0); votes[c] += 1
                            }
                            rs[y] = sums; rv[y] = votes
                        }
                    }
                }
            }
        }
        let sums = rowSums.reduce(.zero, +), votes = rowVotes.reduce(.zero, &+)
        let chrominance = SIMD3<Float>((0..<3).map { votes[$0] > minVotes ? Float(sums[$0] / Double(votes[$0])) : 0 })
        // Fill, never below what was read; all clipped goes to neutral at the brightest clip.
        let white = clips.max() / magic, ceiling = m.gains.max()
        var out = m.samples
        m.samples.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                let o = o
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let c = colour(x, y), v = s[y * w + x]
                        var r = v
                        if v >= clips[c] {
                            let (ref, all) = refavg(s, x, y, c)
                            if all { o[y * w + x] = white; continue }
                            r = max(v, ref + chrominance[c])
                        }
                        o[y * w + x] = min(r, ceiling)
                    }
                }
            }
        }
        m.samples = out
    }

    /// Per photosite, the share of its 3 × 3 that clipped (after the white balance), 0…1; nil when
    /// nothing did. (Called before the reconstruction, which fills the clipped photosites in.)
    static func clippedShare(_ m: Mosaic) -> [Float]? {
        let w = m.width, h = m.height
        let clips = m.gains * (m.saturation * 0.987)
        var hit = [Float](repeating: 0, count: w * h)
        var any = false
        m.samples.withUnsafeBufferPointer { s in
            for y in 0..<h { for x in 0..<w where s[y * w + x] >= clips[m.colour(x, y)] { hit[y * w + x] = 1; any = true } }
        }
        guard any else { return nil }
        var share = [Float](repeating: 0, count: w * h)
        hit.withUnsafeBufferPointer { t in share.withUnsafeMutableBufferPointer { o in
            let o = o
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    var n: Float = 0, c: Float = 0
                    for ny in max(y - 1, 0)...min(y + 1, h - 1) { for nx in max(x - 1, 0)...min(x + 1, w - 1) { n += t[ny * w + nx]; c += 1 } }
                    o[y * w + x] = n / c
                }
            }
        } }
        return share
    }

    /// A box blur of `r` pixels each way, separable, edges clamped.
    static func boxBlur(_ v: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: w * h), out = tmp
        let n = Float(2 * r + 1)
        v.withUnsafeBufferPointer { v in tmp.withUnsafeMutableBufferPointer { t in
            let t = t
            DispatchQueue.concurrentPerform(iterations: h) { y in
                var acc: Float = 0
                for k in -r...r { acc += v[y * w + min(max(k, 0), w - 1)] }
                for x in 0..<w {
                    t[y * w + x] = acc / n
                    acc += v[y * w + min(x + r + 1, w - 1)] - v[y * w + max(x - r, 0)]
                }
            }
        } }
        tmp.withUnsafeBufferPointer { t in out.withUnsafeMutableBufferPointer { o in
            let o = o
            DispatchQueue.concurrentPerform(iterations: w) { x in
                var acc: Float = 0
                for k in -r...r { acc += t[min(max(k, 0), h - 1) * w + x] }
                for y in 0..<h {
                    o[y * w + x] = acc / n
                    acc += t[min(y + r + 1, h - 1) * w + x] - t[max(y - r, 0) * w + x]
                }
            }
        } }
        return out
    }

    /// A per-photosite map turned upright as `picture` turns the develop.
    static func oriented(_ v: [Float], _ m: Mosaic) -> [Float] {
        let w = m.width, h = m.height
        guard m.flip == 3 || m.flip == 5 || m.flip == 6 else { return v }
        let ow = (m.flip == 5 || m.flip == 6) ? h : w
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let (ox, oy): (Int, Int)
                switch m.flip {
                case 3: (ox, oy) = (w - 1 - x, h - 1 - y)
                case 5: (ox, oy) = (y, w - 1 - x)
                default: (ox, oy) = (h - 1 - y, x)
                }
                out[oy * ow + ox] = v[y * w + x]
            }
        }
        return out
    }

    /// The camera's matrix into linear sRGB, turned upright, as a half-float picture.
    static func picture(_ rgb: [Float], _ m: Mosaic) throws -> CGImage {
        let w = m.width, h = m.height
        let quarter = m.flip == 5 || m.flip == 6
        let ow = quarter ? h : w, oh = quarter ? w : h
        var px = [Float16](repeating: 1, count: ow * oh * 4)
        let r0 = m.camToSRGB[0], r1 = m.camToSRGB[1], r2 = m.camToSRGB[2]
        rgb.withUnsafeBufferPointer { s in
            px.withUnsafeMutableBufferPointer { o in
                let o = o
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let k = (y * w + x) * 3
                        let c = SIMD3<Float>(s[k], s[k + 1], s[k + 2])
                        let (ox, oy): (Int, Int)
                        switch m.flip {
                        case 3: (ox, oy) = (w - 1 - x, h - 1 - y)
                        case 5: (ox, oy) = (y, w - 1 - x)
                        case 6: (ox, oy) = (h - 1 - y, x)
                        default: (ox, oy) = (x, y)
                        }
                        let d = (oy * ow + ox) * 4
                        o[d] = Float16((r0 * c).sum()); o[d + 1] = Float16((r1 * c).sum()); o[d + 2] = Float16((r2 * c).sum())
                    }
                }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let provider = CGDataProvider(data: px.withUnsafeBytes { Data($0) } as CFData),
              let image = CGImage(width: ow, height: oh, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: ow * 8,
                                  space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw Failure.unreadable }
        return image
    }
}
