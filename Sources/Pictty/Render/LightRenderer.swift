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
        let adjustments: LightAdjustments
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

    /// `preview` is the screen-sized decode on screen now.
    init(url: URL, preview: CGImage, isHDR: Bool, maxPixel: Int) {
        self.url = url
        self.isHDR = isHDR
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
    func render(_ a: LightAdjustments, done: @escaping @MainActor (Rendered) -> Void) {
        let ticket = bump(&latest)
        queue.async {
            guard self.isLatest(ticket, self.latest) else { return }
            let start = CFAbsoluteTimeGetCurrent()
            var image: CGImage?
            if let raw = self.raw {
                image = raw.render(a)
            } else if let source = self.source {
                image = LightEngine.shared?.render(source, a, output: self.isHDR ? .linear : .display)?.image
            }
            guard let image, self.isLatest(ticket, self.latest) else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            DispatchQueue.main.async { MainActor.assumeIsolated { done(Rendered(image: image, milliseconds: ms, adjustments: a)) } }
        }
    }

    /// Every pixel the GPU can hold, with `a`: for zooming in past the preview.
    func renderFull(_ original: CGImage, _ a: LightAdjustments, done: @escaping @MainActor (Rendered) -> Void) {
        let ticket = bump(&latestFull)
        queue.async {
            guard self.isLatest(ticket, self.latestFull) else { return }
            let start = CFAbsoluteTimeGetCurrent()
            guard let image = Self.renderWhole(original, url: self.url, engine: self.engine, isHDR: self.isHDR, a, output: nil),
                  self.isLatest(ticket, self.latestFull) else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            DispatchQueue.main.async { MainActor.assumeIsolated { done(Rendered(image: image, milliseconds: ms, adjustments: a)) } }
        }
    }

    /// The whole picture with `a`, for saving or zooming. `output` nil picks what the screen wants.
    static func renderWhole(_ original: CGImage, url: URL, engine: Engine, isHDR: Bool, _ a: LightAdjustments,
                            output: LightEngine.Output?) -> CGImage? {
        if engine == .appleRAW {
            return AppleRAW(url: url, maxPixel: nil, hdr: isHDR)?.render(a, float: output == .linear || isHDR)
        }
        guard let engineRef = LightEngine.shared,
              let src = engineRef.source(original, headroom: isHDR ? max(original.contentHeadroom, 1) : 1) else { return nil }
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

/// Apple's RAW engine with the Light values: exposure goes into the develop, where the sensor's
/// headroom still is; the rest is Core Image's own filters on the result.
final class AppleRAW {
    private let filter: CIRAWFilter
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                              .workingFormat: CIFormat.RGBAh, .cacheIntermediates: true])
    private let hdr: Bool

    /// `maxPixel` nil develops every pixel.
    init?(url: URL, maxPixel: Int?, hdr: Bool) {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        self.filter = filter
        self.hdr = hdr
        if let maxPixel {
            let native = filter.nativeSize
            let longest = max(native.width, native.height)
            if longest > 0 { filter.scaleFactor = Float(min(1, CGFloat(maxPixel) / longest)) }
        }
        if hdr { filter.extendedDynamicRangeAmount = 1 }
        if #available(macOS 26, *), filter.isHighlightRecoverySupported { filter.isHighlightRecoveryEnabled = true }
    }

    func render(_ a: LightAdjustments, float: Bool? = nil) -> CGImage? {
        filter.exposure = Float(a.exposure)
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
}
