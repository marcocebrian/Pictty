@testable import PicttyCore
import XCTest

final class LensMatchTests: XCTestCase {
    /// A picture with texture everywhere (sums of soft blobs), linear half float.
    private func texture(_ w: Int, _ h: Int) -> CGImage {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float(state >> 40) / Float(1 << 24) }
        let blobs = (0..<900).map { _ in (rnd() * Float(w), rnd() * Float(h), 4 + rnd() * 10, rnd() - 0.5) }
        var px = [Float16](repeating: 1, count: w * h * 4)
        var v = [Float](repeating: 0.3, count: w * h)
        for (bx, by, r, a) in blobs {
            let x0 = max(0, Int(bx - 3 * r)), x1 = min(w - 1, Int(bx + 3 * r)), y0 = max(0, Int(by - 3 * r)), y1 = min(h - 1, Int(by + 3 * r))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 { for x in x0...x1 { let d = (Float(x) - bx) * (Float(x) - bx) + (Float(y) - by) * (Float(y) - by); v[y * w + x] += a * 0.3 * exp(-d / (2 * r * r)) } }
        }
        for i in 0..<(w * h) { let t = Float16(max(v[i], 0.01)); px[i * 4] = t; px[i * 4 + 1] = t; px[i * 4 + 2] = t }
        return LookMatch.image(px, w, h)!
    }

    /// A known barrel distortion, put on a picture, is measured back.
    func testAKnownDistortionIsMeasured() throws {
        let plain = texture(1200, 800)
        let known = LensMatch(k: [-0.03, 0, 0], scale: 1, v: [0, 0], residual: 0, points: 0)
        let corrected = try XCTUnwrap(known.apply(plain))
        let m = try XCTUnwrap(LensMatch.measure(corrected: corrected, uncorrected: plain))
        // At the corner the model's scale: what matters, not each coefficient.
        let atCorner = m.scale * (1 + m.k[0] + m.k[1] + m.k[2])
        XCTAssertEqual(atCorner, 0.97, accuracy: 0.004)
        let atHalf = m.scale * (1 + 0.25 * m.k[0] + 0.0625 * m.k[1] + 0.015625 * m.k[2])
        XCTAssertEqual(atHalf, 1 - 0.03 * 0.25, accuracy: 0.003)
    }

    /// Red and blue scaled a little apart from green (lateral colour), on top of a distortion:
    /// each channel's scale is measured back, and correcting with it lines the channels up.
    func testAKnownColourFringeIsMeasured() throws {
        let plain = texture(1600, 1060)
        let known = LensMatch(k: [-0.02, 0, 0], scale: 1, v: [0, 0], residual: 0, points: 0,
                              ca: [[0.0012, 0, 0], [0, 0, 0], [-0.0008, 0.0004, 0]])
        let corrected = try XCTUnwrap(known.apply(plain))
        let m = try XCTUnwrap(LensMatch.measure(corrected: corrected, uncorrected: plain))
        func at(_ c: Int, _ r2: Float) -> Float { m.ca[c][0] + r2 * (m.ca[c][1] + r2 * m.ca[c][2]) }
        for r2: Float in [0.25, 0.5, 0.81] {
            XCTAssertEqual(at(0, r2), 0.0012, accuracy: 0.00015, "red at r² \(r2)")
            XCTAssertEqual(at(2, r2), -0.0008 + 0.0004 * r2, accuracy: 0.00015, "blue at r² \(r2)")
            XCTAssertEqual(at(1, r2), 0, accuracy: 0.00001)
        }
        XCTAssertFalse(m.isIdentity)
    }

    /// Two identical develops (a lens Apple has no profile for): no correction.
    func testNoProfileIsNoCorrection() throws {
        let plain = texture(1200, 800)
        let m = try XCTUnwrap(LensMatch.measure(corrected: plain, uncorrected: plain))
        XCTAssertTrue(m.isIdentity, "\(m.k) \(m.scale) \(m.v)")
    }
}
