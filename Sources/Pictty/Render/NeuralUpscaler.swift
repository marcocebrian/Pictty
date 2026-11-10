import CoreGraphics
import CoreML
import Foundation
import PicttyCore
import Vision

/// Enlarge: BHI RealPLKSR 4× "real" (Philip Hofmann, CC-BY-4.0), a network trained on photos with
/// realistic noise, blur and compression, run by Core ML on the GPU in fixed square tiles
/// (`Models/README.md`). It brings back fine texture (fabric, fur, foliage, print) a plain
/// enlargement leaves soft; on faces it is not at its best, so faces are kept to a plain Lanczos
/// enlargement, faded in over a feathered ellipse.
///
/// Each tile is read with a margin around it and only its middle is kept, so the kept parts touch
/// without seams. A tile that comes back far from a Lanczos enlargement of itself, or with values
/// that are not numbers, is replaced by that enlargement. 2× is each 4× tile shrunk by half, in
/// linear light (`Resampler`), as it is written. Measured on an M5 Pro: about 2 s per input megapixel.
final class NeuralUpscaler: @unchecked Sendable {
    static let shared = NeuralUpscaler()

    private let lock = NSLock()
    private var loaded: MLModel?
    private var warm = false
    private let url: URL? = Bundle.main.url(forResource: "Upscale", withExtension: "mlmodelc")

    var isAvailable: Bool { url != nil }

    private var model: MLModel? {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        guard let url else { return nil }
        let config = MLModelConfiguration()
        // Measured: the Neural Engine is several times slower for this network than the GPU.
        config.computeUnits = .cpuAndGPU
        loaded = try? MLModel(contentsOf: url, configuration: config)
        return loaded
    }

    /// The tile and margin the model was converted for, from its metadata.
    private func geometry(_ model: MLModel) -> (tile: Int, margin: Int)? {
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        guard let t = meta?["tile"].flatMap(Int.init), let m = meta?["margin"].flatMap(Int.init) else { return nil }
        return (t, m)
    }

    /// Loads the network and runs it once, in the background: Core ML's first prediction on the GPU
    /// sets itself up (seconds), better spent while the person is choosing.
    func warmUp() {
        lock.lock()
        guard !warm, url != nil else { lock.unlock(); return }
        warm = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            guard let model = self.model, let g = self.geometry(model), let input = self.inputArray(model, side: g.tile + 2 * g.margin),
                  let features = try? MLDictionaryFeatureProvider(dictionary: ["input": input]) else { return }
            let start = CFAbsoluteTimeGetCurrent()
            _ = try? model.prediction(from: features)
            timingMark(String(format: "upscaler warmed up in %.0f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000))
        }
    }

    private func inputArray(_ model: MLModel, side: Int) -> MLMultiArray? {
        let type = model.modelDescription.inputDescriptionsByName["input"]?.multiArrayConstraint?.dataType ?? .float32
        return try? MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: type)
    }

    /// `image` enlarged `factor` times (2 or 4), in its own colour space; 8-bit stays 8-bit, deeper
    /// comes back 16-bit. Nil when there is no model, or `cancelled` says so between tiles.
    /// `progress` hears 0…1 as tiles go, on the calling thread. Call off the main thread.
    func enlarge(_ image: CGImage, factor: Int, cancelled: () -> Bool = { false },
                 progress: ((Double) -> Void)? = nil) -> CGImage? {
        guard EnlargeRule.factors.contains(factor), let model, let g = geometry(model) else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        let out = enlargeTiles(image, scale: factor, model: model, tile: g.tile, margin: g.margin, cancelled: cancelled,
                               progress: progress)
        if out != nil {
            timingMark(String(format: "enlarge: %d×%d ×%d in %.2f s", image.width, image.height, factor, CFAbsoluteTimeGetCurrent() - start))
        }
        return out
    }

    /// The network runs at 4×; for 2× each tile is shrunk by half as it is written (in linear
    /// light), so the 4× picture never exists whole.
    private func enlargeTiles(_ image: CGImage, scale: Int, model: MLModel, tile: Int, margin: Int, cancelled: () -> Bool,
                              progress: ((Double) -> Void)?) -> CGImage? {
        let w = image.width, h = image.height, W = w * scale, H = h * scale
        let space = EnlargeRule.workingSpace(for: image.colorSpace)
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)

        // In: unpremultiplied encoded RGB, 0…1, in the working space.
        guard let src = Self.floatPixels(image, width: w, height: h, space: space) else { return nil }
        var r = [Float](repeating: 0, count: w * h), gr = r, b = r, alpha = r
        for i in 0..<(w * h) {
            let a = max(src[i * 4 + 3], 1e-4)
            alpha[i] = src[i * 4 + 3]
            r[i] = min(max(src[i * 4] / a, 0), 1); gr[i] = min(max(src[i * 4 + 1] / a, 0), 1); b[i] = min(max(src[i * 4 + 2] / a, 0), 1)
        }
        // Transparent pixels take the colour around them: black there would darken every edge.
        if !opaque { EnlargeRule.bleed(&r, &gr, &b, alpha: alpha, width: w, height: h) }

        // Faces, to keep plain: weights at the picture's own size, read bilinearly per output pixel.
        let faces = Self.faces(image)
        let faceWeights = faces.isEmpty ? nil : EnlargeRule.faceWeights(faces: faces, width: w, height: h)
        if !faces.isEmpty { timingMark("enlarge: \(faces.count) face(s) kept plain") }

        // Out: one bitmap, written tile by tile; never the whole picture in floats.
        let deep = image.bitsPerComponent > 8
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let out = CGContext(data: nil, width: W, height: H, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info), let outData = out.data else { return nil }

        let side = tile + 2 * margin, plane = side * side
        guard let input = inputArray(model, side: side) else { return nil }
        let writer = TileWriter(image: image, space: space, opaque: opaque, deep: deep, data: outData, rowBytes: out.bytesPerRow,
                                faceWeights: faceWeights, width: w, height: h, margin: margin, scale: scale)
        let tiles = EnlargeRule.tiles(width: w, height: h, tile: tile, margin: margin)
        // The GPU runs a tile while the CPU writes the one before it out.
        let queue = DispatchQueue(label: "enlarge.write", qos: .userInitiated)
        let pending = DispatchSemaphore(value: 2)
        var tileIn = [Float](repeating: 0, count: plane * 3)
        progress?(0)
        for (n, t) in tiles.enumerated() {
            if cancelled() || writer.failed { queue.sync {}; return nil }
            // The tile and its margin, reflected past the picture's edges.
            let ox = Int(t.source.minX), oy = Int(t.source.minY)
            for ty in 0..<side {
                let sy = Self.reflect(oy + ty, h)
                for tx in 0..<side {
                    let s = sy * w + Self.reflect(ox + tx, w), q = ty * side + tx
                    tileIn[q] = r[s]; tileIn[plane + q] = gr[s]; tileIn[2 * plane + q] = b[s]
                }
            }
            guard let result = predict(model, input, tileIn) else { queue.sync {}; return nil }
            // Copied out now: Core ML may write the next tile's result into the same memory.
            let region = TileRegion(result, keep: t.keep, margin: margin)
            pending.wait()
            queue.async {
                writer.write(t, region)
                pending.signal()
            }
            progress?(Double(n + 1) / Double(tiles.count + 1))
        }
        queue.sync {}
        guard !writer.failed else { return nil }
        progress?(1)
        return out.makeImage()
    }

    /// `i` folded back into 0..<n the way a mirror does (…2 1 0 1 2…), however far past the edge.
    private static func reflect(_ i: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        let period = 2 * (n - 1)
        var k = i % period
        if k < 0 { k += period }
        return k < n ? k : period - k
    }

    static func sample(_ p: [Float], _ w: Int, _ h: Int, _ fx: Float, _ fy: Float) -> Float {
        let x = min(max(fx, 0), Float(w - 1)), y = min(max(fy, 0), Float(h - 1))
        let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = x - Float(x0), ty = y - Float(y0)
        let top = p[y0 * w + x0] * (1 - tx) + p[y0 * w + x1] * tx
        let bottom = p[y1 * w + x0] * (1 - tx) + p[y1 * w + x1] * tx
        return top * (1 - ty) + bottom * ty
    }

    /// The faces Vision finds, in its normalised coordinates (origin bottom-left).
    private static func faces(_ image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }

    /// Premultiplied RGBA floats, top row first, in `space`.
    static func floatPixels(_ image: CGImage, width w: Int, height h: Int, space: CGColorSpace) -> [Float]? {
        var pixels = [Float](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? pixels : nil
    }

    /// One tile through the network: planar RGB in; Core ML's own array out, read in place.
    private func predict(_ model: MLModel, _ input: MLMultiArray, _ tile: [Float]) -> MLMultiArray? {
        let n = tile.count
        if input.dataType == .float16 {
            let p = input.dataPointer.bindMemory(to: Float16.self, capacity: n)
            for i in 0..<n { p[i] = Float16(tile[i]) }
        } else {
            let p = input.dataPointer.bindMemory(to: Float.self, capacity: n)
            tile.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: n) }
        }
        let result = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
        return result?.featureValue(for: "output")?.multiArrayValue
    }
}

/// The part of a network output the writer needs (the kept 4× pixels and `pad` around them),
/// planar RGB, copied out of Core ML's array before the next prediction can reuse it.
private struct TileRegion: Sendable {
    static let pad = 8
    let width: Int, height: Int
    let values: [Float]

    init(_ res: MLMultiArray, keep: CGRect, margin: Int) {
        let st = res.strides.map(\.intValue)  // [1, 3, H, W]
        let half = res.dataType == .float16, origin = margin * 4 - Self.pad
        let w = Int(keep.width) * 4 + 2 * Self.pad, h = Int(keep.height) * 4 + 2 * Self.pad
        var v = [Float](repeating: 0, count: 3 * w * h)
        if half {
            let p = res.dataPointer.bindMemory(to: Float16.self, capacity: st[0])
            for c in 0..<3 { for y in 0..<h { let r = c * st[1] + (origin + y) * st[2] + origin * st[3], d = (c * h + y) * w
                for x in 0..<w { v[d + x] = Float(p[r + x * st[3]]) } } }
        } else {
            let p = res.dataPointer.bindMemory(to: Float.self, capacity: st[0])
            for c in 0..<3 { for y in 0..<h { let r = c * st[1] + (origin + y) * st[2] + origin * st[3], d = (c * h + y) * w
                for x in 0..<w { v[d + x] = p[r + x * st[3]] } } }
        }
        width = w; height = h; values = v
    }

    /// Channel `c` at (`x`, `y`) of the region, `pad` included.
    @inline(__always) func value(_ c: Int, _ y: Int, _ x: Int) -> Float { values[(c * height + y) * width + x] }
}

/// Writes each tile's kept part into the output bitmap: the network's pixels, faded to a Lanczos
/// enlargement inside faces, alpha from the Lanczos enlargement. Tiles write disjoint pixels.
private final class TileWriter: @unchecked Sendable {
    let image: CGImage, space: CGColorSpace, opaque: Bool, deep: Bool
    let data: UnsafeMutableRawPointer, rowBytes: Int
    let faceWeights: [Float]?, width: Int, height: Int, margin: Int
    /// The output's scale: 4, the network's own, or 2.
    let scale: Int
    private(set) var failed = false

    init(image: CGImage, space: CGColorSpace, opaque: Bool, deep: Bool, data: UnsafeMutableRawPointer, rowBytes: Int,
         faceWeights: [Float]?, width: Int, height: Int, margin: Int, scale: Int) {
        self.image = image; self.space = space; self.opaque = opaque; self.deep = deep; self.data = data
        self.rowBytes = rowBytes; self.faceWeights = faceWeights; self.width = width; self.height = height; self.margin = margin
        self.scale = scale
    }

    func write(_ t: EnlargeRule.Tile, _ region: TileRegion) {
        let S = scale
        let kx = Int(t.keep.minX), ky = Int(t.keep.minY), kw = Int(t.keep.width) * S, kh = Int(t.keep.height) * S
        guard let plain = Resampler.render(image, from: t.keep, width: kw, height: kh, kernel: .lanczos, linearLight: false),
              let lz = NeuralUpscaler.floatPixels(plain, width: kw, height: kh, space: space),
              let net = network(t, region, width: kw, height: kh) else { failed = true; return }
        // The network's pixels; a tile that came back broken or far from the plain one is written again, plain.
        var moved: Float = 0, broken = false
        for pass in 0..<2 {
            let useNetwork = pass == 0
            for y in 0..<kh {
                let Y = ky * S + y
                let row = data.advanced(by: Y * rowBytes)
                let fy = (Float(Y) + 0.5) / Float(S) - 0.5
                for x in 0..<kw {
                    let X = kx * S + x, l = (y * kw + x) * 4
                    let a = max(lz[l + 3], 1e-4), alpha = opaque ? 1 : min(max(lz[l + 3], 0), 1)
                    var k: Float = useNetwork ? 1 : 0
                    if useNetwork, let fw = faceWeights {
                        k = NeuralUpscaler.sample(fw, width, height, (Float(X) + 0.5) / Float(S) - 0.5, fy)
                    }
                    for c in 0..<3 {
                        let plainV = min(max(lz[l + c] / a, 0), 1)
                        var v = plainV
                        if useNetwork {
                            let n = net[c * kw * kh + y * kw + x]
                            if !n.isFinite { broken = true; continue }
                            moved += abs(n - plainV)
                            v = plainV + k * (min(max(n, 0), 1) - plainV)
                        }
                        store(row, X * 4 + c, v * alpha)
                    }
                    store(row, X * 4 + 3, alpha)
                }
            }
            if !useNetwork || (!broken && moved / Float(kw * kh * 3) <= 0.08) { break }
            timingMark("enlarge: tile at \(kx),\(ky) kept plain")
        }
    }

    /// The kept part of the network's 4× tile at the output's scale, planar RGB.
    private func network(_ t: EnlargeRule.Tile, _ region: TileRegion, width kw: Int, height kh: Int) -> [Float]? {
        let pad = TileRegion.pad
        func value(_ c: Int, _ y: Int, _ x: Int) -> Float { region.value(c, y, x) }
        let w4 = Int(t.keep.width) * 4, h4 = Int(t.keep.height) * 4
        if scale == 4 {
            var out = [Float](repeating: 0, count: 3 * kw * kh)
            for c in 0..<3 { for y in 0..<kh { for x in 0..<kw { out[(c * kh + y) * kw + x] = value(c, pad + y, pad + x) } } }
            return out
        }
        // 2×: the 4× pixels with a few of the margin's around them (the filter reaches past the
        // edge), as a picture, halved in linear light.
        let pw = w4 + 2 * pad, ph = h4 + 2 * pad
        var rgba = [Float](repeating: 1, count: pw * ph * 4)
        for y in 0..<ph {
            for x in 0..<pw {
                let o = (y * pw + x) * 4
                for c in 0..<3 { rgba[o + c] = min(max(value(c, y, x), 0), 1) }
            }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: rgba.withUnsafeBytes { Data($0) } as CFData),
              let big = CGImage(width: pw, height: ph, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: pw * 16, space: space,
                                bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let small = Resampler.render(big, from: CGRect(x: pad, y: pad, width: w4, height: h4), width: kw, height: kh,
                                           kernel: .lanczos, linearLight: true),
              let px = NeuralUpscaler.floatPixels(small, width: kw, height: kh, space: space) else { return nil }
        var out = [Float](repeating: 0, count: 3 * kw * kh)
        for i in 0..<(kw * kh) { for c in 0..<3 { out[c * kw * kh + i] = px[i * 4 + c] } }
        return out
    }

    @inline(__always) private func store(_ row: UnsafeMutableRawPointer, _ i: Int, _ v: Float) {
        if deep { row.storeBytes(of: UInt16((v * 65535).rounded()), toByteOffset: i * 2, as: UInt16.self) }
        else { row.storeBytes(of: UInt8((v * 255).rounded()), toByteOffset: i, as: UInt8.self) }
    }
}
