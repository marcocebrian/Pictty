import CoreGraphics
import XCTest
@testable import PicttyCore

final class ResamplerTests: XCTestCase {
    /// A Gaussian blob on black, in 8-bit sRGB or half-float extended sRGB.
    private func blob(width: Int, height: Int, at c: CGPoint, deep: Bool) -> CGImage {
        let space = CGColorSpace(name: deep ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)!
        let info = deep
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: deep ? 16 : 8,
                            bytesPerRow: 0, space: space, bitmapInfo: info)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for y in 0..<height {
            for x in 0..<width {
                let d2 = pow(Double(x) + 0.5 - c.x, 2) + pow(Double(y) + 0.5 - c.y, 2)
                let v = exp(-d2 / (2 * 16))
                guard v > 0.002 else { continue }
                ctx.setFillColor(CGColor(gray: v, alpha: 1))
                // CGContext is bottom-up; flip so `c` is in top-left coordinates.
                ctx.fill(CGRect(x: x, y: height - 1 - y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    /// Brightness-weighted centroid, top-left coordinates, pixel centres at +0.5.
    private func centroid(_ image: CGImage) -> CGPoint {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sx = 0.0, sy = 0.0, s = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let v = Double(px[(y * w + x) * 4])
                s += v; sx += v * (Double(x) + 0.5); sy += v * (Double(y) + 0.5)
            }
        }
        return CGPoint(x: sx / s, y: sy / s)
    }

    private func check(deep: Bool, rect: CGRect, out: (Int, Int), file: StaticString = #filePath, line: UInt = #line) {
        let c = CGPoint(x: 101.3, y: 64.8)
        let src = blob(width: 220, height: 150, at: c, deep: deep)
        guard let img = Resampler.render(src, from: rect, width: out.0, height: out.1) else {
            return XCTFail("render failed", file: file, line: line)
        }
        XCTAssertEqual(img.width, out.0, file: file, line: line)
        XCTAssertEqual(img.height, out.1, file: file, line: line)
        let got = centroid(img)
        let want = CGPoint(x: (c.x - rect.minX) * CGFloat(out.0) / rect.width,
                           y: (c.y - rect.minY) * CGFloat(out.1) / rect.height)
        // A tenth of an output pixel: far below what the eye can see.
        XCTAssertEqual(got.x, want.x, accuracy: 0.1, "x", file: file, line: line)
        XCTAssertEqual(got.y, want.y, accuracy: 0.1, "y", file: file, line: line)
    }

    func testEnlargedCropLandsOnSubpixel() {
        check(deep: false, rect: CGRect(x: 61.3, y: 31.7, width: 80.2, height: 60.5), out: (153, 103))
        check(deep: true, rect: CGRect(x: 61.3, y: 31.7, width: 80.2, height: 60.5), out: (153, 103))
    }

    func testReducedWholeImage() {
        check(deep: false, rect: CGRect(x: 0, y: 0, width: 220, height: 150), out: (81, 55))
        check(deep: true, rect: CGRect(x: 0, y: 0, width: 220, height: 150), out: (81, 55))
    }

    func testIdentityIsExact() {
        let src = blob(width: 64, height: 48, at: CGPoint(x: 30, y: 20), deep: false)
        let img = Resampler.render(src, from: CGRect(x: 0, y: 0, width: 64, height: 48), width: 64, height: 48)!
        XCTAssertEqual(centroid(img).x, centroid(src).x, accuracy: 0.01)
        XCTAssertEqual(centroid(img).y, centroid(src).y, accuracy: 0.01)
    }

    func testRegion() {
        let layer = CGSize(width: 1000, height: 800)
        let r = RefineMath.region(visible: CGRect(x: 100.4, y: -50, width: 400, height: 300), layerPixels: layer, margin: 0.25)!
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 601, height: 325))
        XCTAssertTrue(RefineMath.covers(r, visible: CGRect(x: 100.4, y: -50, width: 400, height: 300), layerPixels: layer))
        XCTAssertFalse(RefineMath.covers(r, visible: CGRect(x: 300, y: 100, width: 400, height: 300), layerPixels: layer))
        XCTAssertEqual(RefineMath.sourceRect(for: CGRect(x: 10, y: 20, width: 100, height: 50),
                                             layerPixels: CGSize(width: 500, height: 400),
                                             sourcePixels: CGSize(width: 1000, height: 800)),
                       CGRect(x: 20, y: 40, width: 200, height: 100))
    }

    /// A vector region lands exactly where the layer puts it, and stays transparent around it.
    func testVectorRegion() throws {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><circle cx="130" cy="40" r="10" fill="white"/></svg>"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pictty-test-\(UUID().uuidString).svg")
        try svg.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let v = try XCTUnwrap(VectorImage(url: url))
        XCTAssertEqual(v.size, CGSize(width: 200, height: 100))
        // The picture at 4×: an 800×400 canvas; render the region (400, 60)–(640, 260) at 1:1.
        let region = CGRect(x: 400, y: 60, width: 240, height: 200)
        let img = try XCTUnwrap(v.render(region, of: CGSize(width: 800, height: 400), width: 240, height: 200))
        let c = centroid(img)
        XCTAssertEqual(c.x, 130 * 4 - 400, accuracy: 0.1)
        XCTAssertEqual(c.y, 40 * 4 - 60, accuracy: 0.1)
        XCTAssertTrue(ImageDecoder.hasAlpha(img))
    }

    /// Shrinking a 1-pixel black and white checkerboard by 2 averages light: mid grey is about
    /// 188 in sRGB, not the 128 a gamma-space average gives.
    func testShrinkingAveragesLight() throws {
        let n = 64
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in 0..<n { for x in 0..<n {
            ctx.setFillColor(CGColor(gray: (x + y) % 2 == 0 ? 1 : 0, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let src = try XCTUnwrap(ctx.makeImage())
        let full = CGRect(x: 0, y: 0, width: n, height: n)
        func centre(_ img: CGImage) -> Int {
            var px = [UInt8](repeating: 0, count: 4)
            let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            c.interpolationQuality = .none
            c.draw(img, in: CGRect(x: -img.width / 2, y: -img.height / 2, width: img.width, height: img.height))
            return Int(px[0])
        }
        let light = try XCTUnwrap(Resampler.render(src, from: full, width: n / 2, height: n / 2))
        let gamma = try XCTUnwrap(Resampler.render(src, from: full, width: n / 2, height: n / 2, linearLight: false))
        XCTAssertEqual(light.bitsPerComponent, 8)
        XCTAssertEqual(centre(light), 188, accuracy: 6)
        XCTAssertEqual(centre(gamma), 128, accuracy: 6)
    }

    /// The tent kernel is exact bilinear: enlarging two pixels 0 and 255 by 4 gives a ramp.
    func testLinearKernelIsBilinear() throws {
        let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let src = try XCTUnwrap(ctx.makeImage())
        let img = try XCTUnwrap(Resampler.render(src, from: CGRect(x: 0, y: 0, width: 2, height: 1), width: 8, height: 4,
                                                 kernel: .linear))
        var px = [UInt8](repeating: 0, count: 8 * 4 * 4)
        let c = CGContext(data: &px, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: 8, height: 4))
        let row = (0..<8).map { Int(px[($0 + 8) * 4]) }
        // Strictly increasing through the middle, flat at the ends (edge extended).
        XCTAssertTrue(zip(row.dropFirst(2), row.dropFirst(3)).allSatisfy { $0 <= $1 }, "\(row)")
        XCTAssertLessThan(row[3], row[4])
        XCTAssertGreaterThan(row[7], 200)
        XCTAssertLessThan(row[0], 55)
    }
}

final class ImageAnalysisTests: XCTestCase {
    /// Half white, a quarter black, a quarter mid grey: the shares and the mask follow.
    func testClipping() throws {
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 50, y: 50, width: 50, height: 50))
        let a = try XCTUnwrap(ImageAnalysis.analyze(try XCTUnwrap(ctx.makeImage())))
        XCTAssertEqual(a.highlightsClipped, 0.5, accuracy: 0.01)
        XCTAssertEqual(a.shadowsClipped, 0.25, accuracy: 0.01)
        XCTAssertNotNil(a.mask)
        XCTAssertEqual(a.luma.count, 256)
        XCTAssertEqual(a.luma[1...254].max(), 1)
    }

    /// The spike an HDR RAW develop puts at 228 is found; a smooth ramp has none, so only 255
    /// counts there.
    func testCeiling() {
        var hdr = [UInt32](repeating: 2500, count: 256)
        for i in 244...255 { hdr[i] = 0 }
        hdr[228] = 93_500; hdr[226] = 16_900
        XCTAssertEqual(ImageAnalysis.ceiling(hdr, total: 2_800_000), 227)
        let ramp = [UInt32](repeating: 100, count: 256)
        XCTAssertEqual(ImageAnalysis.ceiling(ramp, total: 25_600), 254)
        // A pile with more of the picture above it is a colour, not a ceiling.
        var colour = [UInt32](repeating: 10_000, count: 256)
        colour[187] = 120_000
        XCTAssertEqual(ImageAnalysis.ceiling(colour, total: 2_800_000), 254)
        // An SDR picture has nothing rolled off: only the top counts.
        XCTAssertEqual(ImageAnalysis.ceiling(hdr, total: 2_800_000, rolledOff: false), 254)
    }

    /// Saturated colours with one channel at the top keep their detail and are not blown.
    func testSaturatedColourIsNotBlown() throws {
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0.7, alpha: 1)); ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        let a = try XCTUnwrap(ImageAnalysis.analyze(try XCTUnwrap(ctx.makeImage())))
        XCTAssertEqual(a.highlightsClipped, 0.5, accuracy: 0.01)
    }
}

final class AlphaTests: XCTestCase {
    /// RGBA pixels that are all opaque count as opaque; one clear pixel is enough to keep alpha.
    func testOpaqueScan() throws {
        func image(clearPixel: Bool) throws -> CGImage {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            if clearPixel { ctx.clear(CGRect(x: 39, y: 0, width: 1, height: 1)) }
            return try XCTUnwrap(ctx.makeImage())
        }
        XCTAssertTrue(ImageDecoder.hasAlpha(try image(clearPixel: false)))
        XCTAssertTrue(ImageDecoder.isOpaque(try image(clearPixel: false)))
        XCTAssertFalse(ImageDecoder.isOpaque(try image(clearPixel: true)))
    }
}
