import CoreGraphics
import CoreImage
import Vision

/// The subjects of a picture (people, pets, objects: all of them, as Photos lifts them) as a grey
/// mask the picture's size, white where a subject is. macOS's own subject lifting: nothing is
/// bundled, and nothing runs until Remove background is used.
enum SubjectMask {
    enum Result { case found(CGImage), noSubject, failed }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Off the main thread: Vision takes a fraction of a second.
    static func make(for image: CGImage) -> Result {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                timingMark("background: no subject in \(image.width)×\(image.height)")
                return .noSubject
            }
            timingMark("background: \(observation.allInstances.count) subject(s) in \(image.width)×\(image.height)")
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let mask = context.createCGImage(ci, from: ci.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            else { return .failed }
            return .found(mask)
        } catch {
            timingMark("background: Vision failed: \(error.localizedDescription)")
            return .failed
        }
    }
}
