import CoreGraphics
@testable import PicttyCore
import XCTest

final class CropTests: XCTestCase {
    func testOrientRoundTrips() {
        let p = CGPoint(x: 0.2, y: 0.7)
        for turns in 0..<4 {
            for mirror in [false, true] {
                let o = Orient(quarterTurns: turns, mirror: mirror)
                let back = o.stored(o.display(p))
                XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
                XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
            }
        }
        // A clockwise turn puts the stored top-left at the top-right.
        let tl = Orient(quarterTurns: 1).display(CGPoint(x: 0, y: 0))
        XCTAssertEqual(tl, CGPoint(x: 1, y: 0))
        XCTAssertEqual(Orient(quarterTurns: 1).storedCorner(1), 0)
    }

    func testRadiiFollowTheTurn() {
        let o = Orient(quarterTurns: 1)
        let stored = [0.1, 0.2, 0.3, 0.4]
        XCTAssertEqual(o.storedRadii(o.displayRadii(stored)), stored)
        XCTAssertEqual(o.displayRadii(stored)[1], 0.1, "the stored top-left shows top-right")
    }

    private func picture() -> CGImage {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return ctx.makeImage()!
    }

    func testCropsToTheRect() throws {
        let box = CropBox(rect: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.8))
        let out = try XCTUnwrap(box.apply(to: picture()))
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 80)
    }

    func testRoundedCornersAreTransparent() throws {
        let box = CropBox(rect: CGRect(x: 0, y: 0, width: 1, height: 1), radii: [0.5, 0, 0, 0])
        let out = try XCTUnwrap(box.apply(to: picture()))
        XCTAssertTrue(ImageDecoder.hasAlpha(out))
        let data = try XCTUnwrap(out.dataProvider?.data as Data?)
        let row = out.bytesPerRow
        XCTAssertEqual(data[3], 0, "top-left corner pixel is clear")
        XCTAssertEqual(data[(out.width - 1) * 4 + 3], 255, "top-right is square, opaque")
        XCTAssertEqual(data[(out.height - 1) * row + 3], 255, "bottom-left is square, opaque")
    }
}
