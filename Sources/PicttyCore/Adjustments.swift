import Foundation

/// A colour pushed into one tonal range: which colour (hue, degrees) and how much (0…1).
public struct ColourShift: Equatable, Codable, Sendable {
    public var hue: Double = 0
    public var amount: Double = 0

    public init(hue: Double = 0, amount: Double = 0) {
        self.hue = hue
        self.amount = amount
    }

    public var isNeutral: Bool { amount == 0 }
}

/// Everything the Adjust panel does to a picture. Every value is 0 at rest, and at rest the
/// engine gives back the picture untouched.
public struct Adjustments: Equatable, Sendable {
    // Light
    /// Stops, −4…+4.
    public var exposure: Double = 0
    /// −1…+1 for the rest.
    public var contrast: Double = 0
    public var brightness: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0

    /// The engine's own number for the method each tone slider uses, while candidates are compared.
    public var exposureAlgorithm = 2
    public var highlightsAlgorithm = 2
    public var shadowsAlgorithm = 1

    // Colour
    /// White balance, −1…+1: cooler ← → warmer, greener ← → more magenta.
    public var temperature: Double = 0
    public var tint: Double = 0
    /// −1…+1: vibrance raises the muted colours most and leaves skin nearly alone; saturation
    /// raises every colour alike, skin less. At −1 saturation is black and white.
    public var vibrance: Double = 0
    public var saturation: Double = 0
    /// Colour grading: a colour for each tonal range, and where the ranges meet (−1…+1).
    public var shadowColour = ColourShift()
    public var midtoneColour = ColourShift()
    public var highlightColour = ColourShift()
    public var balance: Double = 0

    // Detail
    /// −1…+1: surface detail, the middle scales.
    public var texture: Double = 0
    /// −1…+1: local contrast, the coarse scales, in the midtones.
    public var clarity: Double = 0
    /// 0…1: the finest scales, at the radius the picture's own blur calls for.
    public var sharpening: Double = 0
    /// 0…1: how much of the denoised picture replaces the picture.
    public var denoise: Double = 0

    public init() {}

    public static let neutral = Adjustments()

    public var isLightNeutral: Bool {
        exposure == 0 && contrast == 0 && brightness == 0 && highlights == 0 && shadows == 0
    }

    public var isWhiteBalanceNeutral: Bool { temperature == 0 && tint == 0 }

    public var isSaturationNeutral: Bool { vibrance == 0 && saturation == 0 }

    public var isGradingNeutral: Bool {
        shadowColour.isNeutral && midtoneColour.isNeutral && highlightColour.isNeutral
    }

    public var isDetailNeutral: Bool { texture == 0 && clarity == 0 && sharpening == 0 && denoise == 0 }

    /// True when nothing would change the picture, whatever the algorithms.
    public var isNeutral: Bool { isLightNeutral && isWhiteBalanceNeutral && isSaturationNeutral && isGradingNeutral
        && isDetailNeutral }

    /// Every value back to zero; the algorithm choices stay.
    public var valuesReset: Adjustments {
        var a = Adjustments()
        a.exposureAlgorithm = exposureAlgorithm
        a.highlightsAlgorithm = highlightsAlgorithm
        a.shadowsAlgorithm = shadowsAlgorithm
        return a
    }

    public var lightReset: Adjustments {
        var a = self
        a.exposure = 0; a.contrast = 0; a.brightness = 0; a.highlights = 0; a.shadows = 0
        return a
    }

    public var detailReset: Adjustments {
        var a = self
        a.texture = 0; a.clarity = 0; a.sharpening = 0; a.denoise = 0
        return a
    }

    public var colourReset: Adjustments {
        var a = self
        a.temperature = 0; a.tint = 0; a.vibrance = 0; a.saturation = 0
        a.shadowColour = ColourShift(); a.midtoneColour = ColourShift(); a.highlightColour = ColourShift()
        a.balance = 0
        return a
    }
}

/// One slider of the Adjust panel, for the panel and the engine alike.
public enum AdjustmentControl: String, CaseIterable, Identifiable, Sendable {
    case exposure, contrast, brightness, highlights, shadows, temperature, tint, vibrance, saturation, balance
    case texture, clarity, sharpening, denoise

    public static let light: [AdjustmentControl] = [.exposure, .contrast, .brightness, .highlights, .shadows]
    public static let whiteBalance: [AdjustmentControl] = [.temperature, .tint]
    public static let saturationControls: [AdjustmentControl] = [.vibrance, .saturation]
    public static let detail: [AdjustmentControl] = [.texture, .clarity, .sharpening]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .brightness: "Brightness"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .vibrance: "Vibrance"
        case .saturation: "Saturation"
        case .balance: "Balance"
        case .texture: "Texture"
        case .clarity: "Clarity"
        case .sharpening: "Sharpening"
        case .denoise: "Amount"
        }
    }

    public var symbol: String {
        switch self {
        case .exposure: "plusminus.circle"
        case .contrast: "circle.lefthalf.filled"
        case .brightness: "sun.max"
        case .highlights: "sun.horizon"
        case .shadows: "moon"
        case .temperature: "thermometer.medium"
        case .tint: "drop.halffull"
        case .vibrance: "camera.filters"
        case .saturation: "drop.fill"
        case .balance: "scalemass"
        case .texture: "circle.hexagongrid"
        case .clarity: "sun.haze"
        case .sharpening: "scope"
        case .denoise: "wand.and.sparkles"
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .exposure: -4...4
        case .sharpening, .denoise: 0...1
        default: -1...1
        }
    }

    /// The candidates still being compared, as (engine number, name, what it does). One entry:
    /// the winner, and no buttons.
    public var algorithms: [(id: Int, name: String, detail: String)] {
        switch self {
        case .exposure:
            [(1, "Linear", "Multiplies the light. Whatever passes white clips."),
             (2, "Colour-keeping shoulder", "Multiplies the light, then rolls the brightest channel off into white, keeping each colour's hue and saturation."),
             (3, "Film shoulder", "Multiplies the light, then rolls each channel off on its own, so the brightest colours drift to white as on film.")]
        case .highlights:
            [(2, "Guided filter", "The curve moves a smooth, edge-aware base layer; the detail on top is kept."),
             (3, "Local Laplacian", "The curve applied scale by scale through a Laplacian pyramid: detail kept at every size, no halos.")]
        case .shadows:
            [(1, "Global curve", "A tone curve on each pixel's brightness. Fast; flattens detail in the range it moves."),
             (3, "Local Laplacian", "The curve applied scale by scale through a Laplacian pyramid: detail kept at every size, no halos.")]
        default: []
        }
    }

    public func value(_ a: Adjustments) -> Double {
        switch self {
        case .exposure: a.exposure
        case .contrast: a.contrast
        case .brightness: a.brightness
        case .highlights: a.highlights
        case .shadows: a.shadows
        case .temperature: a.temperature
        case .tint: a.tint
        case .vibrance: a.vibrance
        case .saturation: a.saturation
        case .balance: a.balance
        case .texture: a.texture
        case .clarity: a.clarity
        case .sharpening: a.sharpening
        case .denoise: a.denoise
        }
    }

    public func set(_ v: Double, in a: inout Adjustments) {
        let v = min(max(v, range.lowerBound), range.upperBound)
        switch self {
        case .exposure: a.exposure = v
        case .contrast: a.contrast = v
        case .brightness: a.brightness = v
        case .highlights: a.highlights = v
        case .shadows: a.shadows = v
        case .temperature: a.temperature = v
        case .tint: a.tint = v
        case .vibrance: a.vibrance = v
        case .saturation: a.saturation = v
        case .balance: a.balance = v
        case .texture: a.texture = v
        case .clarity: a.clarity = v
        case .sharpening: a.sharpening = v
        case .denoise: a.denoise = v
        }
    }

    /// The engine number of the method in use, or nil for a slider with only one.
    public func algorithm(_ a: Adjustments) -> Int? {
        switch self {
        case .exposure: a.exposureAlgorithm
        case .highlights: a.highlightsAlgorithm
        case .shadows: a.shadowsAlgorithm
        default: nil
        }
    }

    public func setAlgorithm(_ id: Int, in a: inout Adjustments) {
        guard algorithms.contains(where: { $0.id == id }) else { return }
        switch self {
        case .exposure: a.exposureAlgorithm = id
        case .highlights: a.highlightsAlgorithm = id
        case .shadows: a.shadowsAlgorithm = id
        default: break
        }
    }
}

/// The three tonal ranges of colour grading.
public enum ToneRange: String, CaseIterable, Identifiable, Sendable {
    case shadows, midtones, highlights

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shadows: "Shadows"
        case .midtones: "Midtones"
        case .highlights: "Highlights"
        }
    }

    public func shift(_ a: Adjustments) -> ColourShift {
        switch self {
        case .shadows: a.shadowColour
        case .midtones: a.midtoneColour
        case .highlights: a.highlightColour
        }
    }

    public func set(_ s: ColourShift, in a: inout Adjustments) {
        var s = s
        s.amount = min(max(s.amount, 0), 1)
        s.hue = (s.hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        switch self {
        case .shadows: a.shadowColour = s
        case .midtones: a.midtoneColour = s
        case .highlights: a.highlightColour = s
        }
    }
}
