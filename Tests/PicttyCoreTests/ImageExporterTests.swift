import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PicttyCore
import XCTest

final class ImageExporterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pictty-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func picture(width: Int = 300, height: Int = 200) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.4, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// A JPEG with a camera and a location, to take metadata from.
    private func original() throws -> URL {
        let url = folder.appendingPathComponent("original.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, picture(), [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.6, kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    }

    func testKeepsMetadataAndDropsTheLocationWhenAsked() throws {
        let source = try original()
        var o = ExportOptions()
        o.format = .jpeg
        let kept = folder.appendingPathComponent("kept.jpg")
        try ImageExporter.write(picture(), isHDR: false, original: source, to: kept, options: o)
        XCTAssertNotNil(try properties(kept)[kCGImagePropertyGPSDictionary])
        XCTAssertEqual((try properties(kept)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String,
                       "Test Camera")

        o.metadata = .withoutLocation
        let private_ = folder.appendingPathComponent("private.jpg")
        try ImageExporter.write(picture(), isHDR: false, original: source, to: private_, options: o)
        XCTAssertNil(try properties(private_)[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(try properties(private_)[kCGImagePropertyTIFFDictionary])
    }

    func testResizesDepthAndFormat() throws {
        var o = ExportOptions()
        o.format = .png
        o.depth = .sixteen
        o.longEdge = 150
        let url = folder.appendingPathComponent("small.png")
        try ImageExporter.write(picture(), isHDR: false, original: nil, to: url, options: o)
        let p = try properties(url)
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 150)
        XCTAssertEqual(p[kCGImagePropertyPixelHeight] as? Int, 100)
        XCTAssertEqual(p[kCGImagePropertyDepth] as? Int, 16)
    }

    func testOverwritesInPlace() throws {
        let url = try original()
        var o = ExportOptions()
        o.format = .jpeg
        try ImageExporter.write(picture(width: 120, height: 80), isHDR: false, original: url, to: url, options: o)
        XCTAssertEqual(try properties(url)[kCGImagePropertyPixelWidth] as? Int, 120)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("pictty") }
        XCTAssertEqual(leftovers, [])
    }

    func testEveryWritableFormatWrites() throws {
        for format in ExportFormat.writable {
            var o = ExportOptions()
            o.format = format
            let url = folder.appendingPathComponent("out.\(format.fileExtension)")
            XCTAssertNoThrow(try ImageExporter.write(picture(), isHDR: false, original: nil, to: url, options: o), format.title)
            XCTAssertEqual(try properties(url)[kCGImagePropertyPixelWidth] as? Int, 300, format.title)
        }
    }

    /// A 10-bit HEIC edited and saved stays 10-bit: Save chose 16-bit or 8-bit only, and HEIC
    /// has no 16-bit, so every edit of a camera's or phone's 10-bit HEIF came back 8-bit.
    func testSavingKeepsADeepPicturesDepth() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = 1024, h = 64
        var px = [UInt16](repeating: 65535, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let v = UInt16((0.30 + 0.04 * Double(x) / Double(w)) * 65535); let i = (y * w + x) * 4; px[i] = v; px[i + 1] = v; px[i + 2] = v } }
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = px.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: space,
                                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)! }
        let deep = ctx.makeImage()!
        let original = dir.appendingPathComponent("deep.heic")
        let d = try XCTUnwrap(CGImageDestinationCreateWithURL(original as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(d, deep, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        func depth(_ url: URL) -> Int? {
            let src = CGImageSourceCreateWithURL(url as CFURL, nil)
            return (src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any])?[kCGImagePropertyDepth] as? Int
        }
        XCTAssertEqual(depth(original), 10)

        XCTAssertEqual(ImageExporter.depthKeeping(original, format: .heic), .ten)
        XCTAssertEqual(ImageExporter.depthKeeping(original, format: .tiff), .sixteen)
        XCTAssertEqual(ImageExporter.depthKeeping(original, format: .jpeg), .eight)
        var o = ExportOptions()
        o.format = .heic
        o.depth = ImageExporter.depthKeeping(original, format: .heic)
        let saved = dir.appendingPathComponent("saved.heic")
        try ImageExporter.write(deep, isHDR: false, original: original, to: saved, options: o)
        XCTAssertEqual(depth(saved), 10, "saved at its own depth")
    }
}
