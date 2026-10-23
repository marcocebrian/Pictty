import CoreGraphics
@testable import PicttyCore
import XCTest

final class PrintLayoutTests: XCTestCase {
    // A4 in points, with a quarter-inch margin all round.
    let a4 = CGSize(width: 595, height: 842)
    var a4Printable: CGRect { CGRect(x: 18, y: 18, width: 559, height: 806) }

    func testPhotoSizesTurnWithThePicture() {
        let size = PhotoSize(10, 15, .cm)
        let wide = PrintLayout.box(for: .photo(size), picture: CGSize(width: 6000, height: 4000), printable: a4Printable)
        XCTAssertEqual(wide.width, 15 * 72 / 2.54, accuracy: 0.01)
        XCTAssertEqual(wide.height, 10 * 72 / 2.54, accuracy: 0.01)
        let tall = PrintLayout.box(for: .photo(size), picture: CGSize(width: 4000, height: 6000), printable: a4Printable)
        XCTAssertEqual(tall.width, wide.height, accuracy: 0.01)
        XCTAssertEqual(size.label, "10 × 15 cm")
        XCTAssertEqual(PhotoSize(3.5, 5, .inch).label, "3.5 × 5 in")
    }

    func testFitPageKeepsTheWholePictureInsideThePrintableArea() {
        let picture = CGSize(width: 6000, height: 4000)
        let box = PrintLayout.box(for: .fitPage, picture: picture, printable: a4Printable)
        XCTAssertEqual(box.width, 559, accuracy: 0.01)
        XCTAssertEqual(box.height, 559 * 4000 / 6000, accuracy: 0.01)
        let layout = PrintLayout(paper: a4, printable: a4Printable, picture: picture, box: box, fill: false)
        XCTAssertEqual(layout.frame.midX, a4Printable.midX, accuracy: 0.01)
        XCTAssertEqual(layout.visiblePixels.width, 6000, accuracy: 0.5)
        // 6000 pixels over 559 points (7.76 in).
        XCTAssertEqual(layout.ppi, 6000 / (559.0 / 72), accuracy: 0.5)
    }

    func testFillCropsAndTheAnchorChoosesWhatShows() {
        let picture = CGSize(width: 6000, height: 4000)
        // A square frame: a 4000 × 4000 part of the picture shows.
        var layout = PrintLayout(paper: a4, printable: a4Printable, picture: picture, box: CGSize(width: 288, height: 288), fill: true)
        XCTAssertEqual(layout.visiblePixels.width, 4000, accuracy: 0.5)
        XCTAssertEqual(layout.visiblePixels.minX, 1000, accuracy: 0.5)
        layout.anchor = CGPoint(x: 0, y: 0.5)
        XCTAssertEqual(layout.visiblePixels.minX, 0, accuracy: 0.5)
        layout.anchor = CGPoint(x: 1, y: 0.5)
        XCTAssertEqual(layout.visiblePixels.maxX, 6000, accuracy: 0.5)
        // 4000 pixels over 4 inches.
        XCTAssertEqual(layout.ppi, 1000, accuracy: 0.5)
        // Fitted instead, the whole width shows, letterboxed.
        layout.fill = false
        XCTAssertEqual(layout.visiblePixels.width, 6000, accuracy: 0.5)
        XCTAssertEqual(layout.printedRect.height, 192, accuracy: 0.01)
    }

    func testClampKeepsTheFrameOnThePaper() {
        let layout = PrintLayout(paper: a4, printable: a4Printable, picture: CGSize(width: 100, height: 100),
                                 box: CGSize(width: 100, height: 100), fill: true)
        let c = layout.clamped(CGPoint(x: -500, y: 2000))
        XCTAssertEqual(c.x, 18 + 50)
        XCTAssertEqual(c.y, 18 + 806 - 50)
        // Wider than the printable area but not the paper: kept on the paper.
        let wide = PrintLayout(paper: a4, printable: a4Printable, picture: CGSize(width: 100, height: 100),
                               box: CGSize(width: 580, height: 100), fill: true)
        XCTAssertEqual(wide.clamped(CGPoint(x: 0, y: 400)).x, 290)
        // Larger than the paper: centred on the printable area.
        let huge = PrintLayout(paper: a4, printable: a4Printable, picture: CGSize(width: 100, height: 100),
                               box: CGSize(width: 900, height: 100), fill: true)
        XCTAssertEqual(huge.clamped(CGPoint(x: 0, y: 400)).x, a4Printable.midX)
    }

    func testSnapsToTheCentreAndTheMargins() {
        let layout = PrintLayout(paper: a4, printable: a4Printable, picture: CGSize(width: 100, height: 100),
                                 box: CGSize(width: 100, height: 100), fill: true)
        let near = layout.snapped(CGPoint(x: a4Printable.midX + 3, y: 300), tolerance: 4)
        XCTAssertEqual(near.center.x, a4Printable.midX)
        XCTAssertEqual(near.guides.vertical, [a4Printable.midX])
        XCTAssertEqual(near.guides.horizontal, [])
        let edge = layout.snapped(CGPoint(x: 200, y: 18 + 50 + 2), tolerance: 4)
        XCTAssertEqual(edge.center.y, 68)
        XCTAssertEqual(edge.guides.horizontal, [18])
        let free = layout.snapped(CGPoint(x: 200, y: 300), tolerance: 4)
        XCTAssertEqual(free.center, CGPoint(x: 200, y: 300))
    }

    func testResizeHoldsTheOppositeCorner() {
        let layout = PrintLayout(paper: a4, printable: a4Printable, picture: CGSize(width: 100, height: 100),
                                 box: CGSize(width: 100, height: 100), center: CGPoint(x: 200, y: 300), fill: true)
        // Dragging the bottom-right corner: the top-left stays at (150, 250).
        let bigger = layout.resized(to: CGSize(width: 140, height: 140), holding: 2)
        XCTAssertEqual(bigger.frame.minX, 150)
        XCTAssertEqual(bigger.frame.minY, 250)
        // Dragging the top-left: the bottom-right stays at (250, 350).
        let smaller = layout.resized(to: CGSize(width: 60, height: 60), holding: 0)
        XCTAssertEqual(smaller.frame.maxX, 250)
        XCTAssertEqual(smaller.frame.maxY, 350)
    }

    func testPaperTurnsAndItsMarginsGoWithIt() {
        XCTAssertEqual(PrintLayout.orient(a4, landscape: true), CGSize(width: 842, height: 595))
        XCTAssertEqual(PrintLayout.orient(a4, landscape: false), a4)
        // Margins 10 left, 20 top, 30 right, 40 bottom; turned, top becomes left.
        let r = CGRect(x: 10, y: 20, width: 595 - 40, height: 842 - 60)
        let turned = PrintLayout.printable(r, of: a4, turned: CGSize(width: 842, height: 595))
        XCTAssertEqual(turned.minX, 20)
        XCTAssertEqual(turned.minY, 30)
        XCTAssertEqual(turned.width, 842 - 60)
        XCTAssertEqual(turned.height, 595 - 40)
    }

    func testQualityFollowsTheViewingDistance() {
        // A 10 × 15 cm print is held at reading distance: about 290 ppi is all the eye resolves.
        let small = PrintQuality(ppi: 300, printed: PhotoSize(10, 15, .cm).points)
        XCTAssertEqual(small.viewingDistance, 300)
        XCTAssertEqual(small.neededPPI, 291, accuracy: 1)
        XCTAssertEqual(small.rating, .excellent)
        // A 40 × 60 cm poster is seen from its diagonal, 72 cm: 150 ppi is plenty.
        let poster = PrintQuality(ppi: 150, printed: PhotoSize(40, 60, .cm).points)
        XCTAssertEqual(poster.viewingDistance, 721, accuracy: 1)
        XCTAssertEqual(poster.rating, .excellent)
        XCTAssertTrue(poster.upscaleRecommended, "the printer would still enlarge it, less finely")
        XCTAssertEqual(PrintQuality(ppi: 120, printed: PhotoSize(10, 15, .cm).points).rating, .soft)
        XCTAssertEqual(PrintQuality(ppi: 60, printed: PhotoSize(10, 15, .cm).points).rating, .pixelated)
        XCTAssertFalse(PrintQuality(ppi: 260, printed: PhotoSize(10, 15, .cm).points).upscaleRecommended)
        // Upscaled from 120 to 300 ppi: better than 120, short of a true 300.
        let up = PrintQuality.upscaled(ppi: 120, sent: 300, printed: PhotoSize(10, 15, .cm).points)
        XCTAssertEqual(up.ppi, 180)
        XCTAssertEqual(up.rating, .good)
        XCTAssertEqual(PrintQuality.upscaled(ppi: 250, sent: 300, printed: PhotoSize(10, 15, .cm).points).ppi, 300)
    }

    func testResolutionSentToThePrinter() {
        let printed = PhotoSize(20, 30, .cm).points
        // 150 ppi, upscaling on: doubled to 300.
        let up = PrintResolution.target(visible: CGSize(width: 1772, height: 1181), printed: printed, ppi: 150, upscale: true)
        XCTAssertEqual(up?.width, 3544)
        // Upscaling off: as it is.
        XCTAssertNil(PrintResolution.target(visible: CGSize(width: 1772, height: 1181), printed: printed, ppi: 150, upscale: false))
        // Far more than a printer uses: brought down to 600 ppi.
        let down = PrintResolution.target(visible: CGSize(width: 12000, height: 8000), printed: printed, ppi: 1016, upscale: false)
        XCTAssertEqual(down!.width, (12000 * 600 / 1016.0).rounded())
        // Already at the printer's resolution: nothing to do.
        XCTAssertNil(PrintResolution.target(visible: CGSize(width: 3543, height: 2362), printed: printed, ppi: 299.5, upscale: true))
        // A huge print stays within the pixel budget.
        let wall = CGSize(width: 100 * 72 / 2.54, height: 150 * 72 / 2.54)
        let wallPPI = 6000 / Double(wall.width / 72)
        let big = PrintResolution.target(visible: CGSize(width: 6000, height: 4000), printed: wall, ppi: wallPPI, upscale: true)!
        XCTAssertLessThanOrEqual(Double(big.width * big.height), PrintResolution.maxPixels * 1.01)
    }

    func testLargestSharpSize() {
        let s = PrintResolution.largestSize(picture: CGSize(width: 6000, height: 4000), ppi: 300)
        XCTAssertEqual(s.width, 1440)
        XCTAssertEqual(s.height, 960)
    }
}

final class PrintRenderTests: XCTestCase {
    private func picture(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        return ctx.makeImage()!
    }

    func testCropsEnlargesAndSharpensInTheSameColourSpace() throws {
        let out = try XCTUnwrap(PrintRender.prepare(picture(400, 300), isHDR: false, visible: CGRect(x: 50, y: 0, width: 300, height: 300),
                                                    size: CGSize(width: 750, height: 750), ppi: 300,
                                                    sharpening: .standard, finish: .glossy))
        XCTAssertEqual(out.width, 750)
        XCTAssertEqual(out.height, 750)
        XCTAssertEqual(out.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertEqual(out.bitsPerComponent, 16, "enlarged in half float, sharpened at 16 bits")
    }

    /// The darkest and lightest red along the middle row, 0…1.
    private func extremes(_ image: CGImage) -> (lo: Double, hi: Double) {
        let w = image.width, h = image.height
        var px = [Float](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                            space: CGColorSpace(name: CGColorSpace.extendedDisplayP3)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let row = (0..<w).map { Double(px[(h / 2 * w + $0) * 4]) }
        return (row.min()!, row.max()!)
    }

    func testEnlargingAHardEdgeLeavesNoHalo() throws {
        // A grey that has room to ring both ways, against a darker grey.
        let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        ctx.setFillColor(CGColor(gray: 0.7, alpha: 1)); ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
        let edge = ctx.makeImage()!
        let (lo, hi) = extremes(edge)
        let region = CGRect(x: 0, y: 0, width: 40, height: 40)
        let plain = try XCTUnwrap(Resampler.render(edge, from: region, width: 160, height: 160, halfFloat: true))
        let held = try XCTUnwrap(PrintRender.enlarged(edge, from: region, width: 160, height: 160))
        let p = extremes(plain), e = extremes(held)
        XCTAssertGreaterThan(p.hi - hi, 0.02, "plain Lanczos overshoots the edge")
        XCTAssertLessThan(e.hi - hi, (p.hi - hi) * 0.3)
        XCTAssertGreaterThan(lo - e.lo, -0.01)
        XCTAssertLessThan(lo - e.lo, (lo - p.lo) * 0.3 + 0.002)
    }

    func testWithoutASizeItIsTheCropAlone() throws {
        let out = try XCTUnwrap(PrintRender.prepare(picture(400, 300), isHDR: false, visible: CGRect(x: 0, y: 0, width: 200, height: 100),
                                                    size: nil, ppi: 300, sharpening: .off, finish: .matte))
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 100)
    }
}
