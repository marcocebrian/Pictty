import CoreGraphics
@testable import PicttyCore
import XCTest

final class LightEngineTests: XCTestCase {
    /// A horizontal ramp from black to white over a band of colour, 8-bit sRGB.
    private func ramp(width: Int = 256, height: Int = 64) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(x * 255 / (width - 1))
                let i = (y * width + x) * 4
                px[i] = v; px[i + 1] = y < height / 2 ? v : v / 2; px[i + 2] = y < height / 2 ? v : v / 3; px[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    private func flat(_ value: UInt8) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(value) / 255, green: CGFloat(value) / 255, blue: CGFloat(value) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        return ctx.makeImage()!
    }

    /// Pixels as linear sRGB floats, via colour management.
    private func linear(_ image: CGImage) -> [Float] {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let w = image.width, h = image.height
        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return out
    }

    private func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    func testNeutralIsTheIdentity() throws {
        let engine = try XCTUnwrap(LightEngine())
        let image = ramp()
        let src = try XCTUnwrap(engine.source(image))
        let out = try XCTUnwrap(engine.render(src, Adjustments(), output: .linear)).image
        XCTAssertLessThan(maxDifference(linear(out), linear(image)), 0.002)
    }

    func testLoweredExposureHalvesTheLight() throws {
        let engine = try XCTUnwrap(LightEngine())
        let image = flat(160)
        let src = try XCTUnwrap(engine.source(image))
        var a = Adjustments()
        a.exposure = -1
        let before = linear(image)[0], after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)[0]
        XCTAssertEqual(after, before / 2, accuracy: 0.002)
    }

    func testRaisedExposureNeverPassesWhite() throws {
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(ramp()))
        var a = Adjustments()
        a.exposure = 4
        let px = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
        XCTAssertLessThanOrEqual(px.max() ?? 0, 1.0005)
    }

    /// Contrast (per pixel) and brightness (by regions): black and white pictures stay as they are;
    /// on the ramp brightness keeps its order, contrast raised darkens below mid-grey and lightens
    /// above it, and brightness raised lifts the middle.
    func testContrastAndBrightness() throws {
        let engine = try XCTUnwrap(LightEngine())
        for value: UInt8 in [0, 255] {
            let src = try XCTUnwrap(engine.source(flat(value)))
            for (c, b) in [(0.8, 0.0), (-0.8, 0.0), (0.0, 0.8), (0.0, -0.8)] {
                var a = Adjustments()
                a.contrast = c; a.brightness = b
                let v = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)[0]
                XCTAssertEqual(v, value == 0 ? 0 : 1, accuracy: 0.003, "\(value), contrast \(c), brightness \(b)")
            }
        }
        let image = ramp()
        let src = try XCTUnwrap(engine.source(image))
        let before = stride(from: 0, to: 256 * 4, by: 4).map { linear(image)[$0 + 1] }
        func row(contrast: Double = 0, brightness: Double = 0) throws -> [Float] {
            var a = Adjustments()
            a.contrast = contrast; a.brightness = brightness
            let px = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
            return stride(from: 0, to: 256 * 4, by: 4).map { px[$0 + 1] }
        }
        for r in [try row(contrast: 0.8), try row(contrast: -0.8), try row(brightness: 0.8), try row(brightness: -0.8)] {
            XCTAssertTrue(zip(r, r.dropFirst()).allSatisfy { $0 <= $1 + 2e-3 })
            XCTAssertLessThanOrEqual(r.max()!, 1.0005)
        }
        let contrast = try row(contrast: 0.8), brighter = try row(brightness: 0.8)
        XCTAssertLessThan(contrast[50], before[50])
        XCTAssertGreaterThan(contrast[220], before[220])
        XCTAssertGreaterThan(brighter[128], before[128] * 1.1)
    }

    /// Raised exposure, half a camera's and half by regions: a dark level takes all of it, a bright
    /// one comes up too (towards white, so the levels stretch), and their order stays.
    func testExposureRaisesEveryLevelAndStretchesThem() throws {
        let engine = try XCTUnwrap(LightEngine())
        var levels: [Float] = []
        for value: UInt8 in [30, 60, 120, 200] {
            let image = flat(value)
            let src = try XCTUnwrap(engine.source(image))
            var a = Adjustments()
            a.exposure = 2
            let after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)[0]
            let before = linear(image)[0]
            if value == 30 { XCTAssertEqual(after / before, 4, accuracy: 0.1, "dark: all the stops") }
            if value == 200 { XCTAssertGreaterThan(after, before + 0.15, "bright: up towards white") }
            levels.append(after)
        }
        XCTAssertEqual(levels, levels.sorted(), "brighter stays brighter")
    }

    /// Exposure raised with Highlights lowered: a bright, textured sky the exposure alone would
    /// push into white keeps its light from the picture as it came, so Highlights still has its
    /// tones to work on, while a dark ground takes the same exposure as without Highlights.
    func testHighlightsRecoverWhatExposurePushedIntoWhite() throws {
        let w = 128, h = 128
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        // Top half (rows 0…63 in the bitmap's top-down order) a sky of 4-pixel stripes, 0.55 and
        // 0.7; bottom half a dark ground at 0.05.
        for stripe in 0..<32 {
            let v: CGFloat = stripe % 2 == 0 ? 0.55 : 0.7
            ctx.setFillColor(CGColor(colorSpace: space, components: [v, v, v, 1])!)
            ctx.fill(CGRect(x: stripe * 4, y: 64, width: 4, height: 64))
        }
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.05, 0.05, 0.05, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 64))
        let image = ctx.makeImage()!
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(image))
        func render(_ exposure: Double, _ highlights: Double) throws -> [Float] {
            var a = Adjustments()
            a.exposure = exposure
            a.highlights = highlights
            return linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
        }
        func at(_ p: [Float], _ x: Int, _ y: Int) -> Float { p[(y * w + x) * 4 + 1] }
        func stripes(_ p: [Float]) -> Float { abs(at(p, 66, 32) - at(p, 62, 32)) }
        let exposed = try render(2, 0), both = try render(2, -1), plain = try render(0, -1)
        XCTAssertGreaterThan(stripes(both), stripes(exposed) * 1.5, "the sky's tones come back")
        XCTAssertLessThan(at(both, 64, 32), at(exposed, 64, 32) - 0.1, "the sky comes down out of white")
        XCTAssertEqual(at(both, 64, 100), at(exposed, 64, 100), accuracy: 0.02, "the ground keeps its exposure")
        XCTAssertEqual(at(plain, 64, 100), at(linear(image), 64, 100), accuracy: 0.01, "no exposure: as before")
    }

    /// Exposure raised with Highlights lowered: broad regions from dim to bright stay in their
    /// order. Scaling the stops by how far a region was pushed made one at 0.4 land darker than one
    /// at 0.3, and the picture broke into patches.
    func testExposureWithHighlightsKeepsRegionsInOrder() throws {
        let w = 256, h = 64
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        let levels: [CGFloat] = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
        for (i, v) in levels.enumerated() {
            ctx.setFillColor(CGColor(colorSpace: space, components: [v, v, v, 1])!)
            ctx.fill(CGRect(x: i * 32, y: 0, width: 32, height: h))
        }
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(ctx.makeImage()!))
        for (exposure, highlights) in [(1.0, -1.0), (1.0, -0.5), (2.0, -1.0)] {
            var a = Adjustments()
            a.exposure = exposure
            a.highlights = highlights
            let p = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
            let centres = levels.indices.map { p[(32 * w + $0 * 32 + 16) * 4 + 1] }
            for i in 1..<centres.count {
                XCTAssertGreaterThanOrEqual(centres[i], centres[i - 1] - 0.002,
                                            "exposure \(exposure), highlights \(highlights): \(centres)")
            }
        }
    }

    /// A lit face pulled down by Highlights keeps its colour: no more colourful than it was.
    func testHighlightsDoNotSaturateSkin() throws {
        let image = colour(242, 204, 178)
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(image))
        var a = Adjustments()
        a.highlights = -1
        let before = linear(image)[0..<4]
        let after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)[0..<4]
        XCTAssertLessThan(after[1], before[1] - 0.02, "it comes down")
        XCTAssertLessThan(colourfulness(after), colourfulness(before) * 1.05)
    }

    /// A saturated colour pushed past white fades towards white, as on film: raised exposure never
    /// makes a colour more saturated than it was.
    func testRaisedExposureDoesNotSaturate() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = ctx.makeImage()!
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(image))
        func saturation(_ p: [Float]) -> Float {
            let c = Array(p[0..<3]), hi = c.max()!, lo = c.min()!
            return (hi - lo) / max(hi, 1e-6)
        }
        let before = saturation(linear(image))
        var last = before
        for ev in [1.0, 2.0, 3.0] {
            var a = Adjustments()
            a.exposure = ev
            let s = saturation(linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image))
            XCTAssertLessThanOrEqual(s, last + 0.01, "ev \(ev)")
            last = s
        }
        XCTAssertLessThan(last, before * 0.6, "well past white, it fades towards white")
    }

    /// Highlights pulled down hard by the local Laplacian: a bright, noisy patch comes out darker
    /// and no noisier for its brightness than it went in.
    func testLaplacianHighlightsDoNotRaiseNoise() throws {
        let w = 128, h = 128
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 3
        for i in 0..<(w * h) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let v = UInt8(215 + Int(seed >> 28) - 8)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
        }
        let image = ctx.makeImage()!
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(image))
        func relativeNoise(_ p: [Float]) -> Float {
            let g = stride(from: 0, to: p.count, by: 4).map { p[$0 + 1] }
            let mean = g.reduce(0, +) / Float(g.count)
            return (g.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(g.count)).squareRoot() / mean
        }
        var a = Adjustments()
        a.highlights = -1
        let before = linear(image), after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
        XCTAssertLessThan(after[4 * (64 * w + 64) + 1], before[4 * (64 * w + 64) + 1], "darker")
        XCTAssertLessThan(relativeNoise(after), relativeNoise(before) * 1.05)
    }

    /// A scene of strong colours (each with a nearly black channel, as the dark channel prior
    /// expects of a clear scene) under an even haze, and the distance, which is all haze. Dehaze
    /// brings back the surfaces' contrast that the haze took, keeping the scene about as bright
    /// as it was; lowered, it adds haze. The veil is a quarter of the light, as over the far city of
    /// the haze test pictures: a scene under a veil much thicker than that is nearly as bright as
    /// the haze and is taken for sky, which Dehaze leaves alone (here, the yellow patch).
    func testDehazeTakesOutHaze() throws {
        let w = 120, h = 80
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let air = SIMD3<Double>(0.8, 0.82, 0.86), t = 0.75
        let colours: [SIMD3<Double>] = [SIMD3(0.6, 0.05, 0.02), SIMD3(0.02, 0.4, 0.05), SIMD3(0.03, 0.08, 0.5),
                                        SIMD3(0.5, 0.4, 0.01), SIMD3(0.01, 0.3, 0.35), SIMD3(0.4, 0.02, 0.3)]
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        for (i, j) in colours.enumerated() {
            // The last patch is the distance: haze only. The others have a surface, stripes 8 pixels
            // wide: a smooth region has nothing for Dehaze to reveal.
            for stripe in 0..<5 {
                let surface = j * (stripe % 2 == 0 ? 0.8 : 1.2)
                let c = i == colours.count - 1 ? air : surface * t + air * (1 - t)
                ctx.setFillColor(CGColor(colorSpace: space, components: [c.x, c.y, c.z, 1])!)
                ctx.fill(CGRect(x: (i % 3) * 40 + stripe * 8, y: (i / 3) * 40, width: 8, height: 40))
            }
        }
        let hazy = ctx.makeImage()!
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(hazy))
        XCTAssertEqual(Double(src.airlight.z), air.z, accuracy: 0.03, "the haze's light, read in the distance")
        // The patches with a surface under a veil, not the yellow one: their stripes' contrast at the
        // middle, away from the borders where the guided filter blends, and their brightness.
        let patches = [0, 1, 2, 4]
        func luminance(_ p: [Float], _ x: Int, _ y: Int) -> Float {
            let i = (y * w + x) * 4
            return 0.2126 * p[i] + 0.7152 * p[i + 1] + 0.0722 * p[i + 2]
        }
        func contrast(_ p: [Float]) -> Float {
            patches.map { i -> Float in
                let x = (i % 3) * 40, y = (i / 3) * 40 + 20
                let a = luminance(p, x + 12, y), b = luminance(p, x + 20, y)
                return abs(a - b) / (a + b)
            }.reduce(0, +) / Float(patches.count)
        }
        func brightness(_ p: [Float]) -> Float {
            patches.map { i in luminance(p, (i % 3) * 40 + 16, (i / 3) * 40 + 20) }.reduce(0, +) / Float(patches.count)
        }
        let before = linear(hazy)
        var a = Adjustments()
        a.dehaze = 1
        let after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
        XCTAssertGreaterThan(contrast(after), contrast(before) * 1.15, "the surfaces come out of the haze")
        XCTAssertEqual(brightness(after), brightness(before), accuracy: brightness(before) * 0.1, "about as bright")
        a.dehaze = -1
        XCTAssertLessThan(contrast(linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)), contrast(before) * 0.8,
                          "more haze")
    }

    /// A smooth sky, a gradient from blue to pale near the horizon, is not Dehaze's to change:
    /// nothing in it is hidden by haze, and taking "haze" out of it only darkens it into bands.
    func testDehazeLeavesASmoothSkyAlone() throws {
        // A real sky's size: its gradient is gentle from one pixel to the next.
        let w = 800, h = 600
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let t = Double(y) / Double(h - 1)
            for x in 0..<w {
                let i = (y * w + x) * 4
                px[i] = UInt8(120 + 110 * t); px[i + 1] = UInt8(165 + 70 * t); px[i + 2] = UInt8(230 + 15 * t); px[i + 3] = 255
            }
        }
        let image = ctx.makeImage()!
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(image))
        var a = Adjustments()
        a.dehaze = 1
        let after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
        XCTAssertLessThan(maxDifference(after, linear(image)), 0.01)
    }

    /// One flat colour, 8-bit sRGB.
    private func colour(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return ctx.makeImage()!
    }

    /// How colourful a linear pixel is: its channels' spread over their mean.
    private func colourfulness(_ p: ArraySlice<Float>) -> Float {
        let c = Array(p.prefix(3))
        return (c.max()! - c.min()!) / max(c.reduce(0, +) / 3, 1e-6)
    }

    private func adjusted(_ image: CGImage, vibrance: Double = 0, saturation: Double = 0) throws -> ArraySlice<Float> {
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(image))
        var a = Adjustments()
        a.vibrance = vibrance; a.saturation = saturation
        return linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)[0..<4]
    }

    func testSaturationAtMinusOneIsGrey() throws {
        let p = try adjusted(colour(40, 120, 200), saturation: -1)
        XCTAssertEqual(p[p.startIndex], p[p.startIndex + 1], accuracy: 0.004)
        XCTAssertEqual(p[p.startIndex + 2], p[p.startIndex + 1], accuracy: 0.004)
    }

    /// Saturation raises skin by about half as much as another colour equally colourful; vibrance
    /// barely touches skin, and raises a muted colour more than a strong one.
    func testSkinIsProtectedAndVibranceFavoursMutedColours() throws {
        let skin = colour(224, 172, 150), muted = colour(150, 170, 200), strong = colour(30, 90, 220)
        func gain(_ image: CGImage, vibrance: Double = 0, saturation: Double = 0) throws -> Float {
            try colourfulness(adjusted(image, vibrance: vibrance, saturation: saturation)) / colourfulness(adjusted(image))
        }
        let skinSat = try gain(skin, saturation: 0.6), mutedSat = try gain(muted, saturation: 0.6)
        XCTAssertGreaterThan(skinSat, 1.05)
        XCTAssertLessThan(skinSat - 1, 0.75 * (mutedSat - 1))
        let skinVib = try gain(skin, vibrance: 0.8), mutedVib = try gain(muted, vibrance: 0.8)
        let strongVib = try gain(strong, vibrance: 0.8)
        XCTAssertLessThan(skinVib - 1, 0.35 * (mutedVib - 1))
        XCTAssertGreaterThan(mutedVib, strongVib)
        XCTAssertGreaterThanOrEqual(strongVib, 0.999)
    }

    /// Vibrance works by regions: a grey picture's colour noise is raised far less than the colour
    /// of a region would be (per pixel, each speck was taken for a muted colour and raised by 80 %).
    func testVibranceByRegionsLeavesColourNoiseAlone() throws {
        let w = 96, h = 96
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 7
        func noise() -> Int { seed = seed &* 1_664_525 &+ 1_013_904_223; return Int(seed >> 28) - 8 }
        for i in 0..<(w * h) {
            px[i * 4] = UInt8(128 + noise()); px[i * 4 + 1] = UInt8(128 + noise()); px[i * 4 + 2] = UInt8(128 + noise())
            px[i * 4 + 3] = 255
        }
        let image = ctx.makeImage()!
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(image))
        func spread(_ vibrance: Double) throws -> Float {
            var a = Adjustments()
            a.vibrance = vibrance
            let p = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
            var sum: Float = 0
            for i in 0..<(w * h) { sum += abs(p[i * 4] - p[i * 4 + 1]) + abs(p[i * 4 + 2] - p[i * 4 + 1]) }
            return sum / Float(w * h)
        }
        let before = try spread(0), after = try spread(1)
        XCTAssertLessThan(after, before * 1.5)
    }

    /// A strong colour pushed hard stays inside what the screen shows (Display P3) instead of
    /// clipping a channel.
    func testSaturationStaysInsideTheGamut() throws {
        let p = Array(try adjusted(colour(200, 40, 30), saturation: 1).prefix(3))
        let p3 = [0.8225 * p[0] + 0.1774 * p[1], 0.0332 * p[0] + 0.9669 * p[1], 0.0171 * p[0] + 0.0724 * p[1] + 0.9108 * p[2]]
        XCTAssertGreaterThanOrEqual(p3.min()!, -0.005)
        XCTAssertLessThanOrEqual(p3.max()!, 1.005)
        XCTAssertGreaterThan(colourfulness(p[...]), colourfulness(try adjusted(colour(200, 40, 30))))
    }

    func testColourGradingKeepsLuminance() throws {
        let engine = try XCTUnwrap(LightEngine())
        let image = ramp()
        let src = try XCTUnwrap(engine.source(image))
        var a = Adjustments()
        a.shadowColour = ColourShift(hue: 220, amount: 1)
        a.highlightColour = ColourShift(hue: 40, amount: 0.8)
        let before = linear(image), after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
        func luma(_ p: [Float], _ i: Int) -> Float { 0.2126 * p[i] + 0.7152 * p[i + 1] + 0.0722 * p[i + 2] }
        var moved = false
        // Below white: there a tint would have to pass 1.0 to keep its luminance, and SDR clips it.
        for i in stride(from: 0, to: before.count, by: 4 * 7) where luma(before, i) < 0.6 {
            XCTAssertEqual(luma(after, i), luma(before, i), accuracy: 0.003)
            if abs(after[i] - after[i + 2]) > 0.01, abs(before[i] - before[i + 2]) < 0.001 { moved = true }
        }
        XCTAssertTrue(moved, "grey pixels took a colour")
    }

    func testWhiteBalanceWarmsAndCools() throws {
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(flat(128)))
        var a = Adjustments()
        a.temperature = 0.6
        let warm = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
        a.temperature = -0.6
        let cool = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
        XCTAssertGreaterThan(warm[0], warm[2] * 1.15)
        XCTAssertGreaterThan(cool[2], cool[0] * 1.15)
    }

    /// On a flat picture there is no detail to keep: the local Laplacian must land exactly where
    /// the highlights curve does.
    func testHighlightsLandOnTheCurveOnAFlatPicture() throws {
        let engine = try XCTUnwrap(LightEngine())
        for value: UInt8 in [170, 220] {
            let image = flat(value)
            let src = try XCTUnwrap(engine.source(image))
            var a = Adjustments()
            a.highlights = -0.8
            let got = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)[64 * 128 * 4 + 256]
            // The curve, as the kernels have it, on encoded brightness: a pull of 0.21·h that rises
            // from 0.5 to its full at 0.85 (where these pictures' highlights put it) and falls to none
            // at white, linearly.
            func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
                let t = min(max((x - a) / (b - a), 0), 1)
                return t * t * (3 - 2 * t)
            }
            let l = Float(value) / 255
            let l1 = l + -0.8 * 0.21 * smoothstep(0.5, 0.85, l) * min(max((1 - l) / 0.15, 0), 1)
            let expected = l1 <= 0.04045 ? l1 / 12.92 : pow((l1 + 0.055) / 1.055, 2.4)
            XCTAssertEqual(got, expected, accuracy: 0.006, "level \(value)")
        }
    }

    /// A nearly blown sky (0.96) over darker ground: the curve goes to where the picture's
    /// highlights are, so the sky comes down well at −1; white stays white, and the ground stays.
    func testHighlightsReachANearlyBlownSky() throws {
        let w = 256, h = 256
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (y, level) in [(0, 245.0), (96, 255.0), (128, 100.0)] {
            let v = level / 255
            ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h - y - (y == 96 ? 32 : y == 0 ? 96 : 128), width: w, height: y == 96 ? 32 : y == 0 ? 96 : 128))
        }
        let image = ctx.makeImage()!
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(image))
        XCTAssertGreaterThan(src.highlights, 0.95)
        var a = Adjustments()
        a.highlights = -1
        let before = linear(image), after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
        func at(_ p: [Float], _ y: Int) -> Float { p[(y * w + w / 2) * 4 + 1] }
        XCTAssertLessThan(LightEngine.encode(at(after, 48)), LightEngine.encode(at(before, 48)) - 0.08, "the sky comes down")
        XCTAssertGreaterThan(at(after, 112), 0.97, "white stays white")
        XCTAssertEqual(at(after, 200), at(before, 200), accuracy: 0.01, "the ground stays")
    }

    func testDisplayOutputIsEightBitDisplayP3() throws {
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(ramp()))
        let out = try XCTUnwrap(engine.render(src, Adjustments(), output: .display)).image
        XCTAssertEqual(out.bitsPerComponent, 8)
        XCTAssertEqual(out.colorSpace?.name, CGColorSpace.displayP3)
        // One 8-bit step of dither either way.
        XCTAssertLessThan(maxDifference(linear(out), linear(ramp())), 0.015)
    }
}
