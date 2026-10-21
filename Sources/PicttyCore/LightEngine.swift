import CoreGraphics
import Foundation
import Metal
import simd

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
        /// The picture's noise, a standard deviation in encoded luminance (0…1), and the blur of
        /// its edges, a Gaussian sigma in pixels: measured once, at upload.
        public let noise: Float
        public let blur: Float
        /// The picture's middle brightness: the median of its encoded luminance, 0…1.
        public let key: Float
        /// How colourful the picture is: the median Oklab chroma of its pixels.
        public let chroma: Float
        /// The light of its haze, linear, on a 0…1 scale of `white`.
        public let airlight: SIMD3<Float>
        /// The same picture through the denoiser, once it has been.
        fileprivate(set) var denoised: MTLTexture?
        fileprivate var scratch: [String: MTLTexture] = [:]

        public var hasDenoised: Bool { denoised != nil }

        init(width: Int, height: Int, white: Float, isHDR: Bool, input: MTLTexture, noise: Float, blur: Float, key: Float,
             chroma: Float, airlight: SIMD3<Float>) {
            self.width = width; self.height = height; self.white = white; self.isHDR = isHDR; self.input = input
            self.noise = noise; self.blur = blur; self.key = key; self.chroma = chroma
            self.airlight = airlight
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
                     "boxVertical", "guidedCoefficients", "detailBand", "localExposure", "colourMoments", "colourCoefficients", "hazeDark",
                     "minHorizontal", "minVertical", "hazeMoments", "hazeCoefficients", "dehaze", "finish"] {
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
        guard let texture = upload(data, rowBytes: ctx.bytesPerRow, w, h) else { return nil }
        let hdr = headroom > 1.001
        let measured = PictureMeasure.noiseAndBlur(data.assumingMemoryBound(to: Float16.self), width: w, height: h,
                                                   rowFloats: ctx.bytesPerRow / 2)
        let medians = PictureMeasure.medians(data.assumingMemoryBound(to: Float16.self), width: w, height: h,
                                             rowFloats: ctx.bytesPerRow / 2, white: hdr ? headroom : 1)
        return Source(width: w, height: h, white: hdr ? headroom : 1, isHDR: hdr, input: texture,
                      noise: measured.noise, blur: measured.blur, key: medians.luma, chroma: medians.chroma,
                      airlight: PictureMeasure.airlight(data.assumingMemoryBound(to: Float16.self), width: w, height: h,
                                                        rowFloats: ctx.bytesPerRow / 2, white: hdr ? headroom : 1))
    }

    /// Gives `src` its denoised counterpart, the same size, colour-managed the same way.
    public func setDenoised(_ image: CGImage, on src: Source) {
        guard image.width == src.width, image.height == src.height,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
        guard let ctx = CGContext(data: nil, width: src.width, height: src.height, bitsPerComponent: 16,
                                  bytesPerRow: src.width * 8, space: space, bitmapInfo: info) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        guard let data = ctx.data else { return }
        src.denoised = upload(data, rowBytes: ctx.bytesPerRow, src.width, src.height)
    }

    private func upload(_ data: UnsafeMutableRawPointer, rowBytes: Int, _ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: rowBytes)
        return texture
    }

    // MARK: - Render

    /// Must match `Params` in the kernels, field for field.
    private struct Params {
        var exposure: Float = 0, contrast: Float = 0, brightness: Float = 0, highlights: Float = 0, shadows: Float = 0
        var highlightsAlgorithm: Int32 = 2, shadowsAlgorithm: Int32 = 1
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
        var wb: (Float, Float, Float, Float, Float, Float, Float, Float, Float) = (1, 0, 0, 0, 1, 0, 0, 0, 1)
        var whiteBalance: Int32 = 0
        var grade: (Float, Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0, 0)
        var balance: Float = 0
        var gradeOn: Int32 = 0
        var detailS: Float = 0, detailT: Float = 0, detailC: Float = 0
        var noise: Float = 0.004
        var level: Int32 = 0
        var edgeLow: Float = 0.1, edgeHigh: Float = 0.32
        var denoise: Float = 0
        var hasDenoised: Int32 = 0
        var vibrance: Float = 0, saturation: Float = 0
        var key: Float = 0.46
        var saturationAlgorithm: Int32 = 2
        var vibranceScale: Float = 1
        var dehaze: Float = 0
        var airlight: (Float, Float, Float) = (1, 1, 1)
    }

    /// Samples of the Laplacian remap across the brightness range.
    /// 24: with 12, the steps between samples showed as rings and speckle beside small, very
    /// bright things (a street lamp at night) when highlights were pulled down hard.
    static let laplacianSamples = 24

    public struct Result: @unchecked Sendable {
        public let image: CGImage
        public let milliseconds: Double
    }

    public func render(_ src: Source, _ a: Adjustments, output: Output) -> Result? {
        let start = CFAbsoluteTimeGetCurrent()
        let w = src.width, h = src.height
        var p = Params()
        p.exposure = Float(a.exposure); p.contrast = Float(a.contrast); p.brightness = Float(a.brightness)
        p.highlights = Float(a.highlights); p.shadows = Float(a.shadows)
        p.key = Self.key(src, exposure: Float(a.exposure))
        p.saturationAlgorithm = Int32(a.saturationAlgorithm)
        p.dehaze = Float(a.dehaze)
        if a.dehaze != 0 {
            // The haze's light as the picture now has it: white-balanced, and lowered with exposure.
            let m = ColourMath.whiteBalance(temperature: a.temperature, tint: a.tint)
            let lit = m * SIMD3<Double>(src.airlight) * pow(2, min(a.exposure, 0))
            let airlight = simd_clamp(SIMD3<Float>(lit), SIMD3(repeating: 0.02), SIMD3(repeating: 1))
            p.airlight = (airlight.x, airlight.y, airlight.z)
        }
        // A dull picture is given more vibrance, a vivid one less: about 0.08 of Oklab chroma is typical.
        p.vibranceScale = min(max((0.08 / max(src.chroma, 0.02)).squareRoot(), 0.75), 1.3)
        p.highlightsAlgorithm = Int32(a.highlightsAlgorithm); p.shadowsAlgorithm = Int32(a.shadowsAlgorithm)
        p.vibrance = Float(a.vibrance); p.saturation = Float(a.saturation)
        if !a.isWhiteBalanceNeutral {
            // By rows; simd's own storage is by columns.
            let m = ColourMath.whiteBalance(temperature: a.temperature, tint: a.tint).transpose
            let c = (0..<3).flatMap { i in (0..<3).map { Float(m[i][$0]) } }
            p.wb = (c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8])
            p.whiteBalance = 1
        }
        if !a.isGradingNeutral {
            let g = [a.shadowColour, a.midtoneColour, a.highlightColour].flatMap { s in
                let v = ColourMath.gradeVector(s)
                return [Float(v.x), Float(v.y), Float(v.z)]
            }
            p.grade = (g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], g[8])
            p.balance = Float(a.balance)
            p.gradeOn = 1
        }
        p.white = src.white
        p.clampWhite = src.isHDR ? 0 : 1
        p.outputEncoding = output == .display ? 1 : 0
        p.lumaWhite = Self.encode(src.white)

        func uses(_ algorithm: Int) -> Bool {
            (a.highlights != 0 && a.highlightsAlgorithm == algorithm) || (a.shadows != 0 && a.shadowsAlgorithm == algorithm)
        }
        let guided = uses(2), laplacian = uses(3)
        let detail = a.texture != 0 || a.clarity != 0 || a.sharpening != 0
        p.localPaths = (guided ? 1 : 0) | (laplacian ? 2 : 0) | (detail ? 4 : 0)
        p.noise = src.noise
        if a.denoise > 0, src.denoised != nil {
            p.denoise = Float(a.denoise)
            p.hasDenoised = 1
        }

        guard let cb = queue.makeCommandBuffer() else { return nil }
        let outFormat: MTLPixelFormat = output == .display ? .rgba8Unorm : .rgba16Float
        let out = scratch(src, output == .display ? "out8" : "outF", outFormat, w, h, shared: true)
        guard var lit = scratch(src, "lit", .rgba16Float, w, h), var luma = scratch(src, "luma", .r32Float, w, h),
              let out else { return nil }

        dispatch(cb, "prepare", [src.input, lit, luma, src.denoised ?? src.input], &p, w, h)

        // Dehaze, before exposure and the rest: a dark channel per quarter-size cell, eroded, made
        // to follow the picture's edges by a guided filter on its brightness, and the haze it shows
        // taken out of the light (or added to it).
        if a.dehaze != 0 {
            let w4 = (w + 3) / 4, h4 = (h + 3) / 4
            guard let dk = scratch(src, "hd", .rg32Float, w4, h4), let dt = scratch(src, "hdt", .rg32Float, w4, h4),
                  let m = scratch(src, "hm", .rgba32Float, w4, h4), let t = scratch(src, "hmt", .rgba32Float, w4, h4),
                  let ab = scratch(src, "hab", .rgba32Float, w4, h4),
                  let litD = scratch(src, "litD", .rgba16Float, w, h), let lumaD = scratch(src, "lumaD", .r32Float, w, h)
            else { return nil }
            dispatch(cb, "hazeDark", [lit, luma, dk], &p, w4, h4)
            // The erosion: about 1.5 % of the picture's longer side.
            p.radius = Int32(max(2, Double(max(w4, h4)) * 0.015))
            dispatch(cb, "minHorizontal", [dk, dt], &p, w4, h4)
            dispatch(cb, "minVertical", [dt, dk], &p, w4, h4)
            dispatch(cb, "hazeMoments", [dk, m], &p, w4, h4)
            p.radius = Int32(max(2, Double(max(w4, h4)) * 0.03))
            p.eps = 0.001
            dispatch(cb, "boxHorizontal", [m, t], &p, w4, h4)
            dispatch(cb, "boxVertical", [t, m], &p, w4, h4)
            dispatch(cb, "hazeCoefficients", [m, ab], &p, w4, h4)
            dispatch(cb, "boxHorizontal", [ab, t], &p, w4, h4)
            dispatch(cb, "boxVertical", [t, ab], &p, w4, h4)
            dispatch(cb, "dehaze", [lit, luma, ab, litD, lumaD], &p, w, h)
            lit = litD
            luma = lumaD
        }

        // Local exposure: the gain goes onto a smooth, edge-aware map of the picture's brightness,
        // full in the dark regions and less where the light already is; each pixel's detail rides
        // on its region. Everything after works on the result, as after any exposure.
        if a.exposure > 0 {
            guard let regions = self.guided(cb, src, luma, key: "e", radius: 0.04, eps: 0.01, &p),
                  let litE = scratch(src, "litE", .rgba16Float, w, h),
                  let lumaE = scratch(src, "lumaE", .r32Float, w, h) else { return nil }
            dispatch(cb, "localExposure", [lit, luma, regions, litE, lumaE], &p, w, h)
            lit = litE
            luma = lumaE
        }

        // The Gaussian pyramid of the luminance, for the local Laplacian and for detail.
        var sizes = [(w, h)]
        while let last = sizes.last, min(last.0, last.1) > 12, sizes.count < 11 {
            sizes.append(((last.0 + 1) / 2, (last.1 + 1) / 2))
        }
        let n = sizes.count - 1
        var gauss: [MTLTexture] = [luma]
        if laplacian || detail {
            for l in stride(from: 1, through: n, by: 1) {
                guard let t = scratch(src, "G\(l)", .r32Float, sizes[l].0, sizes[l].1) else { return nil }
                gauss.append(t)
                dispatch(cb, "downsample", [gauss[l - 1], gauss[l]], &p, sizes[l].0, sizes[l].1)
            }
        }

        // Guided base: on a quarter-size luminance, its coefficients smoothed and sampled back up.
        var coefficients: MTLTexture?
        if guided {
            guard let ab = self.guided(cb, src, luma, key: "g", radius: 0.025, eps: 0.012, &p) else { return nil }
            coefficients = ab
        }

        // Fast local Laplacian (Aubry et al.): the output pyramid built from a dozen remapped
        // copies of the luminance, each contributing where the input's own level is close to it.
        var rebuilt: MTLTexture?
        if laplacian {
            var remapped: [MTLTexture] = [], outs: [MTLTexture] = []
            for (l, s) in sizes.enumerated() {
                guard let r = scratch(src, "R\(l)", .r32Float, s.0, s.1),
                      let o = scratch(src, "O\(l)", .r32Float, s.0, s.1) else { return nil }
                remapped.append(r); outs.append(o)
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
            p.top = 0
        }

        // Detail: the bands of the luminance pyramid, boosted where they are detail and not noise
        // or edges, put back together twice: the fine bands (sharpening and texture), which the
        // finish keeps within each pixel's neighbourhood, and the coarse ones (clarity).
        var fine: MTLTexture?, coarse: MTLTexture?
        if detail {
            let weights = Self.detailWeights(blur: src.blur, levels: n)
            var fineLevels: [MTLTexture] = [], coarseLevels: [MTLTexture] = []
            for (l, s) in sizes.enumerated() {
                guard let f = scratch(src, "DF\(l)", .r32Float, s.0, s.1),
                      let c = scratch(src, "DC\(l)", .r32Float, s.0, s.1) else { return nil }
                fineLevels.append(f); coarseLevels.append(c)
            }
            let fineTop = min(3, n)
            for l in 0...n {
                p.level = Int32(l)
                let coarser = l < n ? gauss[l + 1] : gauss[l]
                if l <= fineTop {
                    p.top = l == fineTop ? 1 : 0
                    p.detailS = Float(a.sharpening) * 1.6 * weights.sharpen[l]
                    // Texture at three quarters of its first strength: finer steps along the slider.
                    p.detailT = Float(a.texture) * 0.825 * weights.texture[l]
                    p.detailC = 0
                    p.edgeLow = 0.10; p.edgeHigh = 0.32
                    dispatch(cb, "detailBand", [gauss[l], coarser, fineLevels[l]], &p, sizes[l].0, sizes[l].1)
                }
                p.top = l == n ? 1 : 0
                p.detailS = 0; p.detailT = 0
                // Clarity at 85 % of its first strength: finer steps along the slider.
                p.detailC = Float(a.clarity) * 0.6375 * weights.clarity[l]
                p.edgeLow = 0.14; p.edgeHigh = 0.45
                dispatch(cb, "detailBand", [gauss[l], coarser, coarseLevels[l]], &p, sizes[l].0, sizes[l].1)
            }
            p.top = 0
            for l in stride(from: fineTop - 1, through: 0, by: -1) {
                dispatch(cb, "collapse", [fineLevels[l], fineLevels[l + 1]], &p, sizes[l].0, sizes[l].1)
            }
            for l in stride(from: n - 1, through: 0, by: -1) {
                dispatch(cb, "collapse", [coarseLevels[l], coarseLevels[l + 1]], &p, sizes[l].0, sizes[l].1)
            }
            fine = fineLevels[0]
            coarse = coarseLevels[0]
        }

        // Brightness works by regions, on the same kind of base as local exposure.
        var regions: MTLTexture?
        if a.brightness != 0 {
            guard let r = self.guided(cb, src, luma, key: "c", radius: 0.04, eps: 0.01, &p) else { return nil }
            regions = r
        }

        // Vibrance and saturation by regions: each region's colour, edge-aware, on a quarter-size grid.
        var colourRegions: MTLTexture?
        if !a.isSaturationNeutral, a.saturationAlgorithm == 2 {
            let w4 = (w + 3) / 4, h4 = (h + 3) / 4
            guard let m = scratch(src, "km", .rgba32Float, w4, h4), let t = scratch(src, "kt", .rgba32Float, w4, h4),
                  let ab = scratch(src, "kab", .rgba32Float, w4, h4) else { return nil }
            dispatch(cb, "colourMoments", [lit, m], &p, w4, h4)
            p.radius = Int32(max(2, Double(max(w4, h4)) * 0.03))
            // Colour edges of about 0.03 in Oklab chroma and up hold; less than that is smoothed.
            p.eps = 0.0009
            dispatch(cb, "boxHorizontal", [m, t], &p, w4, h4)
            dispatch(cb, "boxVertical", [t, m], &p, w4, h4)
            dispatch(cb, "colourCoefficients", [m, ab], &p, w4, h4)
            dispatch(cb, "boxHorizontal", [ab, t], &p, w4, h4)
            dispatch(cb, "boxVertical", [t, ab], &p, w4, h4)
            colourRegions = ab
        }

        dispatch(cb, "finish", [lit, luma, coefficients ?? lit, rebuilt ?? luma, out, fine ?? luma, coarse ?? luma,
                                regions ?? lit, colourRegions ?? lit], &p, w, h)
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed, let image = Self.image(from: out, output: output, headroom: src.isHDR ? src.white : 1)
        else { return nil }
        return Result(image: image, milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// The picture's middle brightness after `exposure` (encoded, 0…1), for brightness to work
    /// around: the median as measured, moved as local exposure moves a region that bright.
    static func key(_ src: Source, exposure: Float) -> Float {
        var y = Self.decode(src.key) * src.white
        if exposure < 0 {
            y *= exp2(exposure)
        } else if exposure > 0 {
            let base = max(y / src.white, 1e-5)
            let lit = min(max(log(base / 0.03) / log(0.5 / 0.03), 0), 1)
            y *= exp2(exposure * (1 - lit))
        }
        return min(max(encode(min(y / src.white, 1)), 0.2), 0.65)
    }

    /// How much each level of the pyramid carries of each slider. Sharpening sits where the
    /// picture's own blur is: a crisp picture's softness is in the finest level, a softer one's
    /// spreads to the next. Texture is the middle levels, clarity the coarse ones.
    static func detailWeights(blur: Float, levels n: Int) -> (sharpen: [Float], texture: [Float], clarity: [Float]) {
        var sharpen: [Float]
        switch blur {
        case ..<0.8: sharpen = [1.0, 0.25, 0]
        case ..<1.6: sharpen = [0.7, 0.8, 0.2]
        default: sharpen = [0.4, 0.9, 0.6]
        }
        let texture: [Float] = [0.25, 0.75, 1.0]
        let clarity: [Float] = [0, 0, 0, 0.8, 1.0, 1.0, 0.75, 0.45, 0.25, 0.1, 0]
        func padded(_ a: [Float]) -> [Float] { (0...max(n, 3)).map { $0 < a.count ? a[$0] : 0 } }
        return (padded(sharpen), padded(texture), padded(clarity))
    }

    // MARK: - Plumbing

    /// The guided filter's coefficients (a, b) for `luma`, worked out on a quarter-size copy:
    /// `radius` as a fraction of that copy's longer side, `eps` the regularisation. `key` keeps
    /// each user's textures apart.
    private func guided(_ cb: MTLCommandBuffer, _ src: Source, _ luma: MTLTexture, key: String, radius: Double,
                        eps: Float, _ p: inout Params) -> MTLTexture? {
        let w2 = (src.width + 1) / 2, h2 = (src.height + 1) / 2, w4 = (w2 + 1) / 2, h4 = (h2 + 1) / 2
        guard let half = scratch(src, key + "1", .r32Float, w2, h2), let quarter = scratch(src, key + "2", .r32Float, w4, h4),
              let m = scratch(src, key + "m", .rgba32Float, w4, h4), let t = scratch(src, key + "t", .rgba32Float, w4, h4),
              let ab = scratch(src, key + "ab", .rgba32Float, w4, h4) else { return nil }
        dispatch(cb, "downsample", [luma, half], &p, w2, h2)
        dispatch(cb, "downsample", [half, quarter], &p, w4, h4)
        dispatch(cb, "guidedMoments", [quarter, m], &p, w4, h4)
        p.radius = Int32(max(2, Double(max(w4, h4)) * radius))
        p.eps = eps
        dispatch(cb, "boxHorizontal", [m, t], &p, w4, h4)
        dispatch(cb, "boxVertical", [t, m], &p, w4, h4)
        dispatch(cb, "guidedCoefficients", [m, ab], &p, w4, h4)
        dispatch(cb, "boxHorizontal", [ab, t], &p, w4, h4)
        dispatch(cb, "boxVertical", [t, ab], &p, w4, h4)
        return ab
    }

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

    static func decode(_ e: Float) -> Float {
        e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4)
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
