import CoreGraphics

/// Image Size's arithmetic: sizes in pixels, percent, centimetres or inches, Fit into, and which
/// way the picture is resampled. The resampling itself is always Pictty's one method: Lanczos,
/// shrinking in linear light (`Resampler`).
public enum ImageSizeMath {
    public enum Unit: String, CaseIterable, Sendable {
        case pixels, percent, centimetres, inches
    }

    public enum Method: Equatable, Sendable { case shrink, enlarge, same }

    /// The largest side and area Pictty writes: what other apps can still open.
    public static let maxSide: CGFloat = 32_768
    public static let maxPixels: CGFloat = 300_000_000

    /// `value` in `unit` as pixels, for a side `base` pixels long now, at `ppi` pixels per inch.
    public static func pixels(_ value: Double, unit: Unit, base: Double, ppi: Double) -> Double {
        switch unit {
        case .pixels: value
        case .percent: base * value / 100
        case .inches: value * ppi
        case .centimetres: value / 2.54 * ppi
        }
    }

    /// `pixels` in `unit`.
    public static func value(_ pixels: Double, unit: Unit, base: Double, ppi: Double) -> Double {
        switch unit {
        case .pixels: pixels
        case .percent: base > 0 ? pixels / base * 100 : 0
        case .inches: ppi > 0 ? pixels / ppi : 0
        case .centimetres: ppi > 0 ? pixels / ppi * 2.54 : 0
        }
    }

    /// `size` scaled, shape kept, to the largest that fits `box`.
    public static func fit(_ size: CGSize, into box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let k = min(box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
    }

    /// Fewer pixels overall is a shrink; more, an enlargement.
    public static func method(from: CGSize, to: CGSize) -> Method {
        let a = from.width * from.height, b = to.width * to.height
        return a == b ? .same : b < a ? .shrink : .enlarge
    }

    public static func isValid(_ size: CGSize) -> Bool {
        size.width >= 1 && size.height >= 1 && max(size.width, size.height) <= maxSide && size.width * size.height <= maxPixels
    }
}
