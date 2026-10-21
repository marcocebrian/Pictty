import Foundation

// MARK: - Compare layouts

/// How the selected pictures share the canvas.
enum CompareLayout: String, CaseIterable, Identifiable, Codable {
    /// Left / right.
    case sideBySide
    /// Top / bottom.
    case stacked
    /// Two across, then as many rows as it takes. The natural choice for three or four.
    case grid
    /// One picture over the other with a movable split — the best way to spot a one-pixel
    /// difference between two edits.
    case wipe
    /// Superimposed; `B` flips between them at full quality.
    case blink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: "Side by Side"
        case .stacked: "Top & Bottom"
        case .grid: "Grid"
        case .wipe: "Wipe"
        case .blink: "Blink"
        }
    }

    var symbol: String {
        switch self {
        case .sideBySide: "rectangle.split.2x1"
        case .stacked: "rectangle.split.1x2"
        case .grid: "square.grid.2x2"
        case .wipe: "rectangle.lefthalf.inset.filled"
        case .blink: "square.on.square.dashed"
        }
    }

    /// Wipe and blink only make sense for exactly two pictures.
    var requiresExactlyTwo: Bool { self == .wipe || self == .blink }
}

// MARK: - Sorting

enum SortOrder: String, CaseIterable, Identifiable, Codable {
    case name, dateModified, dateCreated, size, kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .size: "Size"
        case .kind: "Kind"
        }
    }
}

// MARK: - Background

/// What sits behind the picture, and behind its transparent pixels.
enum CanvasBackground: String, CaseIterable, Identifiable, Codable {
    case black, glass, checkerboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: "Black"
        case .glass: "Glass"
        case .checkerboard: "Checkerboard"
        }
    }

    var symbol: String {
        switch self {
        case .black: "square.fill"
        case .glass: "square.on.square.intersection.dashed"
        case .checkerboard: "checkerboard.rectangle"
        }
    }
}

// MARK: - Chrome

/// Whether a piece of chrome steps aside when the pointer rests, or stays up.
enum ChromeBehavior: String, CaseIterable, Identifiable, Codable {
    case autoHide, always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoHide: "Hides by itself"
        case .always: "Always visible"
        }
    }
}

// MARK: - Information panel

/// How the panel draws the picture's tones.
enum HistogramStyle: String, CaseIterable, Identifiable, Codable {
    /// How many pixels at each brightness.
    case histogram
    /// Brightness column by column across the picture, so it shows where the highlights and
    /// shadows are, and a clipped one as a line on the edge.
    case waveform

    var id: String { rawValue }

    var title: String {
        switch self {
        case .histogram: "Histogram"
        case .waveform: "Waveform"
        }
    }
}

/// The cards of the information panel, in the order they appear. Each can be switched off.
enum InspectorSection: String, CaseIterable, Identifiable, Codable {
    case histogram, capture, exposure, image, software, dates, location, provenance, keywords, renderer

    var id: String { rawValue }

    /// Also the title of the metadata section it stands for.
    var title: String {
        switch self {
        case .histogram: "Histogram"
        case .capture: "Capture"
        case .exposure: "Exposure"
        case .image: "Image"
        case .software: "Software"
        case .dates: "Dates"
        case .location: "Location"
        case .provenance: "Provenance"
        case .keywords: "Keywords"
        case .renderer: "Renderer"
        }
    }

    var symbol: String {
        switch self {
        case .histogram: "chart.bar.xaxis"
        case .capture: "camera.viewfinder"
        case .exposure: "camera.aperture"
        case .image: "photo"
        case .software: "cpu"
        case .dates: "calendar"
        case .location: "map"
        case .provenance: "doc.text.magnifyingglass"
        case .keywords: "tag"
        case .renderer: "sparkles"
        }
    }

    var detail: String {
        switch self {
        case .histogram: "Histogram or waveform, with clipping at each end"
        case .capture: "Camera, lens and serial number"
        case .exposure: "Focal length, aperture, shutter, ISO and more"
        case .image: "Dimensions, file size, format, bit depth, profile"
        case .software: "What made the file, credit, artist and copyright"
        case .dates: "Captured, digitised and modified"
        case .location: "GPS coordinates and altitude"
        case .provenance: "Container, metadata blocks and title"
        case .keywords: "IPTC and XMP keywords, and Finder tags"
        case .renderer: "How Pictty is drawing the picture"
        }
    }

    init?(sectionTitle: String) {
        guard let match = Self.allCases.first(where: { $0.title == sectionTitle }) else { return nil }
        self = match
    }
}

// MARK: - Info pill

/// What the info pill at the bottom says.
enum PillField: String, CaseIterable, Identifiable, Codable {
    case name, position, fileSize, dimensions, megapixels, format, exposure, camera, captured

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "File name"
        case .position: "Position in folder"
        case .fileSize: "File size"
        case .dimensions: "Dimensions"
        case .megapixels: "Megapixels"
        case .format: "Format"
        case .exposure: "Exposure"
        case .camera: "Camera"
        case .captured: "Date captured"
        }
    }

    var symbol: String {
        switch self {
        case .name: "textformat"
        case .position: "photo.stack"
        case .fileSize: "internaldrive"
        case .dimensions: "arrow.up.left.and.arrow.down.right"
        case .megapixels: "square.grid.3x3"
        case .format: "doc"
        case .exposure: "camera.aperture"
        case .camera: "camera"
        case .captured: "calendar"
        }
    }

    /// What the pill showed before it could be chosen.
    static let standard: [PillField] = [.name, .position, .fileSize, .dimensions, .megapixels, .format, .exposure]
}
