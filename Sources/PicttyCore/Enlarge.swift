import CoreGraphics

/// Enlarge's arithmetic, apart from the network: which pictures may be enlarged, how a picture is cut
/// into the network's fixed tiles, and where faces keep a plain enlargement.
public enum EnlargeRule {
    /// The network invents texture where there is none to find: past 8 MP (a 24 MP photo enlarged)
    /// it only adds crinkle and costs a minute. Measured on the picture as cropped.
    public static let maxPixels = 8_000_000
    public static let factors = [2, 4]

    public enum Refusal: Equatable, Sendable { case tooLarge, hdr }

    public static func refusal(pixelSize: CGSize, isHDR: Bool) -> Refusal? {
        if isHDR { return .hdr }
        return pixelSize.width * pixelSize.height > CGFloat(maxPixels) ? .tooLarge : nil
    }

    public static func outputSize(_ size: CGSize, factor: Int) -> CGSize {
        CGSize(width: size.width * CGFloat(factor), height: size.height * CGFloat(factor))
    }

    /// One run of the network: `source` (always `tile + 2·margin` square, reaching past the picture
    /// where it must: reflect there) and the part of it that is kept, in picture pixels, top-left origin.
    public struct Tile: Equatable, Sendable {
        public let source: CGRect
        public let keep: CGRect
    }

    /// The picture in `tile`-sized cells, each read with `margin` around it so no seam shows: the
    /// network's edges are cut off, and the kept cells touch without overlapping.
    public static func tiles(width: Int, height: Int, tile: Int, margin: Int) -> [Tile] {
        var out: [Tile] = []
        let side = CGFloat(tile + 2 * margin)
        for y in stride(from: 0, to: height, by: tile) {
            for x in stride(from: 0, to: width, by: tile) {
                let keep = CGRect(x: x, y: y, width: min(tile, width - x), height: min(tile, height - y))
                out.append(Tile(source: CGRect(x: CGFloat(x - margin), y: CGFloat(y - margin), width: side, height: side),
                                keep: keep))
            }
        }
        return out
    }

    /// Per pixel of a `width` × `height` picture, top row first: 1 keeps the network's pixel, 0 a
    /// plain enlargement. `faces` in Vision's normalised coordinates (origin bottom-left). Each face
    /// is an ellipse in its rectangle grown by a quarter, plain inside, fading to the network over a
    /// quarter of the face's shorter side.
    public static func faceWeights(faces: [CGRect], width: Int, height: Int) -> [Float] {
        var w = [Float](repeating: 1, count: width * height)
        for f in faces {
            let cx = f.midX * CGFloat(width), cy = (1 - f.midY) * CGFloat(height)
            let a = f.width * CGFloat(width) * 1.25 / 2, b = f.height * CGFloat(height) * 1.25 / 2
            guard a > 0, b > 0 else { continue }
            let feather = 0.25 * min(f.width * CGFloat(width), f.height * CGFloat(height))
            let reach = 1 + feather / min(a, b)  // the normalised radius where the fade ends
            let y0 = max(0, Int((cy - b * reach).rounded(.down))), y1 = min(height, Int((cy + b * reach).rounded(.up)) + 1)
            let x0 = max(0, Int((cx - a * reach).rounded(.down))), x1 = min(width, Int((cx + a * reach).rounded(.up)) + 1)
            guard y0 < y1, x0 < x1 else { continue }
            for y in y0..<y1 {
                let dy = (CGFloat(y) + 0.5 - cy) / b
                for x in x0..<x1 {
                    let dx = (CGFloat(x) + 0.5 - cx) / a
                    let r = (dx * dx + dy * dy).squareRoot()
                    let t = min(1, max(0, (r - 1) / (reach - 1)))
                    let v = Float(t * t * (3 - 2 * t))
                    if v < w[y * width + x] { w[y * width + x] = v }
                }
            }
        }
        return w
    }
}
