import CoreGraphics
@testable import PicttyCore
import XCTest

final class SensorDevelopTests: XCTestCase {
    /// The stabilising transform and its inverse agree, at every level and noise.
    func testTransformRoundTrips() {
        for (a, b) in [(Float(0.002), Float(1e-6)), (0.0001, 1e-8), (0, 0), (0.02, 1e-4)] {
            let v = SensorDevelop.Vst(a: a, b: b)
            for x in stride(from: Float(0), through: 1.6, by: 0.05) {
                XCTAssertEqual(v.inverse(v.forward(x)), x, accuracy: 1e-4)
            }
        }
    }

    /// A flat mosaic with known shot and read noise measures as that line.
    func testNoiseIsMeasuredFromTheMosaic() {
        let w = 512, h = 512, a: Float = 0.001, b: Float = 2e-6
        var rng = SystemRandomNumberGenerator()
        func gauss() -> Float {
            let u = Float.random(in: 1e-7..<1, using: &rng), v = Float.random(in: 0..<1, using: &rng)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        // Flat patches at many levels, so the line has bins to go through.
        var samples = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let level = Float((x / 32 + (y / 32) * 16) % 40 + 1) / 50
                samples[y * w + x] = level + gauss() * (a * level + b).squareRoot()
            }
        }
        let m = SensorDevelop.Mosaic(samples: samples, width: w, height: h, dx: 0, dy: 0, gains: SIMD3(1, 1, 1),
                                     camToSRGB: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)], flip: 0, saturation: 0.98)
        let model = SensorDevelop.estimateNoise(m)
        for c in 0..<3 {
            XCTAssertEqual(model.a[c], a, accuracy: a * 0.25, "shot noise, channel \(c)")
        }
    }

    /// A picture that is not a RAW is refused, so the caller develops it with Apple's engine.
    func testANonRawIsRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-raw.txt")
        try Data("hello".utf8).write(to: url)
        XCTAssertThrowsError(try SensorDevelop.develop(url, model: URL(fileURLWithPath: "/nonexistent.mlmodelc")))
    }

    /// The tone match keeps order and carries the light past white along with it.
    func testLookMatchKeepsOrderAndHeadroom() throws {
        func ramp(_ f: (Float) -> Float) -> CGImage {
            var px = [Float16](repeating: 1, count: 256 * 16 * 4)
            for y in 0..<16 { for x in 0..<256 { let v = Float16(f(Float(x) / 200)); for c in 0..<3 { px[(y * 256 + x) * 4 + c] = v } } }
            return LookMatch.image(px, 256, 16)!
        }
        let ours = ramp { $0 }, theirs = ramp { 1.6 * $0.squareRoot() * 0.5 }
        let look = try XCTUnwrap(LookMatch.fit(ours, to: theirs, side: 256))
        var last: Float = 0
        for y in stride(from: Float(0.01), through: 1.27, by: 0.01) {
            let out = y * look.gain(y)
            XCTAssertGreaterThanOrEqual(out, last, "order kept at \(y)")
            last = out
        }
        XCTAssertGreaterThan(1.27 * look.gain(1.27), 1.0 * look.gain(1.0), "past white stays above white")
    }

    /// The sensor develop's detail always; its light in the dark, Apple's in the bright, and
    /// Apple's pixels where the sensor clipped.
    func testDetailTransferKeepsOurDarksAndTakesApplesHighlights() throws {
        func run(_ ours: Float, _ theirs: Float, clippedFrom: Int = 64) throws -> [Float16] {
            let w = 64, h = 32
            var apple = [Float16](repeating: 1, count: w * h * 4), sensor = apple
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    for c in 0..<3 {
                        apple[i + c] = Float16(theirs)
                        sensor[i + c] = Float16(ours * (1 + 0.2 * (x % 2 == 0 ? 1 : -1)))
                    }
                }
            }
            var clipped = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in clippedFrom..<w { clipped[y * w + x] = 1 } }
            return try XCTUnwrap(LookMatch.halfFloats(try XCTUnwrap(DetailTransfer.apply(
                apple: try XCTUnwrap(LookMatch.image(apple, w, h)), sensor: try XCTUnwrap(LookMatch.image(sensor, w, h)),
                clipped: clipped))))
        }
        let w = 64
        func v(_ p: [Float16], _ x: Int) -> Float { Float(p[(16 * w + x) * 4]) }
        let dark = try run(0.1, 0.2)
        XCTAssertEqual((v(dark, 20) + v(dark, 21)) / 2, 0.1, accuracy: 0.005, "dark: our light")
        XCTAssertEqual(v(dark, 20) / v(dark, 21), 1.2 / 0.8, accuracy: 0.05, "our detail")
        let bright = try run(1.2, 1.6)
        XCTAssertEqual((v(bright, 20) + v(bright, 21)) / 2, 1.6, accuracy: 0.03, "bright: Apple's light")
        XCTAssertEqual(v(bright, 20) / v(bright, 21), 1.2 / 0.8, accuracy: 0.05, "still our detail")
        let clipped = try run(0.1, 0.9, clippedFrom: 40)
        XCTAssertEqual(v(clipped, 60), 0.9, accuracy: 1e-3, "clipped: Apple's pixel")
    }
}
