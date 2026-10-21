import AppKit
import Combine
import Foundation
import PicttyCore

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String?
    var tone: Tone = .neutral

    enum Tone { case neutral, success, warning, error }

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool { lhs.id == rhs.id }
}

/// Everything the SwiftUI chrome needs to draw itself, and nothing else. The render-critical
/// state (scale, centre, rotation) lives in the canvas so a 120 Hz pinch never round-trips
/// through `ObservableObject`.
@MainActor
final class ViewerModel: ObservableObject {
    // MARK: Folder

    @Published private(set) var items: [ImageItem] = []
    @Published private(set) var folderURL: URL?
    @Published var index: Int = 0

    /// Extra pictures shown alongside the primary one, in selection order. Up to three, so
    /// the canvas holds four at once, all locked to the same magnification and point of interest.
    @Published var compareIndices: [Int] = []
    /// Which pane keystrokes and gestures target while comparing.
    @Published var activePane: Int = 0
    /// Where a ⇧-click measures its range from.
    @Published var selectionAnchor: Int = 0

    nonisolated static let maxPanes = 4

    // MARK: Presentation

    @Published var zoomMode: ZoomMode = .bestFit
    @Published var zoomLabel: String = "Fit"
    @Published var isProvisional = false
    @Published var loadingText: String?
    @Published var toast: ToastMessage?
    @Published var chromeVisible = true
    @Published var showInspector = false
    @Published var showHUD = true
    /// The feature is on (T).
    @Published var showFilmstrip = true
    /// The pointer is at the bottom edge.
    @Published var filmstripRevealed = false
    /// T pins it open regardless of the pointer.
    @Published var filmstripPinned = false
    @Published var isScanning = false
    @Published var failedPath: String?
    @Published var slideshowRunning = false
    /// The picture on screen is a RAW: still showing the camera's preview, or developed.
    enum RawStatus: Equatable { case developing, developed }
    @Published var rawStatus: RawStatus?
    @Published var showShortcuts = false
    /// Histogram and clipping of the active pane's picture.
    @Published var analysis: ImageAnalysis?
    @Published var showClipping = false
    @Published var mirrored = false

    // MARK: Light

    @Published var showLight = false
    /// The Light panel's values. Algorithm choices outlive the picture; values do not.
    @Published var light = Adjustments()
    /// Which engine edits the picture on screen, or why it cannot be edited.
    @Published var lightEngine: LightRenderer.Engine?
    @Published var lightUnavailable: String?
    /// "Pictty engine · 12 ms", for the panel's footer.
    @Published var lightTiming = ""
    /// Showing the picture as it was, for a before-and-after.
    @Published var showingOriginal = false
    @Published var isSaving = false
    /// The white balance eyedropper is waiting for a click on the picture.
    @Published var pickingWhite = false

    // MARK: Crop

    /// The crop on the picture, once Done; nil for none.
    @Published var crop: CropBox?
    /// Cropping now: the frame on the picture and the crop toolbar are up.
    @Published var cropping = false
    /// The crop being made, until Done or Esc.
    @Published var cropDraft = CropBox()
    @Published var cropRatio = CropRatio.free
    /// The ratio turned on its side (a landscape ratio made portrait, or the other way).
    @Published var cropRatioTurned = false
    @Published var cropRounded = false
    /// One radius for all four corners, or one each.
    @Published var cropLinkedCorners = true

    // MARK: Metadata

    @Published var report: MetadataReport = .empty
    @Published var compareReport: MetadataReport = .empty
    @Published var decodeSummary = ""
    @Published var renderSummary = ""
    @Published var colorSpaceSummary = "—"
    @Published var displaySummary = "SDR"
    @Published var memorySummary = ""

    /// Per-pane caption while comparing, in window points, top-left origin.
    struct PaneCaption: Identifiable, Equatable {
        let id: Int
        var rect: CGRect
        var ordinal: Int
        var title: String
        var size: String
        var exposure: String
        var isHDR: Bool
        var headroom: Float
        var isActive: Bool
        /// How to use the layout, for Wipe and Blink.
        var hint: String = ""
    }

    @Published var paneCaptions: [PaneCaption] = []
    /// Captions carry information rather than controls, so they outlive the chrome.
    @Published var captionsVisible = true

    // MARK: Derived

    var current: ImageItem? { items.indices.contains(index) ? items[index] : nil }

    func item(forPane pane: Int) -> ImageItem? {
        guard let i = index(forPane: pane) else { return nil }
        return items[i]
    }

    func index(forPane pane: Int) -> Int? {
        guard pane >= 0 else { return nil }
        if pane == 0 { return items.indices.contains(index) ? index : nil }
        guard compareIndices.indices.contains(pane - 1) else { return nil }
        let candidate = compareIndices[pane - 1]
        return items.indices.contains(candidate) ? candidate : nil
    }

    var isComparing: Bool { !compareIndices.isEmpty }
    var paneCount: Int { min(Self.maxPanes, 1 + compareIndices.count) }

    func ordinal(for itemIndex: Int) -> Int? {
        if itemIndex == index { return 1 }
        return compareIndices.firstIndex(of: itemIndex).map { $0 + 2 }
    }

    var filmstripVisible: Bool {
        showFilmstrip && items.count > 1 && (filmstripPinned || filmstripRevealed)
    }

    var positionLabel: String { items.isEmpty ? "" : "\(index + 1) / \(items.count)" }
    var folderLabel: String { folderURL?.lastPathComponent ?? "Pictty" }
    var focusedPath: String? { current?.url.path }

    // MARK: Index maths

    func advance(_ delta: Int, loop: Bool) -> Int? {
        guard !items.isEmpty else { return nil }
        var next = index + delta
        if loop { next = ((next % items.count) + items.count) % items.count }
        return items.indices.contains(next) ? next : nil
    }

    /// Moves the primary selection and re-anchors it.
    func setPrimary(_ value: Int) {
        guard !items.isEmpty else { return }
        index = min(max(value, 0), items.count - 1)
        selectionAnchor = index
    }

    func replaceItems(_ newItems: [ImageItem], folder: URL?) {
        items = newItems
        folderURL = folder
        if items.isEmpty {
            index = 0
            compareIndices.removeAll()
        } else {
            index = min(max(index, 0), items.count - 1)
            pruneSelection()
        }
    }

    /// Removes one picture in place, keeping the selection where it was.
    func remove(at i: Int) {
        guard items.indices.contains(i) else { return }
        items.remove(at: i)
        compareIndices = compareIndices.compactMap { $0 == i ? nil : ($0 > i ? $0 - 1 : $0) }
        if index > i || index >= items.count { index = max(0, index - 1) }
        pruneSelection()
    }

    // MARK: Compare

    /// Adds a picture to the comparison or removes it. False when the canvas is full.
    @discardableResult
    func toggleCompare(with other: Int) -> Bool {
        guard items.indices.contains(other) else { return false }
        guard other != index else { return true }
        if let slot = compareIndices.firstIndex(of: other) {
            compareIndices.remove(at: slot)
            activePane = min(activePane, max(0, paneCount - 1))
            return true
        }
        guard compareIndices.count < Self.maxPanes - 1 else { return false }
        compareIndices.append(other)
        return true
    }

    func beginCompare(with other: Int) {
        guard items.indices.contains(other), other != index else { return endCompare() }
        compareIndices = [other]
        activePane = 0
    }

    func endCompare() {
        compareIndices.removeAll()
        activePane = 0
    }

    /// ⇧-click: everything between the anchor and `target`, inclusive. Anything past the
    /// canvas limit is dropped and the caller is told.
    @discardableResult
    func selectRange(to target: Int) -> Bool {
        guard items.indices.contains(target), items.indices.contains(selectionAnchor) else { return false }
        let run = (min(selectionAnchor, target)...max(selectionAnchor, target)).filter { $0 != index }
        compareIndices = Array(run.prefix(Self.maxPanes - 1))
        activePane = 0
        return run.count <= Self.maxPanes - 1
    }

    func pruneSelection() {
        var seen = Set<Int>()
        compareIndices = compareIndices.filter { items.indices.contains($0) && $0 != index && seen.insert($0).inserted }
        activePane = min(activePane, max(0, paneCount - 1))
    }
}
