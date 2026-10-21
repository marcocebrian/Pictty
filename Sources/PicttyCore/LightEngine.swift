import CoreGraphics
import Foundation
import Metal

/// Pictty's own Light engine for everything that is not a camera RAW: JPEG, HEIC, PNG, TIFF,
/// AVIF, WebP and the rest. A picture is uploaded once as linear half-float light; every change
/// of a slider then runs a handful of GPU passes over it and reads the result back as a CGImage
/// the canvas shows like any other decode.
///
/// One engine per caller, used from one queue at a time. Sources keep their working textures,
/// so a slider drag allocates nothing after its first frame.
public final class LightEngine: @unchecked Sendable {
    public enum Output: Sendable {
        /// 8-bit Display P3, dithered, clamped to SDR white: what the canvas shows for an SDR picture.
        case display
        /// Half-float linear extended sRGB: HDR on screen, and every export.
        case linear
    }

    /// A picture uploaded for editing.
    public final class Source: @unchecked Sendable {
        public let width: Int, height: Int
        /// Linear white: 1 for SDR, the content headroom of an HDR picture.
        public let white: Float
        public let isHDR: Bool
        let input: MTLTexture
        fileprivate var scratch: [String: MTLTexture] = [:]

        init(width: Int, height: Int, white: Float, isHDR: Bool, input: MTLTexture) {
            self.width = width; self.height = height; self.white = white; self.isHDR = isHDR; self.input = input
        }
    }

    public static let shared: LightEngine? = LightEngine()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [String: MTLComputePipelineState] = [:]

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: LightKernels.source, options: nil) else { return nil }
        self.device = device
        self.queue = queue
        for name in ["prepare", "downsample", "remap", "accumulate", "collapse", "guidedMoments", "boxHorizontal",
                     "boxVertical", "guidedCoefficients", "finish"] {
            guard let f = library.makeFunction(name: name),
                  let state = try? device.makeComputePipelineState(function: f) else { return nil }
            pipelines[name] = state
        }
    }

    /// The largest side a source may have.
    public var maxSide: Int { 16384 }

    // MARK: - Upload

    /// Uploads `image`, colour-managed into linear extended sRGB. `headroom` is the picture's
    /// content headroom when it is HDR (1 otherwise).
    public func source(_ image: CGImage, headroom: Float = 1) -> Source? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= maxSide, h <= maxSide,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let rowBytes = w * 8
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: rowBytes,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        let hdr = headroom > 1.001
        return Source(width: w, height: h, white: hdr ? headroom : 1, isHDR: hdr, input: texture)
    }

    // MARK: - Render

    /// Must match `Params` in the kernels, field for field.
    private struct Params {
        var exposure: Float = 0, contrast: Float = 0, brightness: Float = 0, highlights: Float = 0, shadows: Float = 0
        var exposureAlgorithm: Int32 = 1, contrastAlgorithm: Int32 = 1, brightnessAlgorithm: Int32 = 1
        var highlightsAlgorithm: Int32 = 1, shadowsAlgorithm: Int32 = 1
        var white: Float = 1
        var clampWhite: Int32 = 1
        var outputEncoding: Int32 = 0
        var localPaths: Int32 = 0
        var laplacianMask: Int32 = 0
        var gamma: Float = 0
        var gammaStep: Float = 0.1
        var sigma: Float = 0.12
        var first: Int32 = 0
        var top: Int32 = 0
        var lumaWhite: Float = 1
        var eps: Float = 0.01
        var radius: Int32 = 8
    }

    /// Samples of the Laplacian remap across the brightness range.
    static let laplacianSamples = 12

    public struct Result: @unchecked Sendable {
        public let image: CGImage
        public let milliseconds: Double
    }

    public func render(_ src: Source, _ a: LightAdjustments, output: Output) -> Result? {
        let start = CFAbsoluteTimeGetCurrent()
        let w = src.width, h = src.height
        var p = Params()
        p.exposure = Float(a.exposure); p.contrast = Float(a.contrast); p.brightness = Float(a.brightness)
        p.highlights = Float(a.highlights); p.shadows = Float(a.shadows)
        p.exposureAlgorithm = Int32(a.exposureAlgorithm); p.contrastAlgorithm = Int32(a.contrastAlgorithm)
        p.brightnessAlgorithm = Int32(a.brightnessAlgorithm)
        p.highlightsAlgorithm = Int32(a.highlightsAlgorithm); p.shadowsAlgorithm = Int32(a.shadowsAlgorithm)
        p.white = src.white
        p.clampWhite = src.isHDR ? 0 : 1
        p.outputEncoding = output == .display ? 1 : 0
        p.lumaWhite = Self.encode(src.white)

        func uses(_ algorithm: Int) -> Bool {
            (a.highlights != 0 && a.highlightsAlgorithm == algorithm) || (a.shadows != 0 && a.shadowsAlgorithm == algorithm)
        }
        let guided = uses(2), laplacian = uses(3)
        p.localPaths = (guided ? 1 : 0) | (laplacian ? 2 : 0)

        guard let cb = queue.makeCommandBuffer() else { return nil }
        let lit = scratch(src, "lit", .rgba16Float, w, h)
        let luma = scratch(src, "luma", .r32Float, w, h)
        let outFormat: MTLPixelFormat = output == .display ? .rgba8Unorm : .rgba16Float
        let out = scratch(src, output == .display ? "out8" : "outF", outFormat, w, h, shared: true)
        guard let lit, let luma, let out else { return nil }

        dispatch(cb, "prepare", [src.input, lit, luma], &p, w, h)

        // Guided base: on a quarter-size luminance, its coefficients smoothed and sampled back up.
        var coefficients: MTLTexture?
        if guided {
            let w2 = (w + 1) / 2, h2 = (h + 1) / 2, w4 = (w2 + 1) / 2, h4 = (h2 + 1) / 2
            guard let half = scratch(src, "g1", .r32Float, w2, h2), let quarter = scratch(src, "g2", .r32Float, w4, h4),
                  let m = scratch(src, "gm", .rgba32Float, w4, h4), let t = scratch(src, "gt", .rgba32Float, w4, h4),
                  let ab = scratch(src, "gab", .rgba32Float, w4, h4) else { return nil }
            dispatch(cb, "downsample", [luma, half], &p, w2, h2)
            dispatch(cb, "downsample", [half, quarter], &p, w4, h4)
            dispatch(cb, "guidedMoments", [quarter, m], &p, w4, h4)
            p.radius = Int32(max(2, Double(max(w4, h4)) * 0.025))
            p.eps = 0.012
            dispatch(cb, "boxHorizontal", [m, t], &p, w4, h4)
            dispatch(cb, "boxVertical", [t, m], &p, w4, h4)
            dispatch(cb, "guidedCoefficients", [m, ab], &p, w4, h4)
            dispatch(cb, "boxHorizontal", [ab, t], &p, w4, h4)
            dispatch(cb, "boxVertical", [t, ab], &p, w4, h4)
            coefficients = ab
        }

        // Fast local Laplacian (Aubry et al.): the output pyramid built from a dozen remapped
        // copies of the luminance, each contributing where the input's own level is close to it.
        var rebuilt: MTLTexture?
        if laplacian {
            var sizes = [(w, h)]
            while let last = sizes.last, min(last.0, last.1) > 12, sizes.count < 11 {
                sizes.append(((last.0 + 1) / 2, (last.1 + 1) / 2))
            }
            let n = sizes.count - 1
            var gauss: [MTLTexture] = [luma], remapped: [MTLTexture] = [], outs: [MTLTexture] = []
            for (l, s) in sizes.enumerated() {
                if l > 0 { guard let t = scratch(src, "G\(l)", .r32Float, s.0, s.1) else { return nil }; gauss.append(t) }
                guard let r = scratch(src, "R\(l)", .r32Float, s.0, s.1),
                      let o = scratch(src, "O\(l)", .r32Float, s.0, s.1) else { return nil }
                remapped.append(r); outs.append(o)
            }
            for l in stride(from: 1, through: n, by: 1) {
                dispatch(cb, "downsample", [gauss[l - 1], gauss[l]], &p, sizes[l].0, sizes[l].1)
            }
            let k = Self.laplacianSamples
            p.gammaStep = p.lumaWhite / Float(k - 1)
            p.sigma = 0.12 * p.lumaWhite
            for i in 0..<k {
                p.gamma = Float(i) * p.gammaStep
                p.first = i == 0 ? 1 : 0
                dispatch(cb, "remap", [luma, remapped[0]], &p, w, h)
                for l in stride(from: 1, through: n, by: 1) {
                    dispatch(cb, "downsample", [remapped[l - 1], remapped[l]], &p, sizes[l].0, sizes[l].1)
                }
                for l in 0...n {
                    p.top = l == n ? 1 : 0
                    let coarser = l < n ? remapped[l + 1] : remapped[l]
                    dispatch(cb, "accumulate", [remapped[l], coarser, gauss[l], outs[l]], &p, sizes[l].0, sizes[l].1)
                }
            }
            for l in stride(from: n - 1, through: 0, by: -1) {
                dispatch(cb, "collapse", [outs[l], outs[l + 1]], &p, sizes[l].0, sizes[l].1)
            }
            rebuilt = outs[0]
        }

        dispatch(cb, "finish", [lit, luma, coefficients ?? lit, rebuilt ?? luma, out], &p, w, h)
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed, let image = Self.image(from: out, output: output, headroom: src.isHDR ? src.white : 1)
        else { return nil }
        return Result(image: image, milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    // MARK: - Plumbing

    private func scratch(_ src: Source, _ key: String, _ format: MTLPixelFormat, _ w: Int, _ h: Int,
                         shared: Bool = false) -> MTLTexture? {
        if let t = src.scratch[key], t.width == w, t.height == h, t.pixelFormat == format { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = shared ? .shared : .private
        let t = device.makeTexture(descriptor: d)
        src.scratch[key] = t
        return t
    }

    private func dispatch(_ cb: MTLCommandBuffer, _ name: String, _ textures: [MTLTexture], _ p: inout Params,
                          _ w: Int, _ h: Int) {
        guard let state = pipelines[name], let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(state)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        let tw = state.threadExecutionWidth, th = max(1, state.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
    }

    static func encode(_ y: Float) -> Float {
        y <= 0.0031308 ? y * 12.92 : 1.055 * pow(y, 1 / 2.4) - 0.055
    }

    private static func image(from t: MTLTexture, output: Output, headroom: Float) -> CGImage? {
        let w = t.width, h = t.height
        let bpp = output == .display ? 4 : 8
        let rowBytes = w * bpp
        var data = Data(count: rowBytes * h)
        data.withUnsafeMutableBytes { raw in
            t.getBytes(raw.baseAddress!, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        if output == .display {
            guard let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
        guard let image = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: rowBytes,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        if headroom > 1, let tagged = CGImageCreateCopyWithContentHeadroom(headroom, image) { return tagged }
        return image
    }
}
