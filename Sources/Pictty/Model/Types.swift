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
