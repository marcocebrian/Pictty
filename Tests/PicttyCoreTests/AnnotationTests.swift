import CoreGraphics
import XCTest
@testable import PicttyCore

final class AnnotationTests: XCTestCase {
    private let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    func testStepsAreNumberedInOrderAndRenumberAfterADelete() {
        var items = [Annotation(kind: .step, a: CGPoint(x: 0.1, y: 0.1)), Annotation(kind: .arrow, a: .zero, b: CGPoint(x: 1, y: 1)),
                     Annotation(kind: .step, a: CGPoint(x: 0.2, y: 0.2)), Annotation(kind: .step, a: CGPoint(x: 0.3, y: 0.3))]
        XCTAssertEqual(Annotation.stepNumbers(items), [items[0].id: 1, items[2].id: 2, items[3].id: 3])
        items.remove(at: 2)
        XCTAssertEqual(Annotation.stepNumbers(items)[items[2].id], 2, "the third step becomes the second")
    }

    func testContrastingColourStandsOutFromWhatIsUnder() {
        XCTAssertEqual(AnnotationStyle.contrasting(average: (r: 0.95, g: 0.1, b: 0.1)), AnnotationStyle.palette[3], "not red on red")
        XCTAssertNotEqual(AnnotationStyle.contrasting(average: (r: 0.1, g: 0.2, b: 0.9)), AnnotationStyle.palette[3], "not blue on blue")
        XCTAssertEqual(AnnotationStyle.contrasting(average: (r: 0.5, g: 0.5, b: 0.5)), AnnotationStyle.palette[0], "red on grey")
    }

    func testMappingThroughACropAndHitTests() {
        let crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)  // the right half
        let size = CGSize(width: 1000, height: 2000)
        // A point at x = 0.75 of the whole picture is the middle of the cropped one.
        XCTAssertEqual(AnnotationSpace(crop: crop, size: size).pixel(CGPoint(x: 0.75, y: 0.5)), CGPoint(x: 500, y: 1000))
        XCTAssertEqual(AnnotationSpace(crop: crop, size: size).unit(CGPoint(x: 500, y: 1000)), CGPoint(x: 0.75, y: 0.5))
        let space = AnnotationSpace(crop: whole, size: CGSize(width: 1000, height: 1000))
        let box = Annotation(kind: .rectangle, a: CGPoint(x: 0.2, y: 0.2), b: CGPoint(x: 0.6, y: 0.6))
        XCTAssertTrue(box.hit(CGPoint(x: 200, y: 400), in: space), "on the outline")
        XCTAssertFalse(box.hit(CGPoint(x: 400, y: 400), in: space), "inside an outline is not the shape")
        var filled = box; filled.style.filled = true
        XCTAssertTrue(filled.hit(CGPoint(x: 400, y: 400), in: space))
        let arrow = Annotation(kind: .arrow, a: CGPoint(x: 0.1, y: 0.1), b: CGPoint(x: 0.9, y: 0.1))
        XCTAssertTrue(arrow.hit(CGPoint(x: 500, y: 104), in: space))
        XCTAssertFalse(arrow.hit(CGPoint(x: 500, y: 300), in: space))
    }

    // MARK: Rendering

    private func grey(_ w: Int, _ h: Int, stripes: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if stripes {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            for x in stride(from: 0, to: w, by: 4) { ctx.fill(CGRect(x: x, y: 0, width: 2, height: h)) }
        }
        return ctx.makeImage()!
    }

    /// RGB 0…255 at (x, y), top-left origin.
    private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let w = image.width, h = image.height
        var p = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4
        return [Int(p[i]), Int(p[i + 1]), Int(p[i + 2])]
    }

    func testArrowMarksItsLineOnly() throws {
        var arrow = Annotation(kind: .arrow, a: CGPoint(x: 0.1, y: 0.5), b: CGPoint(x: 0.9, y: 0.5))
        arrow.style.colour = AnnotationStyle.palette[0]
        arrow.style.shadow = false
        let out = try XCTUnwrap(AnnotationRenderer.render([arrow], over: grey(1000, 400), crop: whole))
        XCTAssertEqual(out.width, 1000); XCTAssertEqual(out.height, 400)
        XCTAssertGreaterThan(rgb(out, 500, 200)[0], 200, "red on the line")
        XCTAssertLessThan(rgb(out, 500, 200)[1], 120)
        XCTAssertEqual(rgb(out, 500, 40), [128, 128, 128], "untouched away from it")
    }

    func testBlurChangesOnlyItsRect() throws {
        let base = grey(200, 100, stripes: true)
        let blur = Annotation(kind: .blur, a: CGPoint(x: 0, y: 0), b: CGPoint(x: 0.5, y: 1))
        let out = try XCTUnwrap(AnnotationRenderer.render([blur], over: base, crop: whole))
        let inside = (40..<48).map { rgb(out, $0, 50)[0] }
        XCTAssertLessThan(inside.max()! - inside.min()!, 60, "stripes smoothed inside")
        XCTAssertEqual(rgb(out, 150, 50), rgb(base, 150, 50), "outside unchanged")
        XCTAssertEqual(rgb(out, 151, 50), rgb(base, 151, 50))
    }

    func testSolidCensorIsBlackAndSpotlightDarkensOutside() throws {
        var bar = Annotation(kind: .censor, a: CGPoint(x: 0.1, y: 0.1), b: CGPoint(x: 0.4, y: 0.9))
        bar.solid = true
        let censored = try XCTUnwrap(AnnotationRenderer.render([bar], over: grey(200, 100), crop: whole))
        XCTAssertEqual(rgb(censored, 50, 50), [0, 0, 0])
        let spot = Annotation(kind: .spotlight, a: CGPoint(x: 0.4, y: 0.2), b: CGPoint(x: 0.6, y: 0.8))
        let lit = try XCTUnwrap(AnnotationRenderer.render([spot], over: grey(200, 100), crop: whole))
        XCTAssertEqual(rgb(lit, 100, 50), [128, 128, 128], "inside the spotlight unchanged")
        XCTAssertLessThan(rgb(lit, 10, 10)[0], 90, "outside dimmed")
    }
}
