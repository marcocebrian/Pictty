import CoreGraphics
import Foundation
@testable import PicttyCore
import XCTest

final class ReducedTests: XCTestCase {
    /// The GPU-sized full made from every pixel: a GPU texture wide, the same shape, each channel
    /// where it was and nothing shifted.
    func testGPUSizedFullFromEveryPixel() throws {
        let w = 20000, h = 120
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Red on the left, blue on the right, a green band across the top quarter.
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: h * 3 / 4, width: w, height: h / 4))
        let image = try XCTUnwrap(ctx.makeImage())
        let detail = DecodedImage(url: URL(fileURLWithPath: "/x.png"), image: image, pixelSize: CGSize(width: w, height: h),
                                  isFull: true, frameCount: 1, isDetail: true)

        let full = try XCTUnwrap(ImageDecoder.reduced(detail))
        XCTAssertTrue(full.isFull)
        XCTAssertFalse(full.isDetail)
        XCTAssertEqual(full.pixelSize, detail.pixelSize)
        let rw = full.image.width, rh = full.image.height
        XCTAssertEqual(rw, ImageDecoder.maxTexture)
        XCTAssertEqual(rh, Int((Double(h) * Double(rw) / Double(w)).rounded()))

        let data = try XCTUnwrap(full.image.dataProvider?.data)
        let px = try XCTUnwrap(CFDataGetBytePtr(data))
        let row = full.image.bytesPerRow
        func rgb(_ x: Int, _ y: Int) -> [UInt8] { (0..<3).map { px[y * row + x * 4 + $0] } }
        XCTAssertEqual(rgb(rw / 4, rh * 2 / 3), [255, 0, 0])
        XCTAssertEqual(rgb(rw * 3 / 4, rh * 2 / 3), [0, 0, 255])
        XCTAssertEqual(rgb(rw / 4, rh / 16), [0, 255, 0])
        // The red-blue edge stays at the middle, within the filter's reach.
        let edge = (0..<rw).first { rgb($0, rh * 2 / 3)[2] > 128 } ?? 0
        XCTAssertEqual(edge, rw / 2, accuracy: 2)
    }

    /// Pictures that fit a GPU texture have no every-pixel decode to make one from.
    func testNothingToReduceWithinATexture() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let detail = DecodedImage(url: URL(fileURLWithPath: "/x.png"), image: try XCTUnwrap(ctx.makeImage()),
                                  pixelSize: CGSize(width: 64, height: 64), isFull: true, frameCount: 1, isDetail: true)
        XCTAssertNil(ImageDecoder.reduced(detail))
    }
}
