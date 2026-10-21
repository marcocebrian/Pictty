import CoreGraphics
import Foundation
import ImageIO

/// How hard a JPEG was compressed, read from its quantisation tables, so a re-save can match it.
///
/// Saving a JPEG at a different quality than it was made with costs twice: a higher one makes the
/// file bigger without bringing anything back, a lower one throws away more. Saving at the same
/// quality reuses (nearly) the same tables, so the blocks that did not change come back almost
/// as they were. Quality is read the way the IJG tools do it: the luminance table is compared with
/// the standard one scaled for every quality from 1 to 100. Apple's encoder has its own idea of
/// what a quality number means, so it is measured once, by encoding a tiny picture at a range of
/// settings and reading back its tables.
public enum JPEGQuality {
    /// The IJG standard luminance table (Annex K), any order: only the sum is compared.
    static let standard: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]

    /// The IJG quality (1…100) a JPEG file was made with, or nil if it has no readable tables.
    public static func estimate(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return estimate(data)
    }

    public static func estimate(_ data: Data) -> Int? {
        guard let table = luminanceTable(data) else { return nil }
        let sum = table.reduce(0, +)
        var best = (q: 0, error: Int.max)
        for q in 1...100 {
            let scale = q < 50 ? 5000 / q : 200 - 2 * q
            let s = standard.reduce(0) { $0 + min(max(($1 * scale + 50) / 100, 1), 255) }
            if abs(s - sum) < best.error { best = (q, abs(s - sum)) }
        }
        return best.q
    }

    /// Table 0 of the first DQT segment.
    static func luminanceTable(_ data: Data) -> [Int]? {
        let b = [UInt8](data.prefix(256 * 1024))
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { i += 2; continue }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if marker == 0xDA { return nil }  // start of scan: no tables before it
            if marker == 0xDB {
                var j = i + 4
                let end = min(i + 2 + length, b.count)
                while j < end {
                    let precision = b[j] >> 4, id = b[j] & 0x0F
                    j += 1
                    let n = precision == 0 ? 64 : 128
                    guard j + n <= end else { return nil }
                    if id == 0 {
                        return precision == 0 ? b[j..<j + 64].map(Int.init)
                            : stride(from: j, to: j + 128, by: 2).map { Int(b[$0]) << 8 | Int(b[$0 + 1]) }
                    }
                    j += n
                }
            }
            i += 2 + length
        }
        return nil
    }

    /// Apple's encoder measured: for each of its settings from 0.30 to 1.00, the IJG quality it gives
    /// and the sum of its luminance table (lower is finer).
    private static let calibration: [(setting: Double, quality: Int, sum: Int)] = {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let ctx else { return [] }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = ctx.makeImage() else { return [] }
        var out: [(Double, Int, Int)] = []
        for step in stride(from: 30, through: 100, by: 1) {
            let setting = Double(step) / 100
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: setting] as CFDictionary)
            guard CGImageDestinationFinalize(dest), let q = estimate(data as Data),
                  let table = luminanceTable(data as Data) else { continue }
            out.append((setting, q, table.reduce(0, +)))
        }
        return out
    }()

    /// The encoder setting that gives at least IJG quality `q`: the lowest one that does, so the
    /// file is no larger than the original's quality calls for.
    public static func setting(matching q: Int) -> Double {
        calibration.first { $0.quality >= q }?.setting ?? 1
    }

    /// The encoder setting for re-saving the JPEG at `url`: the lowest whose luminance table is at
    /// least as fine as the file's own, compared table to table rather than through a quality
    /// number, which Apple's tables do not follow exactly.
    public static func setting(for url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let table = luminanceTable(data) else { return nil }
        let sum = table.reduce(0, +)
        return calibration.first { $0.sum <= sum }?.setting ?? 1
    }
}
