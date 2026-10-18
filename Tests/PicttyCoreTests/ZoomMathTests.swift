import CoreGraphics
import XCTest
@testable import PicttyCore

final class ZoomMathTests: XCTestCase {
    func testModes() {
        XCTAssertEqual(ZoomMath.scale(mode: .bestFit, override: nil, fit: 0.5), 0.5)
        XCTAssertEqual(ZoomMath.scale(mode: .bestFit, override: nil, fit: 3), 1)
        XCTAssertEqual(ZoomMath.scale(mode: .fitWindow, override: nil, fit: 3), 3)
        XCTAssertEqual(ZoomMath.scale(mode: .actual, override: nil, fit: 0.2), 1)
        XCTAssertEqual(ZoomMath.scale(mode: .remember, override: 2, fit: 0.2, refFactor: 0.5), 1)
        XCTAssertEqual(ZoomMath.scale(mode: .locked, override: 0.37, fit: 0.2), 0.37)
        XCTAssertEqual(ZoomMath.scale(mode: .locked, override: nil, fit: 3), 1)
        XCTAssertTrue(ZoomMode.locked.keepsZoom && ZoomMode.remember.keepsZoom && !ZoomMode.bestFit.keepsZoom)
    }

    func testSteps() {
        XCTAssertEqual(ZoomMath.step(from: 1, up: true), 1.5)
        XCTAssertEqual(ZoomMath.step(from: 0.6, up: false), 0.5)
        XCTAssertEqual(ZoomMath.step(from: 32, up: true), 32)
    }

    func testClampCenter() {
        let c = ZoomMath.clampCenter(CGPoint(x: 0, y: 0.9), display: CGSize(width: 2000, height: 500),
                                     view: CGSize(width: 1000, height: 800))
        XCTAssertEqual(c, CGPoint(x: 0.25, y: 0.5))
    }

    func testBestFitWindow() {
        let s = ZoomMath.bestFitContentSize(imagePoints: CGSize(width: 4000, height: 2000),
                                            visible: CGSize(width: 1000, height: 1000),
                                            minimum: CGSize(width: 400, height: 300))
        XCTAssertEqual(s, CGSize(width: 1000, height: 500))
    }

    func testBestFitWindowAtZoom() {
        let image = CGSize(width: 800, height: 400), visible = CGSize(width: 1000, height: 1000)
        let minimum = CGSize(width: 400, height: 300)
        XCTAssertEqual(ZoomMath.bestFitContentSize(imagePoints: image, scale: 1, visible: visible, minimum: minimum),
                       CGSize(width: 800, height: 400))
        XCTAssertEqual(ZoomMath.bestFitContentSize(imagePoints: image, scale: 2, visible: visible, minimum: minimum),
                       CGSize(width: 1000, height: 800))
        XCTAssertEqual(ZoomMath.bestFitContentSize(imagePoints: image, scale: 0.25, visible: visible, minimum: minimum),
                       CGSize(width: 400, height: 300))
    }

    func testFormats() {
        for e in ["jpg", "png", "heic", "avif", "bmp", "tiff", "webp", "gif", "cr3", "nef", "dng"] {
            XCTAssertTrue(ImageFormats.extensions.contains(e), e)
        }
        XCTAssertFalse(ImageFormats.extensions.contains("pdf"))
        XCTAssertTrue(ImageFormats.isSupported(URL(fileURLWithPath: "/a.svg")))
        XCTAssertTrue(ImageFormats.isVector(URL(fileURLWithPath: "/a.SVG")))
        XCTAssertTrue(ImageFormats.isRaw(URL(fileURLWithPath: "/a.CR3")))
    }
}
