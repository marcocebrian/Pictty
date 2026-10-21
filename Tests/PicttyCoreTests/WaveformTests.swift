import CoreGraphics
import XCTest
@testable import PicttyCore

final class WaveformTests: XCTestCase {
    /// Black on the left half, white on the right: the waveform traces the bottom edge on the
    /// left and the top edge on the right, and nothing in between.
    func testWaveformPlacesBrightnessByColumn() throws {
        let w = 512, h = 256
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        let analysis = try XCTUnwrap(ImageAnalysis.analyze(try XCTUnwrap(ctx.makeImage())))
        let wave = try XCTUnwrap(analysis.waveform)
        let (columns, levels) = ImageAnalysis.waveformSize
        XCTAssertEqual(wave.width, columns)
        XCTAssertEqual(wave.height, levels)

        let data = try XCTUnwrap(wave.dataProvider?.data as Data?)
        func alpha(x: Int, rowFromTop y: Int) -> UInt8 { data[(y * wave.bytesPerRow) + x * 4 + 3] }
        XCTAssertEqual(alpha(x: 10, rowFromTop: levels - 1), 255, "black, on the bottom edge, left")
        XCTAssertEqual(alpha(x: 10, rowFromTop: 0), 0)
        XCTAssertEqual(alpha(x: columns - 10, rowFromTop: 0), 255, "white, on the top edge, right")
        XCTAssertEqual(alpha(x: columns - 10, rowFromTop: levels - 1), 0)
        XCTAssertEqual(alpha(x: 10, rowFromTop: levels / 2), 0, "no mid-tones")
    }
}
