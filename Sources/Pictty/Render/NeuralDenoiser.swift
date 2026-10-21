import CoreGraphics
import CoreML
import Foundation

/// Noise reduction by NAFNet (Chen et al. 2022, MIT licence), a convolutional network trained on
/// real smartphone noise (SIDD), run by Core ML on the GPU in 512-pixel tiles.
///
/// The tiles overlap by 64 pixels and are blended across the overlap: the network averages over
/// each tile as a whole (its channel attention), so cut-and-paste tiles could show their seams.
/// About 1.3 s for 12 megapixels on an M5 Pro. The picture stays in its own colour space,
/// sRGB-encoded as the network was trained; HDR pictures are not offered it.
final class NeuralDenoiser: @unchecked Sendable {
    static let shared = NeuralDenoiser()

    private static let tile = 512, overlap = 64
    private let lock = NSLock()
    private var loaded: MLModel?

    /// The compiled network in the app, if this build has it.
    private let url: URL? = Bundle.main.url(forResource: "Denoise", withExtension: "mlmodelc")

    var isAvailable: Bool { url != nil }

    private var warm = false

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

    /// `image` denoised, the same size and colour space; nil if it cannot be (or `cancelled` says so).
    func denoise(_ image: CGImage, cancelled: () -> Bool = { false }) -> CGImage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let model else { return nil }
        timingMark(String(format: "  denoise: model ready %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        var predictTime = 0.0, fillTime = 0.0
        let w = image.width, h = image.height
        let own = image.colorSpace.flatMap { $0.model == .rgb && !CGColorSpaceUsesExtendedRange($0) ? $0 : nil }
        guard let space = own ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // In: encoded RGB as floats, 0…1.
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

        let t = Self.tile, o = Self.overlap, stride = t - 2 * o
        var sum = [Float](repeating: 0, count: w * h * 3)
        var weight = [Float](repeating: 0, count: w * h)
        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: t), NSNumber(value: t)], dataType: .float16) else { return nil }
        let plane = t * t
        // Tile origins, the last one flush with the far edge.
        func origins(_ size: Int) -> [Int] {
            guard size > t else { return [0] }
            var out = Array(Swift.stride(from: 0, to: size - t, by: stride))
            out.append(size - t)
            return out
        }
        // A weight that rises across the overlap, so neighbouring tiles fade into each other.
        let ramp: [Float] = (0..<t).map { i in
            let d = Float(min(i, t - 1 - i))
            return min(1, (d + 1) / Float(o))
        }
        for y0 in origins(h) {
            for x0 in origins(w) {
                if cancelled() { return nil }
                // Fill the tile; past the picture's edges (small pictures), mirror it.
                let inPtr = input.dataPointer.bindMemory(to: Float16.self, capacity: plane * 3)
                for ty in 0..<t {
                    var sy = y0 + ty
                    if sy >= h { sy = max(0, 2 * h - 2 - sy) }
                    for tx in 0..<t {
                        var sx = x0 + tx
                        if sx >= w { sx = max(0, 2 * w - 2 - sx) }
                        let p = (sy * w + sx) * 4
                        let a = max(pixels[p + 3], 1e-4)
                        let q = ty * t + tx
                        inPtr[q] = Float16(pixels[p] / a)
                        inPtr[plane + q] = Float16(pixels[p + 1] / a)
                        inPtr[2 * plane + q] = Float16(pixels[p + 2] / a)
                    }
                }
                let tp = CFAbsoluteTimeGetCurrent()
                guard let result = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input])),
                      let out = result.featureValue(for: "output")?.multiArrayValue else { return nil }
                predictTime += CFAbsoluteTimeGetCurrent() - tp
                let tb = CFAbsoluteTimeGetCurrent()
                defer { fillTime += CFAbsoluteTimeGetCurrent() - tb }
                let outPtr = out.dataPointer.bindMemory(to: Float16.self, capacity: plane * 3)
                for ty in 0..<t where y0 + ty < h {
                    // Tiles at the picture's edge do not fade out towards it.
                    let wy = (y0 == 0 && ty < o) || (y0 + t >= h && ty >= t - o) ? 1 : ramp[ty]
                    for tx in 0..<t where x0 + tx < w {
                        let wx = (x0 == 0 && tx < o) || (x0 + t >= w && tx >= t - o) ? 1 : ramp[tx]
                        let wgt = wx * wy
                        let q = ty * t + tx, d = (y0 + ty) * w + x0 + tx
                        sum[d * 3] += Float(outPtr[q]) * wgt
                        sum[d * 3 + 1] += Float(outPtr[plane + q]) * wgt
                        sum[d * 3 + 2] += Float(outPtr[2 * plane + q]) * wgt
                        weight[d] += wgt
                    }
                }
            }
        }
        timingMark(String(format: "  denoise: predictions %.0f ms, blending %.0f ms, total so far %.0f ms", predictTime * 1000, fillTime * 1000, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        // Out: the blended result, alpha as it was, premultiplied again.
        for i in 0..<(w * h) {
            let k = 1 / max(weight[i], 1e-6), a = pixels[i * 4 + 3]
            pixels[i * 4] = min(max(sum[i * 3] * k, 0), 1) * a
            pixels[i * 4 + 1] = min(max(sum[i * 3 + 1] * k, 0), 1) * a
            pixels[i * 4 + 2] = min(max(sum[i * 3 + 2] * k, 0), 1) * a
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
