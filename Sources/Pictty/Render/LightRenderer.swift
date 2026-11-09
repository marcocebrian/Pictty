import CoreImage
import Foundation
import PicttyCore

/// Runs the Light panel's renders off the main thread, the newest request first: a slider drag
/// asks many times a second, and only the last value still matters when the GPU comes free.
///
/// Every picture goes through Pictty's own engine. A camera RAW is developed from its sensor mosaic
/// (`SensorDevelop`: LibRaw and a learned demosaic and denoise, its tones matched to Apple's
/// develop of the same frame), and that develop is the picture: exposure, white balance, noise
/// reduction, sharpening and the rest are Pictty's. Apple's develop (`RAWDevelop`) is shown first,
/// at once, while the sensor develop runs (about a second), and stays the picture for a RAW the
/// sensor develop cannot take, with SCUNet for its noise; nothing is asked of the person either way.
final class LightRenderer: @unchecked Sendable {
    enum Engine: Equatable {
        case pictty
        /// A camera RAW: Apple's develop, then Pictty's engine.
        case raw
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
    /// What the network is given at screen size: the decode on screen, or a RAW's develop.
    private var denoiseInput: CGImage
    /// Whether the network's pass is on `source` (a RAW's stand-in does not count).
    private var neuralOnSource = false

    /// Whether the sensor develop is still under way: Apple's develop is on screen meanwhile, and the
    /// network is not run on it, since it is about to be replaced.
    private var sensorPending = false
    /// Whether `source` is the sensor develop (which has its own base of colour). Queue-only.
    private var sensorOnSource = false
    private var appleDevelop = LightRenderer.sensorModel == nil
    /// True when the RAW is Apple's develop for good: the internal engine could not read it.
    var developedByApple: Bool { lock.lock(); defer { lock.unlock() }; return appleDevelop }

    /// The whole picture as the sensor develop made it, once it has; nil when it could not.
    private var sensorFull: CGImage?
    /// The HDR headroom of the RAW's develop on screen, measured once and given to the screen-sized
    /// edit and the whole one alike: measured on each, they were told two different whites and
    /// showed two different pictures, one while a slider moved and the other when it stopped.
    private var rawHeadroom: Float = 1
    var rawWhite: Float {
        lock.lock(); defer { lock.unlock() }
        return rawHeadroom
    }
    private let sensorGroup = DispatchGroup()
    private static let sensorQueue = DispatchQueue(label: "pictty.sensor", qos: .userInitiated)
    /// The sensor network, in the app.
    static let sensorModel = Bundle.main.url(forResource: "SensorNetwork", withExtension: "mlmodelc")

    /// A RAW's base of noise reduction, measured once on its screen-sized develop (0 once the
    /// sensor develop, already denoised, is the picture).
    private var rawBase: Double?
    var rawBaseDenoise: Double? {
        lock.lock(); defer { lock.unlock() }
        return rawBase
    }

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

    /// Whether this picture can have the network: the network is here, and the picture is SDR or a
    /// RAW (whose light past white the denoiser leaves alone, see `denoiseClipsToUnit`).
    var offersNeuralDenoise: Bool { NeuralDenoiser.shared.isAvailable && (engine == .raw || !isHDR) }

    /// `preview` is the screen-sized decode on screen now.
    init(url: URL, preview: CGImage, isHDR: Bool, maxPixel: Int) {
        self.url = url
        self.isHDR = isHDR
        denoiseInput = preview
        engine = ImageFormats.isRaw(url) ? .raw : .pictty
        let headroom = isHDR ? max(preview.contentHeadroom, 1) : 1
        queue.async { [engine] in
            if engine == .raw {
                guard let (develop, src) = Self.rawSource(url, maxPixel: maxPixel, hdr: isHDR, standIn: true) else { return }
                self.lock.lock(); self.rawHeadroom = develop.headroom; self.lock.unlock()
                let base = RAWDevelop.baseDenoise(develop.image)
                self.lock.lock(); self.rawBase = base; self.lock.unlock()
                self.denoiseInput = develop.image
                self.source = src
                timingMark(String(format: "RAW developed by Apple %ld×%ld, base noise reduction %.2f", src.width, src.height, base))
                if Self.sensorModel != nil {
                    self.sensorPending = true
                    self.developSensor(reference: develop.image, size: (src.width, src.height), hdr: isHDR)
                }
            } else {
                self.source = LightEngine.shared?.source(preview, headroom: headroom)
            }
        }
    }

    /// The sensor develop, on its own queue; when it is done it becomes the picture, at the size of
    /// Apple's develop on screen, and the canvas renders again. Queue-only.
    private func developSensor(reference: CGImage, size: (Int, Int), hdr: Bool) {
        sensorGroup.enter()
        Self.sensorQueue.async {
            let full = Self.sensorDevelop(self.url, reference: reference, hdr: hdr)
            let headroom = hdr ? (full.map { LookMatch.peak($0) } ?? 1) : 1
            self.lock.lock(); self.sensorFull = full; if full != nil { self.rawHeadroom = headroom } else { self.appleDevelop = true }; self.lock.unlock()
            self.sensorGroup.leave()
            self.queue.async {
                self.sensorPending = false
                // The same framing as Apple's develop, or it is not used.
                if let full, abs(Double(full.width) / Double(full.height) - Double(size.0) / Double(size.1)) < 0.01,
                   let preview = LookMatch.downscaled(full, width: size.0, height: size.1),
                   let src = LightEngine.shared?.source(preview, headroom: headroom) {
                    src.denoiseClipsToUnit = true
                    self.source = src
                    self.denoiseInput = preview
                    self.neuralOnSource = false
                    self.sensorOnSource = true
                    self.cacheLock.lock(); self.denoisedCache.removeAll(); self.cacheLock.unlock()
                    self.lock.lock(); self.rawBase = 0; self.lock.unlock()
                } else if full != nil {
                    self.lock.lock(); self.sensorFull = nil; self.appleDevelop = true; self.lock.unlock()
                    timingMark("RAW: the sensor develop's framing is not Apple's; Apple's develop stays")
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onDenoised?() } }
            }
        }
    }

    /// The whole picture from the sensor, its tones matched to `reference` (Apple's develop of the
    /// same frame); nil, said in the log, when it cannot be done.
    static func sensorDevelop(_ url: URL, reference: CGImage, hdr: Bool, cancelled: () -> Bool = { false }) -> CGImage? {
        guard let model = sensorModel else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (raw, clipped) = try SensorDevelop.developed(url, model: model, cancelled: cancelled)
            guard let look = LookMatch.fit(raw, to: reference), var out = look.apply(raw) else {
                timingMark("RAW: no tones to match; Apple's develop stays")
                return nil
            }
            // Apple's develop, every pixel, without lens corrections, with this develop's detail on it.
            guard !cancelled(),
                  let apple = RAWDevelop(url: url, maxPixel: nil, hdr: hdr, standIn: false, lensCorrection: false),
                  apple.image.width == out.width, apple.image.height == out.height,
                  let combined = DetailTransfer.apply(apple: apple.image, sensor: out, clipped: clipped) else {
                timingMark("RAW: Apple's develop does not meet the sensor's; Apple's develop stays")
                return nil
            }
            out = combined
            // Apple's lens corrections, measured on its two develops of this picture.
            if let uncorrected = LookMatch.downscaled(apple.image, width: reference.width, height: reference.height),
               let lens = LensMatch.measure(corrected: reference, uncorrected: uncorrected) {
                timingMark(String(format: "RAW lens: distortion %.4f %.4f %.4f, scale %.4f, vignetting %.3f %.3f, %ld points, %.2f px",
                                  lens.k[0], lens.k[1], lens.k[2], lens.scale, lens.v[0], lens.v[1], lens.points, lens.residual))
                if !lens.isIdentity, let corrected = lens.apply(out) { out = corrected }
            } else {
                timingMark("RAW lens: not measured; the sensor develop stays uncorrected")
            }
            timingMark(String(format: "RAW developed from the sensor %ld×%ld in %.0f ms", out.width, out.height,
                              (CFAbsoluteTimeGetCurrent() - start) * 1000))
            return out
        } catch {
            timingMark("RAW: sensor develop not possible (\(error)); Apple's develop stays")
            return nil
        }
    }

    /// The sensor develop of every pixel, waiting for it if it is under way; nil when there is none.
    func sensorDeveloped() -> CGImage? {
        sensorGroup.wait()
        lock.lock(); defer { lock.unlock() }
        return sensorFull
    }

    /// A RAW developed and uploaded: the denoiser's 0…1 kept to that range, and Apple's own noise
    /// reduction standing in for the network's until it is done.
    /// `headroom` nil takes the develop's own.
    private static func rawSource(_ url: URL, maxPixel: Int?, hdr: Bool, standIn: Bool,
                                  headroom: Float? = nil) -> (RAWDevelop, LightEngine.Source)? {
        guard let engine = LightEngine.shared,
              let develop = RAWDevelop(url: url, maxPixel: maxPixel, hdr: hdr, standIn: standIn),
              let src = engine.source(develop.image, headroom: headroom ?? develop.headroom) else { return nil }
        src.denoiseClipsToUnit = true
        if let standIn = develop.standIn { engine.setDenoised(standIn, on: src) }
        return (develop, src)
    }

    /// What the engine is asked for: a RAW's sliders on top of its base.
    private static func effective(_ a: Adjustments, engine: Engine, base: Double?, sensor: Bool = false) -> Adjustments {
        engine == .raw ? RAWDevelop.effective(a, baseDenoise: base ?? 0, sensor: sensor) : a
    }

    /// The screen-sized picture with `a`; `done` runs on the main thread, and only for the newest request.
    func render(_ a: Adjustments, done: @escaping @MainActor (Rendered) -> Void) {
        let ticket = bump(&latest)
        queue.async {
            guard self.isLatest(ticket, self.latest), let source = self.source else { return }
            let start = CFAbsoluteTimeGetCurrent()
            let e = Self.effective(a, engine: self.engine, base: self.rawBaseDenoise, sensor: self.sensorOnSource)
            if e.denoise > 0, !self.neuralOnSource, !self.sensorPending { self.denoisePreview(source) }
            let image = LightEngine.shared?.render(source, e, output: self.isHDR ? .linear : .display)?.image
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
        let input = denoiseInput
        denoiseQueue.async {
            let start = CFAbsoluteTimeGetCurrent()
            let report = self.onDenoiseProgress
            let denoised = NeuralDenoiser.shared.denoise(input, progress: { fraction in
                DispatchQueue.main.async { MainActor.assumeIsolated { report?(fraction, false) } }
            })
            timingMark(String(format: "denoised %ld×%ld in %.0f ms", input.width, input.height,
                              (CFAbsoluteTimeGetCurrent() - start) * 1000))
            self.queue.async {
                // Unless the picture was replaced meanwhile (the sensor develop arrived).
                if let denoised, self.source === source {
                    self.storeDenoised(denoised)
                    LightEngine.shared?.setDenoised(denoised, on: source)
                    self.neuralOnSource = true
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
        timingMark("every pixel: asked (\(ticket))")
        queue.async {
            guard self.isLatest(ticket, self.latestFull) else { return timingMark("every pixel: \(ticket) moot before it began") }
            let start = CFAbsoluteTimeGetCurrent()
            let report = self.onDenoiseProgress
            guard let image = Self.renderWhole(original, url: self.url, engine: self.engine, isHDR: self.isHDR, a, output: nil,
                                               progress: { fraction in
                                                   DispatchQueue.main.async { MainActor.assumeIsolated { report?(fraction, true) } }
                                               }, renderer: self,
                                               // A newer request makes this one moot: the network stops at the next tile.
                                               cancelled: { !self.isLatest(ticket, self.latestFull) }),
                  self.isLatest(ticket, self.latestFull) else { return timingMark("every pixel: \(ticket) stopped") }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            DispatchQueue.main.async { MainActor.assumeIsolated { done(Rendered(image: image, milliseconds: ms, adjustments: a)) } }
        }
    }

    /// The whole picture with `a`, for saving or zooming. `output` nil picks what the screen wants.
    /// A RAW is developed again at every pixel; `original` is used only for other pictures.
    static func renderWhole(_ original: CGImage, url: URL, engine: Engine, isHDR: Bool, _ a: Adjustments,
                            output: LightEngine.Output?, progress: ((Double) -> Void)? = nil,
                            renderer: LightRenderer? = nil, cancelled: @escaping () -> Bool = { false }) -> CGImage? {
        guard let engineRef = LightEngine.shared else { return nil }
        let src: LightEngine.Source
        let denoiseInput: CGImage
        var e = a
        if engine == .raw, let full = renderer.map({ $0.sensorDeveloped() }) ?? standaloneSensor(url, isHDR: isHDR),
           let s = engineRef.source(full, headroom: isHDR ? (renderer?.rawWhite ?? LookMatch.peak(full)) : 1) {
            // Developed from the sensor, and denoised there already: the slider's noise reduction
            // only adds to it.
            s.denoiseClipsToUnit = true
            src = s
            denoiseInput = full
            e = effective(a, engine: engine, base: 0, sensor: true)
        } else if engine == .raw {
            // Apple's noise reduction stands in only when there is no network to do it.
            guard let (develop, s) = rawSource(url, maxPixel: nil, hdr: isHDR, standIn: !NeuralDenoiser.shared.isAvailable,
                                               headroom: renderer?.rawWhite) else { return nil }
            src = s
            denoiseInput = develop.image
            // The base as the screen-sized develop measured it: noise is measured per pixel, and
            // the same picture at every pixel would measure noisier than on screen.
            let base = renderer?.rawBaseDenoise ?? RAWDevelop(url: url, maxPixel: 2048, hdr: isHDR, standIn: false)
                .map { RAWDevelop.baseDenoise($0.image) } ?? 0
            e = effective(a, engine: engine, base: base)
        } else {
            guard let s = engineRef.source(original, headroom: isHDR ? max(original.contentHeadroom, 1) : 1) else { return nil }
            src = s
            denoiseInput = original
        }
        // Every pixel through the network too, when noise reduction is asked for.
        // Done once per resolution: the screen-sized pass is reused when the picture is that size,
        // and a full-size pass is kept for the next change of a slider.
        if e.denoise > 0, engine == .raw || !isHDR {
            if let known = renderer?.cachedDenoised(width: denoiseInput.width) {
                engineRef.setDenoised(known, on: src)
            } else if let denoised = NeuralDenoiser.shared.denoise(denoiseInput, progress: progress, cancelled: cancelled) {
                renderer?.storeDenoised(denoised)
                engineRef.setDenoised(denoised, on: src)
            }
        }
        return engineRef.render(src, e, output: output ?? (isHDR ? .linear : .display))?.image
    }

    /// The sensor develop for a save with no session on screen: its tones matched to a small
    /// Apple develop of the frame.
    private static func standaloneSensor(_ url: URL, isHDR: Bool) -> CGImage? {
        guard sensorModel != nil, let reference = RAWDevelop(url: url, maxPixel: 2048, hdr: isHDR, standIn: false) else { return nil }
        return sensorDevelop(url, reference: reference.image, hdr: isHDR)
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
