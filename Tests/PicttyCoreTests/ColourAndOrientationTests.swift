import CoreGraphics
import ImageIO
@testable import PicttyCore
import simd
import XCTest

final class ColourAndOrientationTests: XCTestCase {
    // MARK: White balance

    func testWhiteBalanceIsTheIdentityAtZero() {
        let m = ColourMath.whiteBalance(temperature: 0, tint: 0)
        XCTAssertEqual(m, matrix_identity_double3x3)
        // Nearly so, either side of zero, and continuous.
        let near = ColourMath.whiteBalance(temperature: 1e-6, tint: 1e-6)
        for c in 0..<3 { XCTAssertEqual(simd_length(near[c] - m[c]), 0, accuracy: 1e-4) }
    }

    /// Picking a neutral and applying what it asks for turns it grey.
    func testANeutralPickTurnsGrey() {
        for cast in [SIMD3<Double>(1, 0.82, 0.58), SIMD3(0.7, 0.85, 1), SIMD3(0.95, 1, 0.9), SIMD3(1, 0.9, 1)] {
            let (t, tint) = ColourMath.whiteBalance(neutral: cast)
            let out = ColourMath.whiteBalance(temperature: t, tint: tint) * cast
            XCTAssertEqual(out.x / out.y, 1, accuracy: 0.02, "\(cast)")
            XCTAssertEqual(out.z / out.y, 1, accuracy: 0.02, "\(cast)")
        }
    }

    func testAutoWhiteBalanceFindsACast() throws {
        // A scene of greys and a few colours, lit warm.
        let w = 120, h = 80
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue))
        let light = SIMD3<Double>(1, 0.8, 0.55)
        let surfaces: [SIMD3<Double>] = [SIMD3(0.5, 0.5, 0.5), SIMD3(0.2, 0.2, 0.2), SIMD3(0.7, 0.7, 0.7),
                                         SIMD3(0.4, 0.15, 0.1), SIMD3(0.1, 0.3, 0.12), SIMD3(0.35, 0.35, 0.35)]
        for (i, s) in surfaces.enumerated() {
            let c = s * light
            ctx.setFillColor(CGColor(colorSpace: space, components: [c.x, c.y, c.z, 1])!)
            ctx.fill(CGRect(x: (i % 3) * 40, y: (i / 3) * 40, width: 40, height: 40))
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let estimate = try XCTUnwrap(ColourMath.estimateIlluminant(image))
        let (t, tint) = ColourMath.whiteBalance(neutral: estimate)
        let grey = ColourMath.whiteBalance(temperature: t, tint: tint) * (SIMD3(0.5, 0.5, 0.5) * light)
        XCTAssertLessThan(t, -0.2, "a warm light is taken out by cooling")
        XCTAssertEqual(grey.x / grey.y, 1, accuracy: 0.06)
        XCTAssertEqual(grey.z / grey.y, 1, accuracy: 0.06)
    }

    // MARK: Orientation

    func testOrientationsCompose() {
        XCTAssertEqual(Orientation.compose(1, quarterTurns: 1, mirror: false), 6)
        XCTAssertEqual(Orientation.compose(6, quarterTurns: 3, mirror: false), 1)
        XCTAssertEqual(Orientation.compose(1, quarterTurns: 2, mirror: false), 3)
        XCTAssertEqual(Orientation.compose(1, quarterTurns: 0, mirror: true), 2)
        XCTAssertEqual(Orientation.compose(8, quarterTurns: 1, mirror: false), 1)
        // Every orientation, turned four times, is itself; mirrored twice, too.
        for o in 1...8 {
            XCTAssertEqual(Orientation.compose(o, quarterTurns: 4, mirror: false), o)
            XCTAssertEqual(Orientation.compose(Orientation.compose(o, quarterTurns: 0, mirror: true), quarterTurns: 0, mirror: true), o)
        }
    }

    /// Two pixels side by side, red then blue: a clockwise turn puts red on top.
    func testPixelsTurnClockwise() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        (px[0], px[1], px[2], px[3]) = (255, 0, 0, 255)
        (px[4], px[5], px[6], px[7]) = (0, 0, 255, 255)
        let turned = try XCTUnwrap(ImageExporter.oriented(try XCTUnwrap(ctx.makeImage()), quarterTurns: 1, mirror: false))
        XCTAssertEqual(turned.width, 1)
        XCTAssertEqual(turned.height, 2)
        let data = try XCTUnwrap(turned.dataProvider?.data as Data?)
        XCTAssertEqual(data[0], 255, "top is red")
        XCTAssertEqual(data[turned.bytesPerRow + 2], 255, "bottom is blue")
    }

    func testReorientLeavesThePixelsAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pictty-orient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("p.jpg")
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for i in 0..<64 { ctx.setFillColor(CGColor(gray: CGFloat(i) / 63, alpha: 1)); ctx.fill(CGRect(x: i, y: 0, width: 1, height: 32)) }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        func stored() throws -> Data {
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            return try XCTUnwrap(img.dataProvider?.data as Data?)
        }
        let before = try stored()
        let quality = JPEGQuality.estimate(url)
        XCTAssertTrue(ImageExporter.reorient(url, quarterTurns: 1, mirror: false))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual((CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(try stored(), before, "the same pixels, decoded")
        XCTAssertEqual(JPEGQuality.estimate(url), quality, "the same tables")
    }

    // MARK: JPEG quality

    func testJPEGQualityIsReadAndMatched() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(ctx.makeImage())
        var last = 0
        for setting in [0.5, 0.7, 0.85, 0.95] {
            let data = NSMutableData()
            let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: setting] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            let q = try XCTUnwrap(JPEGQuality.estimate(data as Data))
            XCTAssertGreaterThanOrEqual(q, last, "higher settings, higher quality")
            last = q
            // Asking for that quality back gives a setting that reproduces it.
            XCTAssertLessThanOrEqual(JPEGQuality.setting(matching: q), setting + 0.0001)
            // And table to table: a re-save is never coarser than the file.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).jpg")
            try (data as Data).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let resave = try XCTUnwrap(JPEGQuality.setting(for: url))
            XCTAssertEqual(resave, setting, accuracy: 0.011)
        }
    }
}
