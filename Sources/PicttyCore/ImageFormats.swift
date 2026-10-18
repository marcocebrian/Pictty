import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Every still/animated image format ImageIO decodes natively (JPEG, PNG, HEIF, AVIF, JPEG XL,
/// WebP, TIFF, BMP, GIF, OpenEXR, camera RAW, …) minus document formats.
public enum ImageFormats {
    static let excludedTypes: Set<String> = [
        "com.adobe.pdf", "com.adobe.illustrator.ai-image",
        "com.adobe.postscript", "com.adobe.encapsulated-postscript",
    ]

    public static let typeIdentifiers: [String] = {
        let ids = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return ids.filter { !excludedTypes.contains($0) } + ["public.svg-image"]
    }()

    public static let extensions: Set<String> = {
        var s = Set<String>()
        for id in typeIdentifiers {
            for e in UTType(id)?.tags[.filenameExtension] ?? [] { s.insert(e.lowercased()) }
        }
        // SVG is not an ImageIO format; it is drawn from the vector by `VectorImage`.
        return s.subtracting(["pdf", "ai", "eps", "ps"]).union(vectorExtensions)
    }()

    static let vectorExtensions: Set<String> = ["svg"]

    private static let rawExtensions: Set<String> = extensions.filter {
        UTType(filenameExtension: $0)?.conforms(to: .rawImage) ?? false
    }

    public static func isSupported(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    public static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }
    public static func isVector(_ url: URL) -> Bool { vectorExtensions.contains(url.pathExtension.lowercased()) }

    /// Supported images in a folder, Finder order.
    public static func listFolder(_ dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants])) ?? []
        return items.filter(isSupported).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}
