import CoreGraphics
import XCTest
@testable import PicttyCore

final class EnlargeTests: XCTestCase {
    func testRefusesOverEightMegapixels() {
        XCTAssertNil(EnlargeRule.refusal(pixelSize: CGSize(width: 3264, height: 2448), isHDR: false), "an 8 MP camera picture is allowed")
        XCTAssertEqual(EnlargeRule.refusal(pixelSize: CGSize(width: 3500, height: 2450), isHDR: false), .tooLarge)
        XCTAssertEqual(EnlargeRule.refusal(pixelSize: CGSize(width: 1000, height: 1000), isHDR: true), .hdr)
    }

    func testOutputSize() {
        XCTAssertEqual(EnlargeRule.outputSize(CGSize(width: 1500, height: 1000), factor: 4), CGSize(width: 6000, height: 4000))
        XCTAssertEqual(EnlargeRule.outputSize(CGSize(width: 1001, height: 777), factor: 2), CGSize(width: 2002, height: 1554))
    }

    func testTilesCoverEveryPixelOnce() {
        for (w, h) in [(1001, 777), (300, 200), (1024, 512)] {
            let tiles = EnlargeRule.tiles(width: w, height: h, tile: 512, margin: 32)
            var covered = [Int](repeating: 0, count: w * h)
            for t in tiles {
                XCTAssertEqual(t.source.size, CGSize(width: 576, height: 576), "every tile is the model's size")
                XCTAssertEqual(t.source.origin, CGPoint(x: t.keep.minX - 32, y: t.keep.minY - 32))
                XCTAssertLessThanOrEqual(t.keep.width, 512)
                for y in Int(t.keep.minY)..<Int(t.keep.maxY) { for x in Int(t.keep.minX)..<Int(t.keep.maxX) { covered[y * w + x] += 1 } }
            }
            XCTAssertTrue(covered.allSatisfy { $0 == 1 }, "\(w)×\(h): every pixel written exactly once")
        }
        XCTAssertEqual(EnlargeRule.tiles(width: 300, height: 200, tile: 512, margin: 32).count, 1)
    }

    func testFaceWeights() {
        XCTAssertTrue(EnlargeRule.faceWeights(faces: [], width: 10, height: 10).allSatisfy { $0 == 1 })
        let w = EnlargeRule.faceWeights(faces: [CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)], width: 100, height: 100)
        XCTAssertEqual(w.count, 100 * 100)
        XCTAssertEqual(w[50 * 100 + 50], 0, accuracy: 1e-6, "the face's centre is plain")
        XCTAssertEqual(w[0], 1, accuracy: 1e-6, "far from the face, the network's")
        var last: Float = -1
        for k in 0..<50 {  // from the centre to the top-left corner
            let v = w[(50 - k) * 100 + (50 - k)]
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
    }

    func testFaceWeightsFollowVisionCoordinates() {
        // Vision's origin is bottom-left: a face near y = 0 is at the bottom rows.
        let w = EnlargeRule.faceWeights(faces: [CGRect(x: 0.4, y: 0.0, width: 0.2, height: 0.2)], width: 100, height: 100)
        XCTAssertEqual(w[95 * 100 + 50], 0, accuracy: 1e-6)
        XCTAssertEqual(w[5 * 100 + 50], 1, accuracy: 1e-6)
    }

    func testWorkingSpaceKeepsTheGamut() {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!, p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        XCTAssertEqual(EnlargeRule.workingSpace(for: srgb).name, CGColorSpace.sRGB)
        XCTAssertEqual(EnlargeRule.workingSpace(for: p3).name, CGColorSpace.displayP3)
        // The save render's linear extended sRGB holds P3 colours past 0…1: P3, encoded, keeps them.
        XCTAssertEqual(EnlargeRule.workingSpace(for: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!).name, CGColorSpace.displayP3)
        XCTAssertEqual(EnlargeRule.workingSpace(for: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!).name, CGColorSpace.sRGB)
        XCTAssertEqual(EnlargeRule.workingSpace(for: nil).name, CGColorSpace.sRGB)
    }

    func testBleedFillsTransparentPixelsFromTheirNeighbours() {
        // A 9×9 picture: one opaque red pixel in the middle, the rest transparent (black underneath).
        let w = 9, h = 9
        var r = [Float](repeating: 0, count: w * h), g = r, b = r, a = r
        r[4 * w + 4] = 1; a[4 * w + 4] = 1
        a[4 * w + 5] = 0.5; g[4 * w + 5] = 1  // a half-transparent green edge pixel keeps its colour
        EnlargeRule.bleed(&r, &g, &b, alpha: a, width: w, height: h)
        XCTAssertEqual(r[4 * w + 4], 1, "opaque pixels are untouched")
        XCTAssertEqual(g[4 * w + 5], 1, "partly transparent pixels keep their own colour")
        XCTAssertGreaterThan(r[0], 0.3, "a far transparent corner takes the colour around it, not black")
        XCTAssertGreaterThan(r[4 * w + 3], 0.5)
    }
}
