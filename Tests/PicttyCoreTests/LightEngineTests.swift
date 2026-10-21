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

    /// Local exposure gives a dark region all the stops and a lit one almost none, and a brighter
    /// region stays brighter.
    func testLocalExposureRaisesTheDarkAndKeepsTheLit() throws {
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
            if value == 200 { XCTAssertLessThan(after / before, 1.2, "lit: almost none") }
            levels.append(after)
        }
        XCTAssertEqual(levels, levels.sorted(), "brighter stays brighter")
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
    /// expects of a clear scene) under an even haze, and the distance, which is all haze: Dehaze
    /// brings it much closer to the clear scene, and lowered, it adds haze.
    func testDehazeTakesOutHaze() throws {
        let w = 120, h = 80
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let air = SIMD3<Double>(0.8, 0.82, 0.86), t = 0.55
        let colours: [SIMD3<Double>] = [SIMD3(0.6, 0.05, 0.02), SIMD3(0.02, 0.4, 0.05), SIMD3(0.03, 0.08, 0.5),
                                        SIMD3(0.5, 0.4, 0.01), SIMD3(0.01, 0.3, 0.35), SIMD3(0.4, 0.02, 0.3)]
        func scene(_ haze: Bool) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            for (i, j) in colours.enumerated() {
                // The last patch is the distance: haze only, whatever the scene.
                let c = i == colours.count - 1 ? air : haze ? j * t + air * (1 - t) : j
                ctx.setFillColor(CGColor(colorSpace: space, components: [c.x, c.y, c.z, 1])!)
                ctx.fill(CGRect(x: (i % 3) * 40, y: (i / 3) * 40, width: 40, height: 40))
            }
            return ctx.makeImage()!
        }
        let clear = linear(scene(false)), hazy = scene(true)
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(hazy))
        XCTAssertEqual(Double(src.airlight.z), air.z, accuracy: 0.03, "the haze's light, read in the distance")
        func error(_ p: [Float]) -> Float {
            // Away from the patches' borders, where the guided filter blends.
            var e: Float = 0, n: Float = 0
            for y in stride(from: 20, to: h, by: 40) {
                for x in stride(from: 20, to: w, by: 40) where !(x == 100 && y == 60) {
                    for c in 0..<3 { e += abs(p[(y * w + x) * 4 + c] - clear[(y * w + x) * 4 + c]); n += 1 }
                }
            }
            return e / n
        }
        var a = Adjustments()
        a.dehaze = 1
        let before = error(linear(hazy)), after = error(linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image))
        XCTAssertLessThan(after, before * 0.4, "most of the haze is out")
        a.dehaze = -1
        XCTAssertGreaterThan(error(linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)), before * 1.2, "more haze")
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

    /// By regions, vibrance raises a grey picture's colour noise far less than per pixel, which
    /// takes each speck for a muted colour and raises it most.
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
        func spread(_ algorithm: Int?) throws -> Float {
            var a = Adjustments()
            if let algorithm { a.vibrance = 1; a.saturationAlgorithm = algorithm }
            let p = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
            var sum: Float = 0
            for i in 0..<(w * h) { sum += abs(p[i * 4] - p[i * 4 + 1]) + abs(p[i * 4 + 2] - p[i * 4 + 1]) }
            return sum / Float(w * h)
        }
        let before = try spread(nil), perPixel = try spread(1), byRegions = try spread(2)
        XCTAssertGreaterThan(perPixel, before * 1.8)
        XCTAssertLessThan(byRegions, before * 1.5)
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
            // The curve, as the kernels have it: −0.32·h·smoothstep(0.4, 1, l) on encoded brightness.
            let l = Float(value) / 255, t = min(max((l - 0.4) / 0.6, 0), 1)
            let l1 = l + -0.8 * 0.32 * t * t * (3 - 2 * t)
            let expected = l1 <= 0.04045 ? l1 / 12.92 : pow((l1 + 0.055) / 1.055, 2.4)
            XCTAssertEqual(got, expected, accuracy: 0.006, "level \(value)")
        }
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
