import Combine
import Foundation
import PicttyCore

/// Persisted settings. Most are a keystroke away and remembered silently; the rest are in Settings.
@MainActor
final class Preferences: ObservableObject {
    enum Key {
        static let zoomMode = "zoomMode"
        static let rememberedScale = "rememberedScale"
        static let compareLayout = "compareLayout"
        static let syncPan = "syncPan"
        static let syncZoom = "syncZoom"
        static let showFilmstrip = "showFilmstrip"
        static let filmstripPinned = "filmstripPinned"
        static let loopFolder = "loopFolder"
        static let slideshowInterval = "slideshowInterval"
        static let sortOrder = "sortOrder"
        static let recursive = "recursive"
        static let animateTransitions = "animateTransitions"
        static let showHUD = "showHUD"
        static let background = "background"
        static let prefetchDepth = "prefetchDepth"
        static let recentFolders = "recentFolders"
        static let windowFrame = "windowFrame"
        static let restoreSession = "restoreSession"
        static let sessionFolder = "sessionFolder"
        static let sessionFile = "sessionFile"
        static let toolbarBehavior = "toolbarBehavior"
        static let pillBehavior = "pillBehavior"
        static let hiddenInspectorSections = "hiddenInspectorSections"
        static let pillFields = "pillFields"
        static let histogramStyle = "histogramStyle"
        static let exportOptions = "exportOptions"
    }

    private let defaults: UserDefaults
    private var isLoading = true

    @Published var zoomMode: ZoomMode = .bestFit { didSet { store(zoomMode.rawValue, Key.zoomMode) } }
    @Published var rememberedScale: CGFloat = 1 { didSet { store(Double(rememberedScale), Key.rememberedScale) } }
    @Published var compareLayout: CompareLayout = .sideBySide { didSet { store(compareLayout.rawValue, Key.compareLayout) } }
    @Published var syncPan = true { didSet { store(syncPan, Key.syncPan) } }
    @Published var syncZoom = true { didSet { store(syncZoom, Key.syncZoom) } }
    @Published var showFilmstrip = true { didSet { store(showFilmstrip, Key.showFilmstrip) } }
    @Published var filmstripPinned = false { didSet { store(filmstripPinned, Key.filmstripPinned) } }
    @Published var loopFolder = true { didSet { store(loopFolder, Key.loopFolder) } }
    @Published var slideshowInterval: Double = 5 { didSet { store(slideshowInterval, Key.slideshowInterval) } }
    @Published var sortOrder: SortOrder = .name { didSet { store(sortOrder.rawValue, Key.sortOrder) } }
    @Published var recursive = false { didSet { store(recursive, Key.recursive) } }
    @Published var animateTransitions = false { didSet { store(animateTransitions, Key.animateTransitions) } }
    @Published var showHUD = true { didSet { store(showHUD, Key.showHUD) } }
    @Published var background: CanvasBackground = .glass { didSet { store(background.rawValue, Key.background) } }
    /// Neighbours decoded ahead on each side.
    @Published var prefetchDepth = 2 { didSet { store(prefetchDepth, Key.prefetchDepth) } }
    @Published var recentFolders: [String] = [] { didSet { store(recentFolders, Key.recentFolders) } }
    /// Launching Pictty on its own reopens the folder and picture you were looking at.
    @Published var restoreSession = true { didSet { store(restoreSession, Key.restoreSession) } }
    @Published var toolbarBehavior: ChromeBehavior = .autoHide { didSet { store(toolbarBehavior.rawValue, Key.toolbarBehavior) } }
    @Published var pillBehavior: ChromeBehavior = .autoHide { didSet { store(pillBehavior.rawValue, Key.pillBehavior) } }
    @Published var hiddenInspectorSections: Set<InspectorSection> = [] {
        didSet { store(hiddenInspectorSections.map(\.rawValue).sorted(), Key.hiddenInspectorSections) }
    }
    /// In the pill's own order, whatever order they were switched on in.
    @Published var pillFields: [PillField] = PillField.standard { didSet { store(pillFields.map(\.rawValue), Key.pillFields) } }
    @Published var histogramStyle: HistogramStyle = .histogram { didSet { store(histogramStyle.rawValue, Key.histogramStyle) } }
    /// The last Save As settings, which the next one starts from.
    @Published var exportOptions = ExportOptions() { didSet { store(try? JSONEncoder().encode(exportOptions), Key.exportOptions) } }

    /// `PICTTY_DEFAULTS_SUITE` keeps a developer's test runs out of the real preferences.
    nonisolated static var store: UserDefaults {
        ProcessInfo.processInfo.environment["PICTTY_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// One set of settings for every window, so a change shows in all of them at once.
    static let shared = Preferences()

    init(defaults: UserDefaults = Preferences.store) {
        self.defaults = defaults
        // Early builds kept the last picture under these names; the session keys replaced them.
        for stale in ["lastFolder", "lastFile"] { defaults.removeObject(forKey: stale) }
        load()
        isLoading = false
    }

    private func store(_ value: Any?, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    private func load() {
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }
        func double(_ k: String, _ d: Double) -> Double { defaults.object(forKey: k) == nil ? d : defaults.double(forKey: k) }

        zoomMode = defaults.string(forKey: Key.zoomMode).flatMap(ZoomMode.init(rawValue:)) ?? .bestFit
        rememberedScale = CGFloat(min(max(double(Key.rememberedScale, 1), 0.02), 32))
        compareLayout = defaults.string(forKey: Key.compareLayout).flatMap(CompareLayout.init(rawValue:)) ?? .sideBySide
        syncPan = bool(Key.syncPan, true)
        syncZoom = bool(Key.syncZoom, true)
        showFilmstrip = bool(Key.showFilmstrip, true)
        filmstripPinned = bool(Key.filmstripPinned, false)
        loopFolder = bool(Key.loopFolder, true)
        slideshowInterval = double(Key.slideshowInterval, 5)
        sortOrder = defaults.string(forKey: Key.sortOrder).flatMap(SortOrder.init(rawValue:)) ?? .name
        recursive = bool(Key.recursive, false)
        animateTransitions = bool(Key.animateTransitions, false)
        showHUD = bool(Key.showHUD, true)
        background = defaults.string(forKey: Key.background).flatMap(CanvasBackground.init(rawValue:)) ?? .glass
        prefetchDepth = min(max(defaults.object(forKey: Key.prefetchDepth) as? Int ?? 2, 0), 6)
        recentFolders = defaults.stringArray(forKey: Key.recentFolders) ?? []
        restoreSession = bool(Key.restoreSession, true)
        toolbarBehavior = defaults.string(forKey: Key.toolbarBehavior).flatMap(ChromeBehavior.init(rawValue:)) ?? .autoHide
        pillBehavior = defaults.string(forKey: Key.pillBehavior).flatMap(ChromeBehavior.init(rawValue:)) ?? .autoHide
        hiddenInspectorSections = Set((defaults.stringArray(forKey: Key.hiddenInspectorSections) ?? []).compactMap(InspectorSection.init(rawValue:)))
        pillFields = defaults.stringArray(forKey: Key.pillFields).map { $0.compactMap(PillField.init(rawValue:)) } ?? PillField.standard
        histogramStyle = defaults.string(forKey: Key.histogramStyle).flatMap(HistogramStyle.init(rawValue:)) ?? .histogram
        exportOptions = defaults.data(forKey: Key.exportOptions).flatMap { try? JSONDecoder().decode(ExportOptions.self, from: $0) } ?? ExportOptions()
    }

    func shows(_ section: InspectorSection) -> Bool { !hiddenInspectorSections.contains(section) }

    func setShows(_ section: InspectorSection, _ on: Bool) {
        if on { hiddenInspectorSections.remove(section) } else { hiddenInspectorSections.insert(section) }
    }

    func shows(_ field: PillField) -> Bool { pillFields.contains(field) }

    func setShows(_ field: PillField, _ on: Bool) {
        let wanted = Set(pillFields).union(on ? [field] : []).subtracting(on ? [] : [field])
        pillFields = PillField.allCases.filter(wanted.contains)
    }

    /// The folder and picture on screen, so the next launch can come back to them.
    func noteSession(folder: URL, file: URL?) {
        guard defaults.string(forKey: Key.sessionFolder) != folder.path || defaults.string(forKey: Key.sessionFile) != file?.path else { return }
        defaults.set(folder.path, forKey: Key.sessionFolder)
        defaults.set(file?.path, forKey: Key.sessionFile)
    }

    /// Where the last session ended, if Pictty should go back there.
    func savedSession() -> (folder: URL, file: URL?)? {
        guard restoreSession, let folder = defaults.string(forKey: Key.sessionFolder) else { return nil }
        return (URL(fileURLWithPath: folder), defaults.string(forKey: Key.sessionFile).map(URL.init(fileURLWithPath:)))
    }

    func noteRecentFolder(_ url: URL) {
        recentFolders = Array(([url.path] + recentFolders.filter { $0 != url.path }).prefix(12))
    }

    func saveWindowFrame(_ frame: CGRect) { defaults.set(NSStringFromRect(frame), forKey: Key.windowFrame) }

    func loadWindowFrame() -> CGRect? {
        guard let raw = defaults.string(forKey: Key.windowFrame) else { return nil }
        let rect = NSRectFromString(raw)
        return rect.isEmpty ? nil : rect
    }
}
