// Everything Pictty knows about a file that is not pixels. Reading properties is cheap, so the
// probe runs in the background as the folder loads and the inspector is populated by the
// time you press `I`.

import CoreGraphics
import Foundation
import ImageIO
import PicttyCore
import UniformTypeIdentifiers

// MARK: - Presentation model

/// One row of the HUD. `symbol` is an SF Symbol; `mono` locks the value to
/// tabular figures so numbers line up column-wise.
struct MetadataField: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String
    var symbol: String? = nil
    var mono: Bool = true
    var tint: FieldTint = .normal

    enum FieldTint: Hashable { case normal, accent, warning }

    static func == (lhs: MetadataField, rhs: MetadataField) -> Bool {
        lhs.label == rhs.label && lhs.value == rhs.value
    }
    func hash(into hasher: inout Hasher) { hasher.combine(label); hasher.combine(value) }
}

struct MetadataSection: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let symbol: String
    let fields: [MetadataField]

    static func == (lhs: MetadataSection, rhs: MetadataSection) -> Bool {
        lhs.title == rhs.title && lhs.fields == rhs.fields
    }
    func hash(into hasher: inout Hasher) { hasher.combine(title); hasher.combine(fields) }
}

/// The full report the inspector renders.
struct MetadataReport {
    var sections: [MetadataSection] = []
    /// One-line summary used by the always-on HUD strip.
    var headline: String = ""
    var subheadline: String = ""
    var cameraLine: String?
    var exposureLine: String?
    var softwareLine: String?
    var isHDR: Bool = false
    var contentHeadroom: Float = 1
    var hasLocation: Bool = false
    var isAnimated: Bool = false

    static let empty = MetadataReport()
}

// MARK: - Probe

/// Raw output of the property pass, cached per file.
struct ImageProbe {
    var pixelSize: CGSize = .zero
    var orientation: CGImagePropertyOrientation = .up
    var frameCount: Int = 1
    var frameDurations: [Double] = []
    var bitDepth: Int?
    var hasAlpha: Bool = false
    var colorModel: String?
    var profileName: String?
    var isFloat: Bool = false
    var isRaw: Bool = false
    /// A gain-map auxiliary image is present (ISO 21496-1 or Apple's).
    var hasGainMap: Bool = false
    /// Peak linear value the source declares. Filled in after the first decode
    /// as well, because some containers only reveal it in the pixel data.
    var declaredHeadroom: Float = 1
    var report: MetadataReport = .empty
    var loaded = false
    var containerExtension: String = ""

    var isHDR: Bool { declaredHeadroom > 1.0001 || hasGainMap }
}

enum MetadataReader {

    // MARK: Probing

    static func probe(url: URL, item: ImageItem?) -> ImageProbe {
        var probe = ImageProbe()
        if ImageFormats.isVector(url) { return vectorProbe(url: url, item: item) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            probe.loaded = true
            probe.report = MetadataReport.empty
            return probe
        }

        probe.containerExtension = url.pathExtension.lowercased()
        probe.frameCount = max(1, CGImageSourceGetCount(source))
        let index = 0
        let props = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]

        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            probe.pixelSize = CGSize(width: w, height: h)
        }
        if let raw = props[kCGImagePropertyOrientation] as? UInt32,
           let o = CGImagePropertyOrientation(rawValue: raw) {
            probe.orientation = o
        }
        probe.bitDepth = props[kCGImagePropertyDepth] as? Int
        probe.hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        probe.colorModel = props[kCGImagePropertyColorModel] as? String
        probe.isFloat = (probe.bitDepth ?? 0) > 16
        // The embedded profile name is in the property dictionary. Decoding the
        // image to ask its CGColorSpace costs a full decode, which on a 60 MP
        // JPEG is seconds — and this runs on the main thread.
        probe.profileName = (props[kCGImagePropertyProfileName] as? String)?.trimmed
        probe.isRaw = ImageFormats.isRaw(url)

        // A floating-point container is high dynamic range whether or not
        // anything says so. Core Image reports `contentHeadroom` for gain-map
        // and PQ/HLG files but reports 1.0 for EXR and Radiance, whose
        // highlights are simply values above 1.0 in the pixels — so without
        // this the viewer would quietly label a scene-referred file as SDR.
        if probe.isFloat || ["exr", "hdr", "rgbe", "pfm", "pic"].contains(probe.containerExtension) {
            probe.declaredHeadroom = max(probe.declaredHeadroom, kCGDefaultHDRImageContentHeadroom)
        }
        probe.hasGainMap = detectGainMap(source: source, props: props)

        if probe.frameCount > 1 {
            probe.frameDurations = frameDelays(source: source, count: probe.frameCount)
        }

        probe.report = buildReport(url: url,
                                   item: item,
                                   props: props,
                                   source: source,
                                   probe: probe)
        probe.loaded = true
        return probe
    }

    /// SVG: no ImageIO properties, so just the facts that matter for a vector.
    private static func vectorProbe(url: URL, item: ImageItem?) -> ImageProbe {
        var probe = ImageProbe()
        probe.containerExtension = url.pathExtension.lowercased()
        probe.hasAlpha = true
        var fields: [MetadataField] = []
        if let size = VectorImage(url: url)?.size {
            probe.pixelSize = size
            let text = "\(Int(size.width)) × \(Int(size.height))"
            fields.append(MetadataField(label: "Canvas", value: text + " px", symbol: "arrow.up.left.and.arrow.down.right"))
            probe.report.headline = text
        }
        if let item {
            fields.append(MetadataField(label: "File size", value: item.formattedFileSize, symbol: "internaldrive"))
        }
        fields.append(MetadataField(label: "Format", value: "SVG (vector, drawn sharp at any zoom)", symbol: "doc", mono: false))
        probe.report.subheadline = "vector"
        probe.report.sections = [MetadataSection(title: "Image", symbol: "photo", fields: fields)]
        probe.loaded = true
        return probe
    }

    /// HDR stills carry their highlights either in a gain map (ISO 21496-1 for
    /// JPEG/HEIC/AVIF, or Apple's older variant) or directly in a wide container
    /// such as EXR. Ask ImageIO for the auxiliary image rather than guessing
    /// from the container type.
    private static func detectGainMap(source: CGImageSource, props: [CFString: Any]) -> Bool {
        _ = props
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            return true
        }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            return true
        }
        return false
    }

    private static func frameDelays(source: CGImageSource, count: Int) -> [Double] {
        var delays: [Double] = []
        // Reading properties for every frame of a long animation adds up, and
        // beyond a couple of hundred frames the exact total stops mattering.
        let sampled = min(count, 256)
        delays.reserveCapacity(count)
        for i in 0..<sampled {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double)
                ?? 0.1
            // Browsers clamp sub-20 ms delays; we match so playback looks right.
            delays.append(delay < 0.02 ? 0.1 : delay)
        }
        if sampled < count {
            let average = delays.reduce(0, +) / Double(max(1, delays.count))
            delays.append(contentsOf: Array(repeating: average, count: count - sampled))
        }
        return delays
    }

    // MARK: Report

    private static func buildReport(url: URL,
                                    item: ImageItem?,
                                    props: [CFString: Any],
                                    source: CGImageSource,
                                    probe: ImageProbe) -> MetadataReport {
        var report = MetadataReport()
        var sections: [MetadataSection] = []

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        let rawDict = props[kCGImagePropertyRawDictionary] as? [CFString: Any] ?? [:]

        // ---- Capture -------------------------------------------------------
        var capture: [MetadataField] = []
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed
        let body = [make, model].compactMap { $0 }.filter { !$0.isEmpty }
        if !body.isEmpty {
            capture.append(MetadataField(label: "Camera", value: dedupe(body), symbol: "camera"))
        }
        if let lens = string(exif, kCGImagePropertyExifLensModel) ?? string(exifAux, kCGImagePropertyExifAuxLensModel) {
            capture.append(MetadataField(label: "Lens", value: lens, symbol: "camera.aperture"))
        }
        if let lensMake = string(exif, kCGImagePropertyExifLensMake) {
            capture.append(MetadataField(label: "Lens make", value: lensMake, symbol: "building.2"))
        }
        if let spec = exif[kCGImagePropertyExifLensSpecification] as? [Double], spec.count == 4, spec[2] > 0 {
            let text = String(format: "%.0f–%.0f mm  f/%.1f–%.1f", spec[0], spec[1], spec[2], spec[3])
            capture.append(MetadataField(label: "Lens spec", value: text, symbol: "ruler"))
        }
        if let serial = string(exif, kCGImagePropertyExifBodySerialNumber) {
            capture.append(MetadataField(label: "Body serial", value: serial, symbol: "number"))
        }
        if let owner = string(exif, kCGImagePropertyExifCameraOwnerName) {
            capture.append(MetadataField(label: "Owner", value: owner, symbol: "person"))
        }
        if !capture.isEmpty {
            sections.append(MetadataSection(title: "Capture", symbol: "camera.viewfinder", fields: capture))
        }

        // ---- Exposure ------------------------------------------------------
        var exposure: [MetadataField] = []
        let focal = exif[kCGImagePropertyExifFocalLength] as? Double
        let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
        if let focal {
            var value = String(format: "%.0f mm", focal)
            if let focal35, focal35 > 0, abs(Double(focal35) - focal) > 0.5 {
                value += "  " + L("(%ld mm eq.)", focal35)
            }
            exposure.append(MetadataField(label: "Focal length", value: value, symbol: "camera.macro"))
        }
        if let fnum = exif[kCGImagePropertyExifFNumber] as? Double, fnum > 0 {
            exposure.append(MetadataField(label: "Aperture", value: String(format: "f/%.1f", fnum), symbol: "camera.aperture"))
        }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            exposure.append(MetadataField(label: "Shutter", value: shutterString(t), symbol: "timer"))
        }
        if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoArray.first {
            exposure.append(MetadataField(label: "ISO", value: "\(iso)", symbol: "circle.hexagongrid"))
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, abs(bias) > 0.001 {
            exposure.append(MetadataField(label: "Exposure bias", value: String(format: "%+.2f EV", bias), symbol: "plusminus"))
        }
        if let program = exif[kCGImagePropertyExifExposureProgram] as? Int, let name = exposureProgram(program) {
            exposure.append(MetadataField(label: "Program", value: name, symbol: "dial.medium", mono: false))
        }
        if let metering = exif[kCGImagePropertyExifMeteringMode] as? Int, let name = meteringMode(metering) {
            exposure.append(MetadataField(label: "Metering", value: name, symbol: "dot.radiowaves.left.and.right", mono: false))
        }
        if let wb = exif[kCGImagePropertyExifWhiteBalance] as? Int {
            exposure.append(MetadataField(label: "White balance", value: wb == 1 ? "Manual" : "Auto",
                                          symbol: "thermometer.medium", mono: false))
        }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int {
            let fired = (flash & 0x1) != 0
            exposure.append(MetadataField(label: "Flash", value: fired ? "Fired" : "Did not fire",
                                          symbol: fired ? "bolt.fill" : "bolt.slash", mono: false))
        }
        if let distance = exif[kCGImagePropertyExifSubjectDistance] as? Double, distance > 0, distance < 1e6 {
            exposure.append(MetadataField(label: "Subject dist.", value: String(format: "%.2f m", distance), symbol: "point.topleft.down.curvedto.point.bottomright.up"))
        }
        if !exposure.isEmpty {
            sections.append(MetadataSection(title: "Exposure", symbol: "camera.aperture", fields: exposure))
        }

        // ---- Image ---------------------------------------------------------
        var image: [MetadataField] = []
        let sizeText = "\(Int(probe.pixelSize.width)) × \(Int(probe.pixelSize.height))"
        image.append(MetadataField(label: "Dimensions", value: sizeText, symbol: "arrow.up.left.and.arrow.down.right"))
        let mp = probe.pixelSize.width * probe.pixelSize.height / 1_000_000
        if mp > 0 {
            image.append(MetadataField(label: "Resolution", value: String(format: "%.1f MP", mp), symbol: "square.grid.3x3"))
        }
        if let item {
            image.append(MetadataField(label: "File size", value: item.formattedFileSize, symbol: "internaldrive"))
        }
        image.append(MetadataField(label: "Format", value: formatDescription(url: url, probe: probe, props: props),
                                   symbol: "doc", mono: false))
        if let depth = probe.bitDepth {
            var text = "\(depth)-bit"
            if let model = probe.colorModel { text += " \(model)" }
            if probe.hasAlpha { text += " + alpha" }
            if probe.isFloat { text += " float" }
            image.append(MetadataField(label: "Bit depth", value: text, symbol: "square.stack.3d.down.right", mono: false))
        }
        if let profile = probe.profileName {
            image.append(MetadataField(label: "Profile", value: profile, symbol: "paintpalette", mono: false))
        }
        if probe.isHDR || probe.hasGainMap {
            var text = String(format: "%.2f× headroom", probe.declaredHeadroom)
            if probe.hasGainMap { text += " · gain map" }
            image.append(MetadataField(label: "Dynamic range", value: text, symbol: "sun.max.trianglebadge.exclamationmark",
                                       mono: false, tint: .accent))
        }
        if probe.orientation != .up {
            image.append(MetadataField(label: "Orientation", value: orientationName(probe.orientation),
                                       symbol: "rotate.right", mono: false))
        }
        if probe.frameCount > 1 {
            let total = probe.frameDurations.reduce(0, +)
            image.append(MetadataField(label: "Animation",
                                       value: L("%ld frames · %.1f s", probe.frameCount, total),
                                       symbol: "film.stack", mono: false))
        }
        if let dpiX = props[kCGImagePropertyDPIWidth] as? Double, dpiX > 0 {
            image.append(MetadataField(label: "DPI", value: String(format: "%.0f", dpiX), symbol: "printer"))
        }
        sections.append(MetadataSection(title: "Image", symbol: "photo", fields: image))

        // ---- Software & provenance -----------------------------------------
        var software: [MetadataField] = []
        let creator = string(tiff, kCGImagePropertyTIFFSoftware)
            ?? string(png, kCGImagePropertyPNGSoftware)
            ?? xmpString(source: source, path: "xmp:CreatorTool")
            ?? xmpString(source: source, path: "tiff:Software")

        if let creator, !creator.isEmpty {
            software.append(MetadataField(label: "Produced by", value: creator, symbol: "app.badge", mono: false))
            report.softwareLine = creator
        }
        if let host = xmpString(source: source, path: "exif:HostComputer") ?? string(tiff, kCGImagePropertyTIFFHostComputer) {
            software.append(MetadataField(label: "Host", value: host, symbol: "desktopcomputer", mono: false))
        }
        if let app = xmpString(source: source, path: "xmp:CreatorTool"), app != creator {
            software.append(MetadataField(label: "Toolkit", value: app, symbol: "wrench.and.screwdriver", mono: false))
        }
        if let version = xmpString(source: source, path: "crs:Version") {
            software.append(MetadataField(label: "RAW engine", value: "Camera Raw \(version)", symbol: "slider.horizontal.3", mono: false))
        }
        if let original = xmpString(source: source, path: "xmpMM:DerivedFrom/stRef:instanceID") ?? xmpString(source: source, path: "xmpMM:DerivedFrom") {
            software.append(MetadataField(label: "Derived from", value: shortenIdentifier(original),
                                          symbol: "arrow.triangle.branch", mono: false, tint: .accent))
        }
        if let docID = xmpString(source: source, path: "xmpMM:DocumentID") {
            software.append(MetadataField(label: "Document ID", value: shortenIdentifier(docID), symbol: "number.square", mono: false))
        }
        if let history = xmpString(source: source, path: "xmpMM:History[1]/stEvt:softwareAgent") {
            software.append(MetadataField(label: "Last edit", value: history, symbol: "clock.arrow.circlepath", mono: false))
        }
        if let comment = string(exif, kCGImagePropertyExifUserComment), !comment.isEmpty {
            software.append(MetadataField(label: "Comment", value: comment, symbol: "text.bubble", mono: false))
        }
        if let credit = string(iptc, kCGImagePropertyIPTCCredit) {
            software.append(MetadataField(label: "Credit", value: credit, symbol: "checkmark.seal", mono: false))
        }
        if let artist = string(tiff, kCGImagePropertyTIFFArtist) ?? xmpString(source: source, path: "dc:creator") {
            software.append(MetadataField(label: "Artist", value: artist, symbol: "person.crop.circle", mono: false))
        }
        if let copyright = string(tiff, kCGImagePropertyTIFFCopyright) ?? string(iptc, kCGImagePropertyIPTCCopyrightNotice) {
            software.append(MetadataField(label: "Copyright", value: copyright, symbol: "c.circle", mono: false))
        }
        if !software.isEmpty {
            sections.append(MetadataSection(title: "Software", symbol: "cpu", fields: software))
        }

        // ---- Dates ---------------------------------------------------------
        var dates: [MetadataField] = []
        if let s = string(exif, kCGImagePropertyExifDateTimeOriginal), let d = exifDate(s, exif) {
            dates.append(MetadataField(label: "Captured", value: Self.absoluteFormatter.string(from: d), symbol: "camera.badge.clock", mono: false))
            let t = exifTime(s, exif, key: kCGImagePropertyExifOffsetTimeOriginal)
            if let t { dates.append(MetadataField(label: "Capture time", value: t, symbol: "clock", mono: false)) }
        }
        if let s = string(exif, kCGImagePropertyExifDateTimeDigitized) {
            dates.append(MetadataField(label: "Digitised", value: friendlyDate(s), symbol: "sdcard", mono: false))
        }
        if let s = string(tiff, kCGImagePropertyTIFFDateTime) {
            dates.append(MetadataField(label: "File dated", value: friendlyDate(s), symbol: "doc.badge.clock", mono: false))
        }
        if let modified = item?.modified {
            dates.append(MetadataField(label: "Modified", value: Self.absoluteFormatter.string(from: modified), symbol: "pencil.line", mono: false))
        }
        if !dates.isEmpty {
            sections.append(MetadataSection(title: "Dates", symbol: "calendar", fields: dates))
        }

        // ---- Location ------------------------------------------------------
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            var location: [MetadataField] = []
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            location.append(MetadataField(label: "Coordinates",
                                          value: String(format: "%.5f° %@, %.5f° %@", lat, latRef, lon, lonRef),
                                          symbol: "location"))
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
                location.append(MetadataField(label: "Altitude", value: String(format: "%.0f m", alt), symbol: "mountain.2"))
            }
            if let stamp = gps[kCGImagePropertyGPSTimeStamp] as? String {
                location.append(MetadataField(label: "GPS time", value: stamp, symbol: "clock.badge"))
            }
            report.hasLocation = true
            sections.append(MetadataSection(title: "Location", symbol: "map", fields: location))
        }

        // ---- Conformances / structure ---------------------------------------
        var structure: [MetadataField] = []
        structure.append(MetadataField(label: "Container", value: (url.pathExtension.isEmpty ? "unknown" : url.pathExtension.uppercased()),
                                       symbol: "shippingbox", mono: false))
        structure.append(MetadataField(label: "Metadata", value: metadataSummary(tiff: tiff, exif: exif, iptc: iptc, gps: gps, hasXMP: hasXMP(source: source)),
                                       symbol: "list.bullet.rectangle", mono: false))
        if !rawDict.isEmpty {
            structure.append(MetadataField(label: "RAW", value: rawSummary(rawDict), symbol: "camera.metering.center.weighted", mono: false))
        }
        if let title = string(iptc, kCGImagePropertyIPTCObjectName) ?? string(tiff, kCGImagePropertyTIFFImageDescription) {
            structure.append(MetadataField(label: "Title", value: title, symbol: "textformat", mono: false))
        }
        if let keywords = iptc[kCGImagePropertyIPTCKeywords] as? [String], !keywords.isEmpty {
            structure.append(MetadataField(label: "Keywords", value: keywords.joined(separator: ", "), symbol: "tag", mono: false))
        }
        sections.append(MetadataSection(title: "Provenance", symbol: "doc.text.magnifyingglass", fields: structure))

        report.sections = sections
        report.headline = sizeText
        report.subheadline = mp > 0 ? String(format: "%.1f MP", mp) : ""
        report.cameraLine = body.isEmpty ? nil : dedupe(body)
        report.exposureLine = exposureLineValue(exif)
        report.isHDR = probe.isHDR || probe.hasGainMap
        report.contentHeadroom = probe.declaredHeadroom
        report.isAnimated = probe.frameCount > 1
        return report
    }

    // MARK: Helpers

    private static func exposureLineValue(_ exif: [CFString: Any]) -> String? {
        var bits: [String] = []
        if let f = exif[kCGImagePropertyExifFNumber] as? Double, f > 0 { bits.append(String(format: "f/%.1f", f)) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 { bits.append(shutterString(t)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { bits.append("ISO \(iso)") }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { bits.append(String(format: "%.0fmm", fl)) }
        return bits.isEmpty ? nil : bits.joined(separator: "  ·  ")
    }

    static func shutterString(_ t: Double) -> String {
        if t >= 1 { return String(format: "%.1fs", t) }
        return "1/\(Int((1 / t).rounded()))s"
    }

    private static func dedupe(_ parts: [String]) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for part in parts {
            let key = part.lowercased()
            guard !seen.contains(key) else { continue }
            // Don't repeat the make when the model already starts with it.
            if !out.isEmpty, part.lowercased().hasPrefix(out[0].lowercased()) { continue }
            seen.insert(key)
            out.append(part)
        }
        return out.joined(separator: " ")
    }

    private static func string(_ dict: [CFString: Any], _ key: CFString) -> String? {
        guard let value = dict[key] as? String else { return nil }
        let trimmed = value.trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    /// ImageIO exposes the RAW IFD as an opaque dictionary, so surface the
    /// entries that are actually useful in the inspector rather than dumping it.
    private static func rawSummary(_ dict: [CFString: Any]) -> String {
        var bits: [String] = []
        for key in ["BlackLevel", "WhiteLevel", "DefaultCropSize", "BaselineExposure", "Orientation"] {
            guard let value = dict[key as CFString] else { continue }
            let text = String(describing: value).replacingOccurrences(of: "\n", with: " ")
            bits.append("\(key) \(text.prefix(24))")
            if bits.count == 3 { break }
        }
        return bits.isEmpty ? L("%ld entries", dict.count) : bits.joined(separator: " · ")
    }

    private static func metadataSummary(tiff: [CFString: Any], exif: [CFString: Any],
                                        iptc: [CFString: Any], gps: [CFString: Any], hasXMP: Bool) -> String {
        var blocks: [String] = []
        if !exif.isEmpty { blocks.append("EXIF") }
        if !tiff.isEmpty { blocks.append("TIFF") }
        if !iptc.isEmpty { blocks.append("IPTC") }
        if !gps.isEmpty { blocks.append("GPS") }
        if hasXMP { blocks.append("XMP") }
        return blocks.isEmpty ? "none" : blocks.joined(separator: " · ")
    }

    private static func hasXMP(source: CGImageSource) -> Bool {
        // Presence, not contents. Serialising the XMP packet to XML just to
        // answer "is there any?" is pure waste on files that carry a history.
        CGImageSourceCopyMetadataAtIndex(source, 0, nil) != nil
    }

    private static func xmpString(source: CGImageSource, path: String) -> String? {
        guard let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        if let value = CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) as String? {
            let trimmed = value.trimmed
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func shortenIdentifier(_ value: String) -> String {
        if value.count <= 48 { return value }
        return String(value.prefix(24)) + "…" + String(value.suffix(16))
    }

    private static func formatDescription(url: URL, probe: ImageProbe, props: [CFString: Any]) -> String {
        let ext = url.pathExtension.uppercased()
        if probe.isRaw { return ext.isEmpty ? "RAW" : "\(ext) (RAW)" }
        if probe.frameCount > 1 { return "\(ext.isEmpty ? "Animated" : ext) (animated)" }
        return ext.isEmpty ? "Image" : ext
    }

    private static func orientationName(_ o: CGImagePropertyOrientation) -> String {
        switch o {
        case .up: return "Normal"
        case .upMirrored: return "Mirrored"
        case .down: return "180°"
        case .downMirrored: return "180° mirrored"
        case .leftMirrored: return "90° CCW mirrored"
        case .right: return "90° CW"
        case .rightMirrored: return "90° CW mirrored"
        case .left: return "90° CCW"
        @unknown default: return "Unknown"
        }
    }

    private static func exposureProgram(_ value: Int) -> String? {
        switch value {
        case 0: return nil
        case 1: return "Manual"
        case 2: return "Program"
        case 3: return "Aperture priority"
        case 4: return "Shutter priority"
        case 5: return "Creative"
        case 6: return "Action"
        case 7: return "Portrait"
        case 8: return "Landscape"
        default: return nil
        }
    }

    private static func meteringMode(_ value: Int) -> String? {
        switch value {
        case 0: return nil
        case 1: return "Average"
        case 2: return "Centre-weighted"
        case 3: return "Spot"
        case 4: return "Multi-spot"
        case 5: return "Pattern"
        case 6: return "Partial"
        default: return nil
        }
    }

    // EXIF "YYYY:MM:DD HH:MM:SS"
    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private static func exifDate(_ value: String, _ exif: [CFString: Any]) -> Date? {
        guard var date = exifFormatter.date(from: value) else { return nil }
        if let offset = string(exif, kCGImagePropertyExifOffsetTimeOriginal),
           let seconds = timezoneOffsetSeconds(offset) {
            date = date.addingTimeInterval(-Double(seconds) + Double(TimeZone.current.secondsFromGMT(for: date)))
        }
        return date
    }

    private static func exifTime(_ value: String, _ exif: [CFString: Any], key: CFString) -> String? {
        let comps = value.split(separator: " ")
        guard comps.count == 2 else { return nil }
        if let offset = string(exif, key) { return "\(comps[1]) \(offset)" }
        return String(comps[1])
    }

    private static func friendlyDate(_ value: String) -> String {
        guard let date = exifFormatter.date(from: value) else { return value }
        return absoluteFormatter.string(from: date)
    }

    private static func timezoneOffsetSeconds(_ value: String) -> Int? {
        // "+02:00" / "-05:30"
        let sign: Int
        var body = value
        if body.hasPrefix("+") { sign = 1; body.removeFirst() }
        else if body.hasPrefix("-") { sign = -1; body.removeFirst() }
        else { sign = 1 }
        let parts = body.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return sign * (h * 3600 + m * 60)
    }
}

// MARK: - Small helpers

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
