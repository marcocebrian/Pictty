import CoreGraphics
import XCTest
@testable import PicttyCore

final class ImageSizeTests: XCTestCase {
    func testUnitsToPixelsAndBack() {
        let base = 1500.0, ppi = 300.0
        XCTAssertEqual(ImageSizeMath.pixels(50, unit: .percent, base: base, ppi: ppi), 750, accuracy: 1e-9)
        XCTAssertEqual(ImageSizeMath.pixels(2, unit: .inches, base: base, ppi: ppi), 600, accuracy: 1e-9)
        XCTAssertEqual(ImageSizeMath.pixels(2.54, unit: .centimetres, base: base, ppi: ppi), 300, accuracy: 1e-9)
        XCTAssertEqual(ImageSizeMath.pixels(1234, unit: .pixels, base: base, ppi: ppi), 1234)
        for unit in ImageSizeMath.Unit.allCases {
            let v = ImageSizeMath.value(900, unit: unit, base: base, ppi: ppi)
            XCTAssertEqual(ImageSizeMath.pixels(v, unit: unit, base: base, ppi: ppi), 900, accuracy: 1e-9, "\(unit)")
        }
    }

    func testFitIntoKeepsTheShape() {
        XCTAssertEqual(ImageSizeMath.fit(CGSize(width: 6000, height: 4000), into: CGSize(width: 1920, height: 1080)),
                       CGSize(width: 1620, height: 1080))
        XCTAssertEqual(ImageSizeMath.fit(CGSize(width: 1000, height: 3000), into: CGSize(width: 1920, height: 1080)),
                       CGSize(width: 360, height: 1080))
    }

    func testMethodFollowsTheChange() {
        let from = CGSize(width: 1000, height: 800)
        XCTAssertEqual(ImageSizeMath.method(from: from, to: CGSize(width: 500, height: 400)), .shrink)
        XCTAssertEqual(ImageSizeMath.method(from: from, to: CGSize(width: 2000, height: 1600)), .enlarge)
        XCTAssertEqual(ImageSizeMath.method(from: from, to: from), .same)
        XCTAssertEqual(ImageSizeMath.method(from: from, to: CGSize(width: 1200, height: 700)), .enlarge, "more pixels overall, one side shorter")
    }

    func testRefusesSizesNoOneCanOpen() {
        XCTAssertTrue(ImageSizeMath.isValid(CGSize(width: 12000, height: 8000)))
        XCTAssertFalse(ImageSizeMath.isValid(CGSize(width: 40000, height: 100)), "a side past 32 768")
        XCTAssertFalse(ImageSizeMath.isValid(CGSize(width: 20000, height: 20000)), "past 300 MP")
        XCTAssertFalse(ImageSizeMath.isValid(CGSize(width: 0, height: 100)))
    }
}
