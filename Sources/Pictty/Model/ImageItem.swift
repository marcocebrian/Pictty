import CoreGraphics
import Foundation
import PicttyCore

/// One picture on disk. Identity plus what the directory listing returned in the same call,
/// so opening a 40 000 file folder costs one enumeration and nothing more.
struct ImageItem: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }

    var fileName: String
    var fileSize: Int64
    var modified: Date
    var created: Date

    init(url: URL, values: URLResourceValues? = nil) {
        self.url = url
        fileName = url.lastPathComponent
        fileSize = values?.fileSize.map(Int64.init) ?? 0
        modified = values?.contentModificationDate ?? .distantPast
        created = values?.creationDate ?? .distantPast
    }

    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }
    var isRaw: Bool { ImageFormats.isRaw(url) }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool {
        lhs.url == rhs.url && lhs.modified == rhs.modified && lhs.fileSize == rhs.fileSize
    }

    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

// MARK: - Folder scanning

enum FolderScanner {
    static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey,
    ]

    static func scan(_ folder: URL, order: SortOrder, recursive: Bool) -> [ImageItem] {
        let fm = FileManager.default
        var urls: [URL] = []
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if recursive {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: resourceKeys, options: options) else { return [] }
            for case let url as URL in e { urls.append(url) }
        } else {
            urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: resourceKeys,
                                                options: options.union(.skipsSubdirectoryDescendants))) ?? []
        }

        var items: [ImageItem] = []
        items.reserveCapacity(urls.count)
        for url in urls where ImageFormats.isSupported(url) {
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            if values?.isDirectory == true || values?.isRegularFile == false { continue }
            items.append(ImageItem(url: url, values: values))
        }
        return sort(items, by: order)
    }

    static func sort(_ items: [ImageItem], by order: SortOrder) -> [ImageItem] {
        func name(_ a: ImageItem, _ b: ImageItem) -> Bool {
            a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
        switch order {
        case .name: return items.sorted(by: name)
        case .dateModified: return items.sorted { $0.modified == $1.modified ? name($0, $1) : $0.modified < $1.modified }
        case .dateCreated: return items.sorted { $0.created == $1.created ? name($0, $1) : $0.created < $1.created }
        case .size: return items.sorted { $0.fileSize == $1.fileSize ? name($0, $1) : $0.fileSize < $1.fileSize }
        case .kind: return items.sorted { $0.fileExtension == $1.fileExtension ? name($0, $1) : $0.fileExtension < $1.fileExtension }
        }
    }
}
