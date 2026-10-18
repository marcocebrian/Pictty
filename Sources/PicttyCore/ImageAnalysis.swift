import CoreGraphics

/// Histogram and clipping, measured once per picture on its screen-sized decode.
///
/// Pixels are sampled, not averaged: averaging would hide exactly the single blown or blocked
/// pixels a clipping warning exists to show.
public struct ImageAnalysis: @unchecked Sendable {
    /// 256 bins each, scaled so the tallest bin between the ends is 1 (the end bins of a
    /// clipped picture would otherwise flatten everything else).
    public let red: [Float], green: [Float], blue: [Float], luma: [Float]
    /// Share of pixels with two channels at the top (blown highlights) or all at the bottom.
    public let highlightsClipped: Double
    public let shadowsClipped: Double
    /// Red where highlights are blown, blue where shadows are blocked, clear elsewhere; the size
    /// of the analysed image, to be stretched over the picture.
    public let mask: CGImage?

    /// The level from which a pixel counts as blown, on the histogram of each pixel's second
    /// brightest channel.
    ///
    /// A camera RAW developed by the RAW engine, and any HDR picture seen on an SDR scale, rolls
    /// its highlights off: blown areas do not reach 255, they pile up on one level somewhere in
    /// the bright end (228 for a typical HDR RAW develop). That pile is what gives clipping away:
    /// a level that holds at least eight times the pixels of the levels around it, a meaningful
    /// share of the picture, and is the top of the picture: fewer pixels lie above it than on it.
    /// A bright area that is not clipped (a sky, a white wall) spreads over many levels with its
    /// noise and gradients and does not form one, and a pile with a whole picture above it is a
    /// colour, not a ceiling. Without a pile, only the top values count.
    ///
    /// An SDR picture has nothing to roll off: its blown areas sit at the top, so `rolledOff` is
    /// false for it and only the top values count.
    static func ceiling(_ top: [UInt32], total: Int, rolledOff: Bool = true) -> Int {
        guard total > 0, rolledOff else { return 254 }
        var above = 0.0
        for c in stride(from: 255, through: 160, by: -1) {
            defer { above += Double(top[c]) }
            guard c <= 254 else { continue }
            let here = Double(top[c])
            guard here > Double(total) * 0.001, above < here else { continue }
            var around: [UInt32] = []
            for d in 3...14 {
                if c - d >= 0 { around.append(top[c - d]) }
                if c + d <= 255 { around.append(top[c + d]) }
            }
            around.sort()
            let median = Double(around[around.count / 2])
            if here > max(median, 1) * 8 { return c - 1 }
        }
        return 254
    }

    public static func analyze(_ image: CGImage, maxPixel: Int = 2048) -> ImageAnalysis? {
        let k = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
        // Measured in the picture's own colour space: converting a Display P3 picture to sRGB first
        // would pull its pure white below the top and hide the clipping. Wide or HDR spaces that
        // an 8-bit context cannot hold are measured in Display P3, where values past SDR white
        // count as blown, which is what they are on an SDR display.
        let own = image.colorSpace.flatMap { cs -> CGColorSpace? in
            guard cs.model == .rgb, !CGColorSpaceUsesExtendedRange(cs), !CGColorSpaceUsesITUR_2100TF(cs) else { return nil }
            return cs
        }
        guard let space = own ?? CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let maskSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let maskCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: maskSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = ctx.data?.assumingMemoryBound(to: UInt8.self),
              let mk = maskCtx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // A pixel is blown when at least two of its channels are: a saturated colour has one
        // channel at the top by nature (a sodium street lamp, a red sign at night) and still all
        // its detail, so one channel alone does not count.
        @inline(__always) func second(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 { max(min(a, b), min(max(a, b), c)) }

        var r = [UInt32](repeating: 0, count: 256), g = r, b = r, l = r, top = r
        var counted = 0
        for i in 0..<(w * h) {
            let o = i * 4
            guard px[o + 3] > 0 else { continue }
            let pr = px[o], pg = px[o + 1], pb = px[o + 2]
            r[Int(pr)] += 1; g[Int(pg)] += 1; b[Int(pb)] += 1
            l[(2126 * Int(pr) + 7152 * Int(pg) + 722 * Int(pb)) / 10000] += 1
            top[Int(second(pr, pg, pb))] += 1
            counted += 1
        }

        // Where highlights clip: a pile below white for a rolled-off (HDR or RAW) picture, the
        // top values otherwise. `own` is nil exactly for the extended and HDR spaces.
        let ceiling = Self.ceiling(top, total: counted, rolledOff: own == nil)

        var blown = 0, blocked = 0
        for i in 0..<(w * h) {
            let o = i * 4
            guard px[o + 3] > 0 else { continue }
            let pr = px[o], pg = px[o + 1], pb = px[o + 2]
            if Int(second(pr, pg, pb)) >= ceiling {
                blown += 1
                mk[o] = 235; mk[o + 1] = 40; mk[o + 2] = 40; mk[o + 3] = 235
            } else if pr <= 1 && pg <= 1 && pb <= 1 {
                blocked += 1
                mk[o] = 30; mk[o + 1] = 100; mk[o + 2] = 245; mk[o + 3] = 235
            }
        }
        func normalised(_ bins: [UInt32]) -> [Float] {
            let peak = Float(max(1, bins[1...254].max() ?? 1))
            return bins.map { min(1, Float($0) / peak) }
        }
        let total = Double(max(1, counted))
        return ImageAnalysis(red: normalised(r), green: normalised(g), blue: normalised(b), luma: normalised(l),
                             highlightsClipped: Double(blown) / total, shadowsClipped: Double(blocked) / total,
                             mask: blown + blocked > 0 ? maskCtx.makeImage() : nil)
    }
}
