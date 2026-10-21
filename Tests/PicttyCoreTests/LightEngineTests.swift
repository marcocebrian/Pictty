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

    func testNeutralIsTheIdentityWithEveryAlgorithm() throws {
        let engine = try XCTUnwrap(LightEngine())
        let image = ramp()
        let src = try XCTUnwrap(engine.source(image))
        for n in 1...3 {
            var a = Adjustments()
            a.exposureAlgorithm = n
            a.highlightsAlgorithm = n
            a.shadowsAlgorithm = n
            let out = try XCTUnwrap(engine.render(src, a, output: .linear)).image
            XCTAssertLessThan(maxDifference(linear(out), linear(image)), 0.002, "algorithm \(n)")
        }
    }

    func testLinearExposureDoublesTheLight() throws {
        let engine = try XCTUnwrap(LightEngine())
        let image = flat(60)
        let src = try XCTUnwrap(engine.source(image))
        var a = Adjustments()
        a.exposure = 1
        let before = linear(image)[0], after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)[0]
        XCTAssertEqual(after, before * 2, accuracy: 0.002)
    }

    func testTheShouldersNeverPassWhite() throws {
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(ramp()))
        for n in [2, 3] {
            var a = Adjustments()
            a.exposure = 2
            a.exposureAlgorithm = n
            let px = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
            XCTAssertLessThanOrEqual(px.max() ?? 0, 1.0005, "algorithm \(n)")
            // Monotonic along the ramp's top row.
            let row = stride(from: 0, to: 256 * 4, by: 4).map { px[$0 + 1] }
            XCTAssertTrue(zip(row, row.dropFirst()).allSatisfy { $0 <= $1 + 1e-4 }, "algorithm \(n)")
        }
    }

    /// Linear exposure clips at white; the shoulders keep what is brighter than mid-grey apart.
    func testLinearExposureClipsAndTheShouldersDoNot() throws {
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(ramp()))
        func row(_ n: Int) throws -> [Float] {
            var a = Adjustments()
            a.exposure = 2
            a.exposureAlgorithm = n
            let px = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
            return stride(from: 0, to: 256 * 4, by: 4).map { px[$0 + 1] }
        }
        let clipped = try row(1), shoulder = try row(2), film = try row(3)
        XCTAssertEqual(clipped[150], clipped[255], accuracy: 1e-4)
        XCTAssertLessThan(shoulder[150], shoulder[255] - 0.01)
        XCTAssertLessThan(film[150], film[255] - 0.01)
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
            a.exposureAlgorithm = 4
            let after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)[0]
            let before = linear(image)[0]
            if value == 30 { XCTAssertEqual(after / before, 4, accuracy: 0.1, "dark: all the stops") }
            if value == 200 { XCTAssertLessThan(after / before, 1.2, "lit: almost none") }
            levels.append(after)
        }
        XCTAssertEqual(levels, levels.sorted(), "brighter stays brighter")
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

    /// On a flat picture there is no detail to keep: the local methods must land exactly where
    /// the global curve does.
    func testLocalMethodsAgreeWithTheCurveOnAFlatPicture() throws {
        let engine = try XCTUnwrap(LightEngine())
        for value: UInt8 in [40, 200] {
            let src = try XCTUnwrap(engine.source(flat(value)))
            var results: [Float] = []
            for n in 1...3 {
                var a = Adjustments()
                a.highlights = -0.8; a.shadows = 0.7
                a.highlightsAlgorithm = n; a.shadowsAlgorithm = n
                results.append(linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)[64 * 128 * 4 + 256])
            }
            XCTAssertEqual(results[1], results[0], accuracy: 0.004, "guided, level \(value)")
            XCTAssertEqual(results[2], results[0], accuracy: 0.006, "Laplacian, level \(value)")
            XCTAssertNotEqual(results[0], linear(flat(value))[0], accuracy: 0.002, "the sliders did something at \(value)")
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
