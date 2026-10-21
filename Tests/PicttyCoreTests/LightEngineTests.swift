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
            var a = LightAdjustments()
            for c in LightControl.allCases { c.setAlgorithm(n, in: &a) }
            let out = try XCTUnwrap(engine.render(src, a, output: .linear)).image
            XCTAssertLessThan(maxDifference(linear(out), linear(image)), 0.002, "algorithm \(n)")
        }
    }

    func testLinearExposureDoublesTheLight() throws {
        let engine = try XCTUnwrap(LightEngine())
        let image = flat(60)
        let src = try XCTUnwrap(engine.source(image))
        var a = LightAdjustments()
        a.exposure = 1
        let before = linear(image)[0], after = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)[0]
        XCTAssertEqual(after, before * 2, accuracy: 0.002)
    }

    func testShouldersNeverPassWhite() throws {
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(ramp()))
        for n in 2...3 {
            var a = LightAdjustments()
            a.exposure = 2
            a.exposureAlgorithm = n
            let px = linear(try XCTUnwrap(engine.render(src, a, output: .linear)).image)
            XCTAssertLessThanOrEqual(px.max() ?? 0, 1.0005, "algorithm \(n)")
            // Monotonic along the ramp's top row.
            let row = stride(from: 0, to: 256 * 4, by: 4).map { px[$0 + 1] }
            XCTAssertTrue(zip(row, row.dropFirst()).allSatisfy { $0 <= $1 + 1e-4 }, "algorithm \(n)")
        }
    }

    /// On a flat picture there is no detail to keep: the local methods must land exactly where
    /// the global curve does.
    func testLocalMethodsAgreeWithTheCurveOnAFlatPicture() throws {
        let engine = try XCTUnwrap(LightEngine())
        for value: UInt8 in [40, 200] {
            let src = try XCTUnwrap(engine.source(flat(value)))
            var results: [Float] = []
            for n in 1...3 {
                var a = LightAdjustments()
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
        let out = try XCTUnwrap(engine.render(src, LightAdjustments(), output: .display)).image
        XCTAssertEqual(out.bitsPerComponent, 8)
        XCTAssertEqual(out.colorSpace?.name, CGColorSpace.displayP3)
        // One 8-bit step of dither either way.
        XCTAssertLessThan(maxDifference(linear(out), linear(ramp())), 0.015)
    }
}
