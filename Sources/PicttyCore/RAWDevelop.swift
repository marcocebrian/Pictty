import CoreImage
import Foundation

/// A camera RAW as Pictty's engine starts from it. Apple's RAW engine does only what needs the
/// sensor: demosaicing, the camera's own colour and lens corrections, at the white balance the
/// camera recorded and its own exposure. Everything else is Pictty's, as for any other picture:
/// exposure, white balance, noise reduction, sharpening and the rest.
///
/// The develop comes out in half float, linear and unclipped: what lies past white (a neon sign, a
/// lamp) is still there for Highlights, and the shadows keep the sensor's precision when they are
/// lifted. Developed in 8 bits, both were lost before any slider could reach them.
///
/// This is the develop for a RAW the sensor develop (`SensorDevelop`) cannot take, and what is shown
/// while it runs. Apple's sharpening and luminance noise reduction are off in it; its colour noise
/// reduction stays at the camera's default, which takes out the colour blotches SCUNet, working after
/// the demosaic, could not. So that an untouched RAW still looks as it does in the viewer, Pictty's
/// engine puts a base of noise reduction and sharpening under the sliders (`effective`): noise
/// reduction as much as this picture's own noise calls for, and a little sharpening.
public final class RAWDevelop: @unchecked Sendable {
    /// The develop: linear extended sRGB, half float.
    public let image: CGImage
    /// The same develop with Apple's noise reduction for this camera: what stands in for the
    /// network's while it works, so the first edit does not show the picture's grain.
    public let standIn: CGImage?
    /// The content headroom of an HDR develop, 1 for SDR.
    public let headroom: Float

    /// The sharpening an untouched RAW has, 0…1 on Sharpening's scale: about what Apple's
    /// default sharpening gave.
    public static let baseSharpening = 0.3

    /// `maxPixel` nil develops every pixel; `standIn` asks for the stand-in too.
    /// `lensCorrection` false leaves the lens's distortion in, pixel for pixel as the sensor develop
    /// has it.
    public init?(url: URL, maxPixel: Int?, hdr: Bool, standIn wantsStandIn: Bool = true, lensCorrection: Bool = true) {
        guard let filter = CIRAWFilter(imageURL: url),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        if let maxPixel {
            let native = filter.nativeSize
            let longest = max(native.width, native.height)
            if longest > 0 { filter.scaleFactor = Float(min(1, CGFloat(maxPixel) / longest)) }
        }
        if hdr { filter.extendedDynamicRangeAmount = 1 }
        if !lensCorrection, filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = false }
        if #available(macOS 26, *), filter.isHighlightRecoverySupported { filter.isHighlightRecoveryEnabled = true }
        filter.sharpnessAmount = 0
        filter.detailAmount = 0
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh])
        let defaultLuminanceNR = filter.luminanceNoiseReductionAmount
        let defaultColourNR = filter.colorNoiseReductionAmount
        func render() -> CGImage? {
            guard let out = filter.outputImage else { return nil }
            return context.createCGImage(out, from: out.extent, format: .RGBAh, colorSpace: space)
        }
        standIn = wantsStandIn && (defaultLuminanceNR > 0 || defaultColourNR > 0) ? render() : nil
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = defaultColourNR
        guard let image = render() else { return nil }
        self.image = image
        // The develop's light past SDR white, for an HDR screen (Core Image's own `contentHeadroom`
        // says 1 for an extended-range develop): where its brightest thousandth begins.
        headroom = hdr ? LookMatch.peak(image) : 1
    }

    /// The base of noise reduction this develop calls for, 0…1: what Auto would set, from the
    /// picture's own noise.
    public static func baseDenoise(_ image: CGImage) -> Double {
        PictureMeasure.denoiseAmount(PictureMeasure.noiseLevels(image))
    }

    /// The colour an untouched sensor develop is given, on Vibrance's and Saturation's scales: its
    /// colour is the camera matrix's, plainer than Apple's rendering, and this much brings it close.
    public static let sensorVibrance = 0.10, sensorSaturation = 0.20

    /// The panel's values as Pictty's engine applies them to a develop: Noise reduction and
    /// Sharpening raise the base towards their strongest, and 0 on the slider is the base. A sensor
    /// develop (`sensor`) also has its base of colour under Vibrance and Saturation.
    public static func effective(_ a: Adjustments, baseDenoise: Double, sensor: Bool = false) -> Adjustments {
        var e = a
        e.denoise = baseDenoise + (1 - baseDenoise) * a.denoise
        e.sharpening = baseSharpening + (1 - baseSharpening) * a.sharpening
        if sensor {
            e.vibrance = min(max(a.vibrance + sensorVibrance, -1), 1)
            e.saturation = min(max(a.saturation + sensorSaturation, -1), 1)
        }
        return e
    }
}
