import CoreGraphics
import XCTest
@testable import PicttyCore

final class BackgroundTests: XCTestCase {
    private let w = 40, h = 20

    /// Left half red, right half green: the "subject" is the left half.
    private func picture() -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        return ctx.makeImage()!
    }

    /// White on the left half (keep), black on the right (background).
    private func mask() -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        return ctx.makeImage()!
    }

    /// RGBA 0…255 at (x, y), top-left origin, unpremultiplied.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Double] {
        var p = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4, a = Double(p[i + 3])
        return a == 0 ? [0, 0, 0, 0] : [Double(p[i]) * 255 / a, Double(p[i + 1]) * 255 / a, Double(p[i + 2]) * 255 / a, a]
    }

    func testTransparentLeavesTheSubjectAndClearsTheRest() throws {
        let out = try XCTUnwrap(BackgroundComposite.apply(picture(), mask: mask(), fill: .transparent))
        XCTAssertEqual(out.width, w); XCTAssertEqual(out.height, h)
        let inside = pixel(out, 5, 10), outside = pixel(out, 35, 10)
        XCTAssertEqual(inside[0], 255, accuracy: 2); XCTAssertEqual(inside[3], 255, accuracy: 2)
        XCTAssertEqual(outside[3], 0, accuracy: 2, "the background is gone")
    }

    func testColourFillsTheBackground() throws {
        for (fill, rgb) in [(BackgroundFill.white, [255.0, 255, 255]), (.black, [0, 0, 0]), (.colour(0, 0, 1), [0, 0, 255])] {
            let out = try XCTUnwrap(BackgroundComposite.apply(picture(), mask: mask(), fill: fill))
            let outside = pixel(out, 35, 10), inside = pixel(out, 5, 10)
            for c in 0..<3 { XCTAssertEqual(outside[c], rgb[c], accuracy: 3, "\(fill)") }
            XCTAssertEqual(outside[3], 255, accuracy: 2)
            XCTAssertEqual(inside[0], 255, accuracy: 2, "the subject stays red")
        }
    }

    func testBlurredKeepsTheSubjectAndSoftensTheRest() throws {
        let out = try XCTUnwrap(BackgroundComposite.apply(picture(), mask: mask(), fill: .blurred))
        XCTAssertEqual(pixel(out, 5, 10)[0], 255, accuracy: 3, "the subject stays sharp")
        let near = pixel(out, 21, 10)
        XCTAssertGreaterThan(near[0], 10, "the red bleeds into the blurred green next to it")
        XCTAssertEqual(near[3], 255, accuracy: 2)
    }
}
