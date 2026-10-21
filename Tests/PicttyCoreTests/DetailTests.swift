import CoreGraphics
@testable import PicttyCore
import XCTest

final class DetailTests: XCTestCase {
    /// An 8-bit sRGB grey picture drawn from encoded values, row-major.
    private func picture(_ w: Int, _ h: Int, _ value: (Int, Int) -> Double) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let v = UInt8(max(0, min(255, (value(x, y) * 255).rounded())))
                let i = (y * w + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    /// Gaussian noise, the same every run.
    private struct Noise {
        var state: UInt64 = 0x9E3779B97F4A7C15
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u = max(uniform(), 1e-12), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// A vertical edge from 0.25 to 0.75, blurred with a Gaussian of `sigma` pixels.
    private func edge(sigma: Double, w: Int = 256, h: Int = 64) -> CGImage {
        picture(w, h) { x, _ in
            let t = (Double(x) - Double(w) / 2) / (sigma * 2.0.squareRoot())
            return 0.25 + 0.5 * 0.5 * (1 + erf(t))
        }
    }

    private func encodedRow(_ image: CGImage, y: Int) -> [Double] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<image.width).map { Double(px[(y * image.width + $0) * 4 + 1]) / 255 }
    }

    func testNoiseIsMeasured() throws {
        var n = Noise()
        let image = picture(400, 300) { _, _ in 0.5 + 0.02 * n.gaussian() }
        let src = try XCTUnwrap(LightEngine()?.source(image))
        XCTAssertEqual(src.noise, 0.02, accuracy: 0.006)
        let clean = try XCTUnwrap(LightEngine()?.source(picture(400, 300) { x, _ in Double(x) / 400 }))
        XCTAssertLessThan(clean.noise, 0.004)
    }

    func testBlurIsMeasured() throws {
        // Many edges, so the median has something to choose from.
        for sigma in [0.7, 1.5, 2.5] {
            let image = picture(512, 256) { x, _ in
                let period = 32.0, u = Double(x).truncatingRemainder(dividingBy: period) - period / 2
                return 0.25 + 0.5 * 0.5 * (1 + erf(u / (sigma * 2.0.squareRoot())))
            }
            let src = try XCTUnwrap(LightEngine()?.source(image))
            XCTAssertEqual(Double(src.blur), sigma, accuracy: max(0.35, sigma * 0.3), "sigma \(sigma)")
        }
    }

    func testSharpeningSteepensAnEdgeWithoutOvershoot() throws {
        let engine = try XCTUnwrap(LightEngine())
        let image = edge(sigma: 1.5)
        let src = try XCTUnwrap(engine.source(image))
        var a = Adjustments()
        a.sharpening = 1
        let out = try XCTUnwrap(engine.render(src, a, output: .display)).image
        let before = encodedRow(image, y: 32), after = encodedRow(out, y: 32)
        let slope = { (r: [Double]) in (128 - 3...128 + 2).map { abs(r[$0 + 1] - r[$0]) }.max() ?? 0 }
        XCTAssertGreaterThan(slope(after), slope(before) * 1.15, "steeper")
        // No ringing: nothing beyond the edge's own ends, but for a hair.
        XCTAssertLessThan(after.max() ?? 1, (before.max() ?? 1) + 0.025)
        XCTAssertGreaterThan(after.min() ?? 0, (before.min() ?? 0) - 0.025)
    }

    func testSharpeningLeavesGrainAlone() throws {
        var n = Noise()
        let image = picture(256, 256) { _, _ in 0.45 + 0.015 * n.gaussian() }
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(image))
        var a = Adjustments()
        a.sharpening = 1
        a.texture = 1
        let out = try XCTUnwrap(engine.render(src, a, output: .display)).image
        func spread(_ img: CGImage) -> Double {
            let r = (40..<216).flatMap { encodedRow(img, y: $0)[40..<216] }
            let m = r.reduce(0, +) / Double(r.count)
            return (r.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(r.count)).squareRoot()
        }
        XCTAssertLessThan(spread(out), spread(image) * 1.15, "the grain is not amplified")
    }

    func testClarityRaisesMidScaleContrast() throws {
        // Soft bands about 40 pixels wide, in the midtones.
        let image = picture(512, 128) { x, _ in 0.5 + 0.08 * sin(Double(x) / 40 * 2 * .pi) }
        let engine = try XCTUnwrap(LightEngine())
        let src = try XCTUnwrap(engine.source(image))
        var a = Adjustments()
        a.clarity = 1
        let out = try XCTUnwrap(engine.render(src, a, output: .display)).image
        let before = encodedRow(image, y: 64)[100..<412], after = encodedRow(out, y: 64)[100..<412]
        XCTAssertGreaterThan((after.max()! - after.min()!), (before.max()! - before.min()!) * 1.1)
    }

    func testDenoiseMixesTheDenoisedPictureIn() throws {
        let engine = try XCTUnwrap(LightEngine())
        let noisy = picture(64, 64) { x, y in (x + y) % 2 == 0 ? 0.4 : 0.6 }
        let src = try XCTUnwrap(engine.source(noisy))
        engine.setDenoised(picture(64, 64) { _, _ in 0.5 }, on: src)
        var a = Adjustments()
        a.denoise = 1
        let row = encodedRow(try XCTUnwrap(engine.render(src, a, output: .display)).image, y: 10)
        XCTAssertLessThan((row.max()! - row.min()!), 0.02, "fully denoised: flat")
        a.denoise = 0.5
        let half = encodedRow(try XCTUnwrap(engine.render(src, a, output: .display)).image, y: 10)
        XCTAssertGreaterThan(half.max()! - half.min()!, 0.05, "half: some of the pattern left")
    }
}

final class GrainTests: XCTestCase {
    private struct Rand {
        var s: UInt64 = 42
        mutating func g() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let u = max(Double(s >> 11) / Double(1 << 53), 1e-12)
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let v = Double(s >> 11) / Double(1 << 53)
            return Float((-2 * log(u)).squareRoot() * cos(2 * .pi * v))
        }
    }

    private func levels(_ l: [Float], _ w: Int, _ h: Int) -> (full: Float, half: Float, quarter: Float) {
        let half = PictureMeasure.shrink(l, width: w, height: h, by: 2)
        let quarter = PictureMeasure.shrink(half.plane, width: half.width, height: half.height, by: 2)
        return (PictureMeasure.flatNoise(l, width: w, height: h),
                PictureMeasure.flatNoise(half.plane, width: half.width, height: half.height),
                PictureMeasure.flatNoise(quarter.plane, width: quarter.width, height: quarter.height))
    }

    func testFineNoiseIsFineAndCoarseGrainIsCoarse() {
        let w = 1024, h = 768
        var r = Rand()
        // Fine: independent per pixel, 3 levels.
        let fine = (0..<(w * h)).map { _ in 0.5 + 3 / 255 * r.g() }
        let f = levels(fine, w, h)
        XCTAssertEqual(f.full, 3, accuracy: 0.8)
        XCTAssertEqual(PictureMeasure.grainScales(f), [], "fine noise needs no coarse pass")
        // Coarse: noise drawn at a third of the size and enlarged, as an editor's grain is (blobs
        // of a few pixels, like the photo this was calibrated on).
        let k: Float = 3
        let gw = w / 3 + 2, gh = h / 3 + 2
        let grid = (0..<(gw * gh)).map { _ in 6 / 255 * r.g() }
        let coarse = (0..<(w * h)).map { i -> Float in
            let x = Float(i % w) / k, y = Float(i / w) / k
            let x0 = min(Int(x), gw - 2), y0 = min(Int(y), gh - 2), tx = x - Float(x0), ty = y - Float(y0)
            let v = grid[y0 * gw + x0] * (1 - tx) * (1 - ty) + grid[y0 * gw + x0 + 1] * tx * (1 - ty)
                + grid[(y0 + 1) * gw + x0] * (1 - tx) * ty + grid[(y0 + 1) * gw + x0 + 1] * tx * ty
            return 0.5 + v
        }
        let c = levels(coarse, w, h)
        XCTAssertFalse(PictureMeasure.grainScales(c).isEmpty, "coarse grain is taken out at a smaller scale: \(c)")
    }

    func testAutoLeavesCleanPicturesAlone() {
        let w = 512, h = 512
        let clean = (0..<(w * h)).map { i in Float(i % w) / Float(w) * 0.6 + 0.2 }
        XCTAssertEqual(PictureMeasure.denoiseAmount(levels(clean, w, h)), 0)
        var r = Rand()
        let noisy = (0..<(w * h)).map { _ in 0.5 + 4 / 255 * r.g() }
        XCTAssertGreaterThan(PictureMeasure.denoiseAmount(levels(noisy, w, h)), 0.6)
    }
}
