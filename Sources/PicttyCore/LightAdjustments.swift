import Foundation

/// The Light panel: exposure, contrast, brightness, highlights and shadows.
///
/// Every value is 0 at rest, and at rest the engine gives back the picture untouched. While the
/// algorithms are being compared, each slider carries its own choice of three; the one that
/// wins stays and the others go.
public struct LightAdjustments: Equatable, Sendable {
    /// Stops, −4…+4.
    public var exposure: Double = 0
    /// −1…+1 for the rest.
    public var contrast: Double = 0
    public var brightness: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0

    /// 1, 2 or 3 per slider.
    public var exposureAlgorithm = 1
    public var contrastAlgorithm = 1
    public var brightnessAlgorithm = 1
    public var highlightsAlgorithm = 1
    public var shadowsAlgorithm = 1

    public init() {}

    public static let neutral = LightAdjustments()

    /// True when every slider is at rest, whatever the algorithms.
    public var isNeutral: Bool {
        exposure == 0 && contrast == 0 && brightness == 0 && highlights == 0 && shadows == 0
    }

    /// The same values, every algorithm reset: what "Reset" leaves.
    public var valuesReset: LightAdjustments {
        var a = self
        a.exposure = 0; a.contrast = 0; a.brightness = 0; a.highlights = 0; a.shadows = 0
        return a
    }
}

/// One slider of the Light panel, for the panel and the engine alike.
public enum LightControl: String, CaseIterable, Identifiable, Sendable {
    case exposure, contrast, brightness, highlights, shadows

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .brightness: "Brightness"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        }
    }

    public var range: ClosedRange<Double> { self == .exposure ? -4...4 : -1...1 }

    /// The three candidates, in button order, and what each one does.
    public var algorithms: [(name: String, detail: String)] {
        switch self {
        case .exposure:
            [("Linear", "Multiplies the light. Whatever passes white clips."),
             ("Colour-keeping shoulder", "Multiplies the light, then rolls the brightest channel off into white, keeping each colour's hue and saturation."),
             ("Film shoulder", "Multiplies the light, then rolls each channel off on its own, so the brightest colours drift to white as on film.")]
        case .contrast:
            [("Classic", "Stretches every channel around mid-grey, on the encoded values. Ends clip."),
             ("Log, about 18 % grey", "Scales light in stops around middle grey, keeping colours, with a shoulder so white is never passed."),
             ("Sigmoid", "An S-curve on brightness that holds black and white in place, keeping colours.")]
        case .brightness:
            [("Midtone gamma", "Bends the middle of the curve; black and white stay put."),
             ("Lift", "Adds to every channel: blacks turn grey and whites clip, the old way."),
             ("CIELAB L*", "Raises lightness in a perceptual space; colour coordinates stay where they are.")]
        case .highlights, .shadows:
            [("Global curve", "A tone curve on each pixel's brightness. Fast; flattens detail in the range it moves."),
             ("Guided filter", "The curve moves a smooth, edge-aware base layer; the detail on top is kept."),
             ("Local Laplacian", "The curve applied scale by scale through a Laplacian pyramid: detail kept at every size, no halos.")]
        }
    }

    public func value(_ a: LightAdjustments) -> Double {
        switch self {
        case .exposure: a.exposure
        case .contrast: a.contrast
        case .brightness: a.brightness
        case .highlights: a.highlights
        case .shadows: a.shadows
        }
    }

    public func set(_ v: Double, in a: inout LightAdjustments) {
        let v = min(max(v, range.lowerBound), range.upperBound)
        switch self {
        case .exposure: a.exposure = v
        case .contrast: a.contrast = v
        case .brightness: a.brightness = v
        case .highlights: a.highlights = v
        case .shadows: a.shadows = v
        }
    }

    public func algorithm(_ a: LightAdjustments) -> Int {
        switch self {
        case .exposure: a.exposureAlgorithm
        case .contrast: a.contrastAlgorithm
        case .brightness: a.brightnessAlgorithm
        case .highlights: a.highlightsAlgorithm
        case .shadows: a.shadowsAlgorithm
        }
    }

    public func setAlgorithm(_ n: Int, in a: inout LightAdjustments) {
        let n = min(max(n, 1), 3)
        switch self {
        case .exposure: a.exposureAlgorithm = n
        case .contrast: a.contrastAlgorithm = n
        case .brightness: a.brightnessAlgorithm = n
        case .highlights: a.highlightsAlgorithm = n
        case .shadows: a.shadowsAlgorithm = n
        }
    }
}
