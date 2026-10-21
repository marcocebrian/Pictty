import CoreImage
import Foundation
import PicttyCore

/// Runs the Light panel's renders off the main thread, the newest request first: a slider drag
/// asks many times a second, and only the last value still matters when the GPU comes free.
///
/// Pictures go through Pictty's own engine. Camera RAWs go through Apple's RAW engine for now
/// (exposure in the develop itself, then Core Image's own tone filters).
final class LightRenderer: @unchecked Sendable {
    enum Engine: Equatable {
        case pictty
        case appleRAW
    }

    struct Rendered {
        let image: CGImage
        let milliseconds: Double
        let adjustments: Adjustments
    }

    let url: URL
    let engine: Engine
    let isHDR: Bool
    private let queue = DispatchQueue(label: "pictty.light", qos: .userInteractive)
    private let lock = NSLock()
    private var latest = 0
    private var latestFull = 0

    // Queue-only state.
    private var source: LightEngine.Source?
    private var raw: AppleRAW?

    /// The screen-sized picture, kept for the denoiser.
    private let preview: CGImage
    /// The network runs on a queue of its own, so the sliders stay live while it works.
    private let denoiseQueue = DispatchQueue(label: "pictty.denoise", qos: .userInitiated)
    private var denoising = false
    /// Called on the main thread when the screen-sized picture has been denoised: render again.
    var onDenoised: (@MainActor () -> Void)?
    /// How far the network is, 0…1, on the main thread, for the canvas to say so.
    var onDenoiseProgress: (@MainActor (Double, _ full: Bool) -> Void)?

    /// What the network made of this picture, by width, so no resolution is ever done twice.
    private let cacheLock = NSLock()
    private var denoisedCache: [Int: CGImage] = [:]

    func cachedDenoised(width: Int) -> CGImage? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return denoisedCache[width]
    }

    func storeDenoised(_ image: CGImage) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        denoisedCache[image.width] = image
    }

    /// Whether this picture can have Pictty's noise reduction (not HDR, and the network is here).
    var offersNeuralDenoise: Bool { engine == .pictty && !isHDR && NeuralDenoiser.shared.isAvailable }

    /// `preview` is the screen-sized decode on screen now.
    init(url: URL, preview: CGImage, isHDR: Bool, maxPixel: Int) {
        self.url = url
        self.isHDR = isHDR
        self.preview = preview
        engine = ImageFormats.isRaw(url) ? .appleRAW : .pictty
        let headroom = isHDR ? max(preview.contentHeadroom, 1) : 1
        queue.async { [engine] in
            if engine == .appleRAW {
                self.raw = AppleRAW(url: url, maxPixel: maxPixel, hdr: isHDR)
            } else {
                self.source = LightEngine.shared?.source(preview, headroom: headroom)
            }
        }
    }

    /// The screen-sized picture with `a`; `done` runs on the main thread, and only for the newest request.
    func render(_ a: Adjustments, done: @escaping @MainActor (Rendered) -> Void) {
        let ticket = bump(&latest)
        queue.async {
            guard self.isLatest(ticket, self.latest) else { return }
            let start = CFAbsoluteTimeGetCurrent()
            var image: CGImage?
            if let raw = self.raw {
                image = raw.render(a).flatMap { AppleRAW.graded($0, a, isHDR: self.isHDR) }
            } else if let source = self.source {
                if a.denoise > 0, !source.hasDenoised { self.denoisePreview(source) }
                image = LightEngine.shared?.render(source, a, output: self.isHDR ? .linear : .display)?.image
            }
            guard let image, self.isLatest(ticket, self.latest) else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            DispatchQueue.main.async { MainActor.assumeIsolated { done(Rendered(image: image, milliseconds: ms, adjustments: a)) } }
        }
    }

    /// The network over the screen-sized picture, once; the render after it mixes it in.
    /// Queue-only.
    private func denoisePreview(_ source: LightEngine.Source) {
        guard offersNeuralDenoise, !denoising else { return }
        denoising = true
        let preview = preview
        denoiseQueue.async {
            let start = CFAbsoluteTimeGetCurrent()
            let report = self.onDenoiseProgress
            let denoised = NeuralDenoiser.shared.denoise(preview, progress: { fraction in
                DispatchQueue.main.async { MainActor.assumeIsolated { report?(fraction, false) } }
            })
            timingMark(String(format: "denoised %ld×%ld in %.0f ms", preview.width, preview.height,
                              (CFAbsoluteTimeGetCurrent() - start) * 1000))
            self.queue.async {
                if let denoised {
                    self.storeDenoised(denoised)
                    LightEngine.shared?.setDenoised(denoised, on: source)
                }
                self.denoising = false
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onDenoised?() } }
            }
        }
    }

    /// The picture's measured noise (0…1 of encoded luminance), for Auto; on the main thread.
    func measuredNoise(_ done: @escaping @MainActor (Float?) -> Void) {
        queue.async {
            let noise = self.source?.noise
            DispatchQueue.main.async { MainActor.assumeIsolated { done(noise) } }
        }
    }

    /// Every pixel the GPU can hold, with `a`: for zooming in past the preview.
    func renderFull(_ original: CGImage, _ a: Adjustments, done: @escaping @MainActor (Rendered) -> Void) {
        let ticket = bump(&latestFull)
        queue.async {
            guard self.isLatest(ticket, self.latestFull) else { return }
            let start = CFAbsoluteTimeGetCurrent()
            let report = self.onDenoiseProgress
            guard let image = Self.renderWhole(original, url: self.url, engine: self.engine, isHDR: self.isHDR, a, output: nil,
                                               progress: { fraction in
                                                   DispatchQueue.main.async { MainActor.assumeIsolated { report?(fraction, true) } }
                                               }, renderer: self,
                                               // A newer request makes this one moot: the network stops at the next tile.
                                               cancelled: { !self.isLatest(ticket, self.latestFull) }),
                  self.isLatest(ticket, self.latestFull) else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            DispatchQueue.main.async { MainActor.assumeIsolated { done(Rendered(image: image, milliseconds: ms, adjustments: a)) } }
        }
    }

    /// The whole picture with `a`, for saving or zooming. `output` nil picks what the screen wants.
    static func renderWhole(_ original: CGImage, url: URL, engine: Engine, isHDR: Bool, _ a: Adjustments,
                            output: LightEngine.Output?, progress: ((Double) -> Void)? = nil,
                            renderer: LightRenderer? = nil, cancelled: @escaping () -> Bool = { false }) -> CGImage? {
        if engine == .appleRAW {
            return AppleRAW(url: url, maxPixel: nil, hdr: isHDR)?.render(a, float: output == .linear || isHDR)
                .flatMap { AppleRAW.graded($0, a, isHDR: isHDR, output: output) }
        }
        guard let engineRef = LightEngine.shared,
              let src = engineRef.source(original, headroom: isHDR ? max(original.contentHeadroom, 1) : 1) else { return nil }
        // Every pixel through the network too, when noise reduction is asked for.
        // Done once per resolution: the screen-sized pass is reused when the picture is that size,
        // and a full-size pass is kept for the next change of a slider.
        if a.denoise > 0, !isHDR {
            if let known = renderer?.cachedDenoised(width: original.width) {
                engineRef.setDenoised(known, on: src)
            } else if let denoised = NeuralDenoiser.shared.denoise(original, progress: progress, cancelled: cancelled) {
                renderer?.storeDenoised(denoised)
                engineRef.setDenoised(denoised, on: src)
            }
        }
        return engineRef.render(src, a, output: output ?? (isHDR ? .linear : .display))?.image
    }

    func cancelAll() {
        _ = bump(&latest)
        _ = bump(&latestFull)
    }

    private func bump(_ counter: inout Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return counter
    }

    private func isLatest(_ ticket: Int, _ counter: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ticket == counter
    }
}

/// Apple's RAW engine with the panel's values: exposure and white balance go into the develop,
/// where the sensor's headroom and its own colour are; the tones are Core Image's own filters on
/// the result. Dehaze, vibrance, saturation and colour grading have no Apple counterpart (one that
/// protects skin or keeps lightness): Pictty's engine does them on the developed picture.
final class AppleRAW {
    private let filter: CIRAWFilter
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                              .workingFormat: CIFormat.RGBAh, .cacheIntermediates: true])
    private let hdr: Bool
    /// What the camera recorded, which the white balance sliders move from.
    private let asShotTemperature: Float
    private let asShotTint: Float
    /// Apple's own noise reduction for this camera, which Noise reduction raises from.
    private let defaultLuminanceNR: Float
    private let defaultColourNR: Float

    /// `maxPixel` nil develops every pixel.
    init?(url: URL, maxPixel: Int?, hdr: Bool) {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        self.filter = filter
        self.hdr = hdr
        asShotTemperature = filter.neutralTemperature
        asShotTint = filter.neutralTint
        defaultLuminanceNR = filter.luminanceNoiseReductionAmount
        defaultColourNR = filter.colorNoiseReductionAmount
        if let maxPixel {
            let native = filter.nativeSize
            let longest = max(native.width, native.height)
            if longest > 0 { filter.scaleFactor = Float(min(1, CGFloat(maxPixel) / longest)) }
        }
        if hdr { filter.extendedDynamicRangeAmount = 1 }
        if #available(macOS 26, *), filter.isHighlightRecoverySupported { filter.isHighlightRecoveryEnabled = true }
    }

    func render(_ a: Adjustments, float: Bool? = nil) -> CGImage? {
        filter.exposure = Float(a.exposure)
        // Warmer means the light is assumed bluer: the same doubling either way as Pictty's own.
        filter.neutralTemperature = asShotTemperature * Float(pow(2, a.temperature))
        filter.neutralTint = asShotTint + Float(a.tint) * 60
        // Noise reduction: from the camera's default up to Apple's strongest.
        filter.luminanceNoiseReductionAmount = defaultLuminanceNR + (1 - defaultLuminanceNR) * Float(a.denoise)
        filter.colorNoiseReductionAmount = defaultColourNR + (1 - defaultColourNR) * Float(a.denoise)
        guard var image = filter.outputImage else { return nil }
        // Core Image's tone filters are made for gamma-encoded values, not linear light: they
        // run between the sRGB curve and its inverse.
        let tones = a.highlights != 0 || a.shadows != 0 || a.contrast != 0 || a.brightness != 0
        if tones { image = image.applyingFilter("CILinearToSRGBToneCurve") }
        if a.highlights < 0 || a.shadows != 0 {
            let f = CIFilter(name: "CIHighlightShadowAdjust")!
            f.setValue(image, forKey: kCIInputImageKey)
            // Full strength at no radius flattens the picture and rings around faces; a radius of
            // about 1 % of the picture and a gentler range look like a highlights slider should.
            f.setValue(1 + 0.7 * min(a.highlights, 0), forKey: "inputHighlightAmount")
            f.setValue(0.8 * a.shadows, forKey: "inputShadowAmount")
            f.setValue(max(image.extent.width, image.extent.height) * 0.01, forKey: "inputRadius")
            image = f.outputImage ?? image
        }
        if a.highlights > 0 {
            let f = CIFilter(name: "CIToneCurve")!
            f.setValue(image, forKey: kCIInputImageKey)
            let h = CGFloat(a.highlights) * 0.12
            for (i, (x, y)) in [(0.0, 0.0), (0.25, 0.25), (0.5, 0.5), (0.75, 0.75 + h), (1.0, 1.0)].enumerated() {
                f.setValue(CIVector(x: x, y: y), forKey: "inputPoint\(i)")
            }
            image = f.outputImage ?? image
        }
        if a.contrast != 0 || a.brightness != 0 {
            let f = CIFilter(name: "CIColorControls")!
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(pow(2, a.contrast * 0.8), forKey: kCIInputContrastKey)
            f.setValue(a.brightness * 0.2, forKey: kCIInputBrightnessKey)
            f.setValue(1, forKey: kCIInputSaturationKey)
            image = f.outputImage ?? image
        }
        if tones { image = image.applyingFilter("CISRGBToneCurveToLinear") }
        let extent = image.extent
        if float ?? hdr, let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            return context.createCGImage(image, from: extent, format: .RGBAh, colorSpace: space)
        }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }

    /// Dehaze, vibrance, saturation and colour grading on a developed picture, through Pictty's engine.
    static func graded(_ image: CGImage, _ a: Adjustments, isHDR: Bool, output: LightEngine.Output? = nil) -> CGImage? {
        guard !a.isGradingNeutral || !a.isSaturationNeutral || a.dehaze != 0 else { return image }
        var g = Adjustments()
        g.dehaze = a.dehaze
        g.vibrance = a.vibrance
        g.saturation = a.saturation
        g.shadowColour = a.shadowColour
        g.midtoneColour = a.midtoneColour
        g.highlightColour = a.highlightColour
        g.balance = a.balance
        guard let engine = LightEngine.shared,
              let src = engine.source(image, headroom: isHDR ? max(image.contentHeadroom, 1) : 1) else { return image }
        return engine.render(src, g, output: output ?? (isHDR ? .linear : .display))?.image ?? image
    }
}
