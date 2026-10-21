// The conductor. Owns the window, the canvas, the decode store and the folder, and decides
// what "the current picture at the current zoom" means. The chrome is SwiftUI in exactly-sized
// AppKit hosting views laid over the canvas, so the picture keeps every pixel that is not
// actually a control.

import AppKit
import Combine
import PicttyCore
import SwiftUI
import UniformTypeIdentifiers

final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    static let zoomModes: [ZoomMode] = [.actual, .bestFit, .fitWindow, .remember, .locked]

    let model = ViewerModel()
    let prefs = Preferences.shared
    /// Called once the window has closed, so the app can let go of this controller.
    var onClose: ((ViewerWindowController) -> Void)?
    let display = DisplayEnvironment()

    private(set) var canvas: CanvasView!
    private var glass: NSVisualEffectView?
    let store = ImageStore()
    private var memoryPressure: DispatchSourceMemoryPressure?

    private var hudHost: PassthroughHostingView?
    private var toolbarHost: FadeHostingView?
    private var filmstripHost: FadeHostingView?
    private var inspectorHost: FadeHostingView?
    private var lightHost: FadeHostingView?
    private var nudgeHost: FadeHostingView?

    var probes: [String: ImageProbe] = [:]
    private var probing: Set<String> = []
    private var scanGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var idleTimer: Timer?
    private var slideshowTimer: Timer?
    private var lastPointerLocation: CGPoint = .zero
    private var requestedFull: Set<String> = []
    private var requestedDetail: Set<String> = []
    /// Histogram and clipping per file, and whether it was measured on a RAW's camera preview.
    var analyses: [String: (analysis: ImageAnalysis, embedded: Bool)] = [:]
    private var analysing: Set<String> = []
    /// The picture being edited in the Light panel, if any.
    var lightSession: LightSession?
    var lightAnalysisTicket = 0

    /// The user's own zoom for pane 0 (device pixels per image pixel), or nil to follow the
    /// zoom mode. In Remember mode it survives navigation.
    private var override: CGFloat?

    // MARK: - Init

    convenience init() {
        let window = PicttyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        self.init(window: window)
        configureWindow(window)
        buildInterface()
        wire()
        if let frame = prefs.loadWindowFrame(), frame.width > 240, frame.height > 200 {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        if prefs.zoomMode.keepsZoom { override = prefs.rememberedScale }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = "Pictty"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        window.delegate = self
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .none
        window.isRestorable = false
        window.appearance = NSAppearance(named: .darkAqua)
    }

    private func buildInterface() {
        guard let window else { return }
        let container = DropContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.onDrop = { [weak self] urls in
            // A dropped folder comes with the user's permission; keep it.
            for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { FolderAccess.remember(url) }
            self?.open(urls: urls)
        }

        let glass = NSVisualEffectView(frame: container.bounds)
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        container.addSubview(glass)
        self.glass = glass

        let canvas = CanvasView(frame: container.bounds)
        canvas.autoresizingMask = [.width, .height]
        canvas.delegate = self
        canvas.syncPan = prefs.syncPan
        canvas.syncZoom = prefs.syncZoom
        canvas.compareLayout = prefs.compareLayout
        canvas.animateTransitions = prefs.animateTransitions
        container.addSubview(canvas)
        self.canvas = canvas

        let hud = PassthroughHostingView(rootView: AnyView(HUDOverlay(model: model, prefs: prefs)))
        hud.frame = container.bounds
        hud.autoresizingMask = [.width, .height]
        container.addSubview(hud)
        hudHost = hud

        let nudge = FadeHostingView(rootView: AnyView(DefaultNudgeView { [weak self] in
            Preferences.store.set(true, forKey: DefaultNudgeView.dismissedKey)
            self?.syncChrome()
        }))
        nudge.autoresizingMask = [.width, .maxYMargin]
        nudge.alphaValue = 0
        nudge.isInteractive = false
        container.addSubview(nudge)
        nudgeHost = nudge

        let toolbar = FadeHostingView(rootView: AnyView(ToolbarView(model: model, prefs: prefs, controller: self)))
        toolbar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(toolbar)
        toolbarHost = toolbar

        let strip = FadeHostingView(rootView: AnyView(FilmstripView(model: model, prefs: prefs, controller: self)))
        strip.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(strip)
        filmstripHost = strip

        let inspector = FadeHostingView(rootView: AnyView(InspectorView(model: model, prefs: prefs, controller: self)))
        inspector.autoresizingMask = [.minXMargin, .height]
        inspector.wantsLayer = true
        inspector.alphaValue = 0
        inspector.isInteractive = false
        container.addSubview(inspector)
        inspectorHost = inspector

        let light = FadeHostingView(rootView: AnyView(AdjustPanelView(model: model, prefs: prefs, controller: self)))
        light.autoresizingMask = [.minXMargin, .height]
        light.wantsLayer = true
        light.alphaValue = 0
        light.isInteractive = false
        container.addSubview(light)
        lightHost = light

        window.contentView = container
        container.registerForDraggedTypes([.fileURL])

        model.zoomMode = prefs.zoomMode
        // The strip always auto-hides at least; older builds could switch it off entirely.
        model.showFilmstrip = true
        prefs.showFilmstrip = true
        model.filmstripPinned = prefs.filmstripPinned
        model.showHUD = prefs.showHUD
        display.attach(window: window)
        model.displaySummary = display.summary
        applyBackground()
        syncChrome()
    }

    /// Black, glass (the desktop blurred through the window) or a checkerboard behind transparency.
    private func applyBackground() {
        guard let window, let container = window.contentView else { return }
        let isGlass = prefs.background == .glass
        window.isOpaque = !isGlass
        window.backgroundColor = isGlass ? .clear : .black
        container.layer?.backgroundColor = isGlass ? NSColor.clear.cgColor : NSColor.black.cgColor
        glass?.isHidden = !isGlass
        canvas.background = prefs.background
    }

    @objc func cycleBackground(_ sender: Any?) {
        let all = CanvasBackground.allCases
        setBackground(all[((all.firstIndex(of: prefs.background) ?? 0) + 1) % all.count])
    }

    @objc func setBackgroundFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, CanvasBackground.allCases.indices.contains(item.tag) else { return }
        setBackground(CanvasBackground.allCases[item.tag])
    }

    private func setBackground(_ background: CanvasBackground) {
        prefs.background = background
        applyBackground()
        showToast(L("Background: %@", L(background.title)), symbol: background.symbol)
    }

    private func wire() {
        // Under memory pressure, give back every decode that is not on screen (and on a
        // critical warning, the thumbnails too) rather than slow the whole Mac down.
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let onScreen = Set((0..<self.model.paneCount).compactMap { self.model.item(forPane: $0)?.url })
                self.store.trim(keeping: onScreen)
                if pressure.data.contains(.critical) { ThumbStore.shared.removeAll() }
            }
        }
        pressure.activate()
        memoryPressure = pressure

        display.$headroom
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.model.displaySummary = self.display.summary
            }
            .store(in: &cancellables)

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncChrome() }
            .store(in: &cancellables)
        DefaultViewer.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncChrome() }
            .store(in: &cancellables)

        wirePreferences()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }

        let timer = Timer(timeInterval: Self.idleTick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    // MARK: - Chrome

    func syncChrome() {
        guard let container = window?.contentView else { return }
        let bounds = container.bounds
        toolbarHost?.frame = NSRect(x: 0, y: bounds.maxY - 92, width: bounds.width, height: 92)
        // Floating cards: the inspector hangs below the toolbar. Both frames depend on the window
        // alone: showing or hiding the inspector never resizes a hosting view, because that would
        // lay the whole SwiftUI tree out again on every frame of the animation. The inspector
        // slides on its layer (see `set(_:visible:slide:)`) and the filmstrip makes room for it
        // with an animated padding inside SwiftUI.
        let inspectorWidth: CGFloat = 318
        inspectorHost?.frame = NSRect(x: bounds.maxX - inspectorWidth - 6, y: 0,
                                      width: inspectorWidth, height: max(0, bounds.height - 48))
        lightHost?.frame = inspectorHost?.frame ?? .zero
        filmstripHost?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: FilmstripView.dockedHeight)
        nudgeHost?.frame = NSRect(x: 0, y: 24, width: bounds.width, height: 110)
        // A pinned strip takes its own room: the picture ends at the strip's top edge. The Adjust
        // panel takes its own on the right.
        let canvasFrame = NSRect(x: 0, y: canvasBottomInset, width: max(0, bounds.width - canvasRightInset),
                                 height: max(0, bounds.height - canvasBottomInset))
        if let canvas, canvas.frame != canvasFrame { canvas.frame = canvasFrame }

        if let window {
            let width = max(560, (toolbarHost?.fittingSize.width ?? 0) + 20).rounded(.up)
            let size = NSSize(width: width, height: 340)
            if window.contentMinSize != size {
                window.contentMinSize = size
                window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            }
        }
        updatePaneCaptions()

        set(toolbarHost, visible: !model.items.isEmpty && (model.chromeVisible || prefs.toolbarBehavior == .always))
        set(filmstripHost, visible: model.filmstripVisible)
        set(inspectorHost, visible: model.showInspector, slide: 28)
        set(lightHost, visible: model.showLight, slide: 28)
        set(nudgeHost, visible: model.items.isEmpty && !DefaultViewer.shared.opensJPEG
            && !Preferences.store.bool(forKey: DefaultNudgeView.dismissedKey), duration: 0.4)
    }

    /// What the Adjust panel takes from the right of the window.
    static let adjustPanelWidth: CGFloat = 324
    private var canvasRightInset: CGFloat { model.showLight ? Self.adjustPanelWidth : 0 }

    /// What the pinned filmstrip's bar takes from the bottom of the window; the canvas keeps the rest.
    private var canvasBottomInset: CGFloat {
        model.filmstripPinned && model.filmstripVisible ? FilmstripView.dockedHeight : 0
    }

    /// Fades a floating card in or out. With `slide`, it also drifts that many points to the right
    /// as it goes and back as it comes, on its layer alone: the compositor moves the finished
    /// card, nothing is laid out or drawn again.
    private func set(_ host: FadeHostingView?, visible: Bool, duration: TimeInterval = 0.26, slide: CGFloat = 0) {
        guard let host, host.isInteractive != visible || host.alphaValue == (visible ? 0 : 1) else { return }
        host.isInteractive = visible
        let ease = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = slide > 0 ? 0.32 : duration
            context.timingFunction = slide > 0 ? ease : CAMediaTimingFunction(name: .easeInEaseOut)
            host.animator().alphaValue = visible ? 1 : 0
        }
        guard slide > 0, let layer = host.layer else { return }
        let away = CATransform3DMakeTranslation(slide, 0, 0)
        let from = layer.presentation()?.transform ?? (visible ? away : CATransform3DIdentity)
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = from
        move.toValue = visible ? CATransform3DIdentity : away
        move.duration = 0.32
        move.timingFunction = ease
        // Hidden, the card rests where it went; shown, the animation ends on the layer's own
        // identity transform and can go.
        move.fillMode = .forwards
        move.isRemovedOnCompletion = visible
        layer.add(move, forKey: "slide")
    }

    private func updatePaneCaptions() {
        guard let canvas, model.isComparing, !model.items.isEmpty else {
            if !model.paneCaptions.isEmpty { model.paneCaptions = [] }
            return
        }
        var rects = canvas.paneRects(in: canvas.bounds.size)
        if prefs.compareLayout == .wipe, rects.count == 2 {
            let w = canvas.bounds.width, split = w * canvas.wipeFraction
            rects = [CGRect(x: 0, y: 0, width: split, height: canvas.bounds.height),
                     CGRect(x: split, y: 0, width: w - split, height: canvas.bounds.height)]
        }
        var captions: [ViewerModel.PaneCaption] = []
        for pane in 0..<model.paneCount where pane < rects.count {
            guard let item = model.item(forPane: pane) else { continue }
            if prefs.compareLayout == .blink, model.paneCount == 2, (pane == 1) != canvas.blinkShowsSecond { continue }
            let report = report(for: item)
            var size = report.headline
            if size.isEmpty, let s = canvas.shown(pane: pane)?.pixelSize { size = "\(Int(s.width)) × \(Int(s.height))" }
            var hint = ""
            if isOverlayLayout {
                hint = prefs.compareLayout == .wipe
                    ? (pane == 0 ? L("◀ left of the line") : L("right of the line ▶"))
                    : L("Showing %ld of 2 · press B to flip", pane + 1)
            }
            captions.append(.init(id: pane, rect: rects[pane], ordinal: pane + 1, title: item.displayName, size: size,
                                  exposure: report.exposureLine ?? "", isHDR: report.isHDR,
                                  headroom: report.contentHeadroom, isActive: model.activePane == pane, hint: hint))
        }
        if captions != model.paneCaptions { model.paneCaptions = captions }
    }

    /// The Settings window edits `prefs` directly; each change takes effect here, through the
    /// same paths the keys and the toolbar use. Values set by those paths compare equal and
    /// are ignored.
    private func wirePreferences() {
        func on<T: Equatable>(_ publisher: Published<T>.Publisher, _ apply: @escaping (ViewerWindowController, T) -> Void) {
            publisher.dropFirst().removeDuplicates().receive(on: RunLoop.main)
                .sink { [weak self] value in if let self { apply(self, value) } }
                .store(in: &cancellables)
        }
        on(prefs.$zoomMode) { c, mode in if c.model.zoomMode != mode { c.applyZoomMode(mode) } }
        on(prefs.$background) { c, _ in c.applyBackground() }
        on(prefs.$showHUD) { c, show in c.model.showHUD = show }
        on(prefs.$filmstripPinned) { c, pinned in
            c.model.filmstripPinned = pinned
            if pinned { c.model.showFilmstrip = true; c.prefs.showFilmstrip = true }
            // Best Fit: the window grows by the strip so the picture keeps its size.
            c.fitWindowToPicture(animated: true)
        }
        on(prefs.$toolbarBehavior) { c, _ in
            c.syncChrome()
            c.setChromeVisible(c.model.chromeVisible)
        }
        on(prefs.$animateTransitions) { c, on in c.canvas.animateTransitions = on }
        on(prefs.$sortOrder) { c, _ in c.rescanFolder() }
        on(prefs.$recursive) { c, _ in c.rescanFolder() }
        on(prefs.$syncPan) { c, on in c.canvas.syncPan = on }
        on(prefs.$syncZoom) { c, on in c.canvas.syncZoom = on }
        on(prefs.$compareLayout) { c, layout in if c.canvas.compareLayout != layout, c.model.isComparing { c.setLayout(layout) } }
        on(prefs.$slideshowInterval) { c, _ in
            guard c.slideshowTimer != nil else { return }
            c.slideshowTimer?.invalidate()
            c.slideshowTimer = nil
            c.startSlideshow()
        }
    }

    // MARK: - Opening

    func open(urls: [URL]) {
        guard let first = urls.first?.standardizedFileURL.resolvingSymlinksInPath() else { return }
        FolderAccess.restore(for: first)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory) else {
            showToast(L("Not found: %@", first.lastPathComponent), symbol: "questionmark.folder", tone: .warning)
            return
        }
        if isDirectory.boolValue {
            guard FolderAccess.needsPermission(first) else { return loadFolder(first, selecting: nil) }
            FolderAccess.ask(for: first, on: window) { [weak self] allowed in
                if allowed { self?.loadFolder(first, selecting: nil) }
            }
        } else if ImageFormats.isSupported(first) {
            NSDocumentController.shared.noteNewRecentDocumentURL(first)
            let folder = first.deletingLastPathComponent()
            // In the sandbox the picture shows at once; the rest of its folder follows the user's permission.
            loadFolder(folder, selecting: first)
            if FolderAccess.needsPermission(folder) {
                FolderAccess.ask(for: folder, on: window) { [weak self] allowed in
                    if allowed { self?.loadFolder(folder, selecting: first) }
                }
            }
        } else {
            showToast("Not a picture Pictty can open", symbol: "nosign", tone: .warning)
        }
    }

    /// The folder and picture of the last session, quietly: nothing is said or asked if they
    /// have gone or need a permission Pictty no longer holds.
    func restoreSession(folder: URL, file: URL?) {
        FolderAccess.restore(for: folder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !FolderAccess.needsPermission(folder) else { return }
        loadFolder(folder, selecting: file.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }

    func loadFolder(_ folder: URL, selecting target: URL?) {
        // Another folder or another picture leaves the edits behind: they are settled first.
        if hasUnsavedEdits, folder != model.folderURL || (target != nil && target != model.current?.url) {
            settleEdits { [weak self] in self?.loadFolder(folder, selecting: target) }
            return
        }
        model.isScanning = true
        prefs.noteRecentFolder(folder)

        let order = prefs.sortOrder, recursive = prefs.recursive
        let previousPath = target?.path ?? (model.folderURL == folder ? model.focusedPath : nil)
        scanGeneration &+= 1
        let generation = scanGeneration
        requestedFull.removeAll()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var items = FolderScanner.scan(folder, order: order, recursive: recursive)
            // Paths are compared canonically: `/tmp/x` and `/private/tmp/x` are one file.
            func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
            let wanted = previousPath.map(canonical)
            if let target, !items.contains(where: { canonical($0.url.path) == wanted }) {
                // A file the folder filter skipped but that was opened explicitly.
                items.append(ImageItem(url: target, values: try? target.resourceValues(forKeys: Set(FolderScanner.resourceKeys))))
            }
            let found = wanted.flatMap { w in items.firstIndex { canonical($0.url.path) == w } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.scanGeneration else { return }
                    let sameFolder = self.model.folderURL == folder
                    self.model.replaceItems(items, folder: folder)
                    self.model.setPrimary(found ?? 0)
                    if !sameFolder { self.model.endCompare() }
                    self.model.pruneSelection()
                    self.model.isScanning = false
                    if !sameFolder {
                        self.probes.removeAll()
                        ThumbStore.shared.removeAll()
                    }
                    self.navigated()
                    self.refreshCurrent(animated: false)
                    self.startMetadataPass()
                    if items.isEmpty {
                        self.showToast("No pictures in this folder", symbol: "photo.on.rectangle.angled")
                    }
                }
            }
        }
    }

    func rescanFolder() {
        guard let folder = model.folderURL else { return }
        loadFolder(folder, selecting: model.current?.url)
    }

    // MARK: - Current picture

    /// Puts the selection on the canvas: pane count, reports, decodes, prefetch, chrome.
    func refreshCurrent(animated: Bool) {
        guard let item = model.current else {
            model.report = .empty
            model.compareReport = .empty
            for pane in 0..<ViewerModel.maxPanes { canvas.clear(pane: pane) }
            canvas.setPaneCount(1)
            window?.title = "Pictty"
            syncChrome()
            return
        }
        window?.title = item.fileName
        model.failedPath = nil
        if let folder = model.folderURL { prefs.noteSession(folder: folder, file: item.url) }
        canvas.setPaneCount(model.paneCount)
        canvas.compareLayout = model.paneCount > 2 && prefs.compareLayout.requiresExactlyTwo ? .grid : prefs.compareLayout
        updateReports()

        for pane in 0..<ViewerModel.maxPanes {
            if pane < model.paneCount, let picture = model.item(forPane: pane) {
                if canvas.shown(pane: pane)?.url != picture.url { requestDecode(for: picture, pane: pane, animated: animated) }
            } else if pane > 0 {
                canvas.clear(pane: pane)
            }
        }
        applyZoom(animated: false)

        let url = item.url
        if canvas.shown(pane: 0)?.url != url {
            // Only if nothing at all has arrived after a moment (a RAW normally shows its
            // embedded preview at once and develops in the corner).
            let raw = ImageFormats.isRaw(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.model.current?.url == url, self.canvas.shown(pane: 0)?.url != url,
                      self.model.failedPath != url.path else { return }
                withAnimation(Chrome.spring) {
                    self.model.loadingText = raw ? L("Developing RAW…") : L("Decoding %@…", url.lastPathComponent)
                }
            }
        }
        if !ImageFormats.isRaw(url) { model.rawStatus = nil }
        model.analysis = analyses[url.path]?.analysis
        updateLightAvailability()
        prefetchNeighbours()
        warmThumbnails()
        updateStatus()
        syncChrome()
    }

    /// Resets the per-picture camera after the selection moved.
    private func navigated() {
        endLight()
        model.loadingText = nil
        if !prefs.zoomMode.keepsZoom { override = nil }
    }

    func select(_ index: Int) {
        guard model.items.indices.contains(index), index != model.index else { return }
        guard !hasUnsavedEdits else { return settleEdits { [weak self] in self?.select(index) } }
        model.setPrimary(index)
        model.pruneSelection()
        navigated()
        refreshCurrent(animated: prefs.animateTransitions)
    }

    private func requestDecode(for item: ImageItem, pane: Int, animated: Bool) {
        let url = item.url
        store.load(url, full: false) { [weak self] decoded in
            guard let self else { return }
            guard let decoded else {
                if self.model.current?.url == url {
                    self.model.failedPath = url.path
                    self.model.loadingText = nil
                }
                return
            }
            self.deliver(decoded, animated: animated)
        }
    }

    /// Puts a decode into every pane showing that file. A new picture gets a fresh camera:
    /// the zoom mode's scale, centred, unrotated (Remember mode keeps zoom and centre).
    func deliver(_ d: DecodedImage, animated: Bool) {
        // The picture being edited keeps its edited pixels; sharper decodes go through the Light engine.
        if keepsEdits(d.url) { return }
        CATransaction.begin()
        defer { CATransaction.commit() }
        for pane in 0..<model.paneCount where model.item(forPane: pane)?.url == d.url {
            let isNew = canvas.shown(pane: pane)?.url != d.url
            canvas.deliver(d, pane: pane, animated: animated)
            guard isNew else { continue }
            var vp = canvas.viewport(pane: pane)
            vp.rotation = 0
            vp.mirror = false
            if !prefs.zoomMode.keepsZoom || override == nil { vp.center = CGPoint(x: 0.5, y: 0.5) }
            if pane > 0, prefs.syncPan || isOverlayLayout { vp.center = canvas.viewport(pane: 0).center }
            canvas.setViewport(vp, pane: pane, animated: false)
            applyZoom(animated: false, only: pane)
            if pane == 0 {
                // Lock: the first picture's zoom becomes the zoom for all that follow.
                if prefs.zoomMode == .locked, override == nil {
                    override = canvas.viewport(pane: 0).scale
                    prefs.rememberedScale = override ?? 1
                }
                model.loadingText = nil
                fitWindowToPicture(animated: false)
            }
        }
        analyse(d)
        if model.current?.url == d.url, ImageFormats.isRaw(d.url) {
            if d.isEmbedded {
                withAnimation(Chrome.spring) { model.rawStatus = .developing }
                requestDevelop(d.url)
            } else if model.rawStatus != .developed {
                withAnimation(Chrome.spring) { model.rawStatus = .developed }
            }
        }
        updatePaneCaptions()
        updateStatus()
        updateLightAvailability()
        updateDocumentEdited()
    }

    /// Measures histogram and clipping on a screen-sized decode, once per file (again when a
    /// RAW's real develop replaces its camera preview), off the main thread.
    func analyse(_ d: DecodedImage) {
        let path = d.url.path
        // A picture measured before gets its mask back whatever decode arrives: coming back to
        // it usually delivers the cached full decode, which is never measured itself, and the
        // canvas cleared the mask when the picture changed.
        let known = analyses[path]
        let small = !d.isDetail && max(d.image.width, d.image.height) <= store.previewMaxPixel * 3 / 2
        if let known, !(known.embedded && small && !d.isEmbedded) { publish(known.analysis, for: d.url); return }
        if let known { publish(known.analysis, for: d.url) }
        guard small else { return }
        guard analysing.insert(path).inserted else { return }
        let image = d.image, embedded = d.isEmbedded
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let a = ImageAnalysis.analyze(image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.analysing.remove(path)
                    guard let a else { return }
                    if self.analyses.count > 64 { self.analyses.removeAll() }
                    self.analyses[path] = (a, embedded)
                    self.publish(a, for: d.url)
                }
            }
        }
    }

    func publish(_ a: ImageAnalysis, for url: URL) {
        for pane in 0..<model.paneCount where model.item(forPane: pane)?.url == url {
            canvas.setClipMask(a.mask, pane: pane)
        }
        let active = min(model.activePane, max(0, model.paneCount - 1))
        if model.item(forPane: active)?.url == url { model.analysis = a }
    }

    @objc func toggleClipping(_ sender: Any?) {
        model.showClipping.toggle()
        canvas.showClipping = model.showClipping
        showToast(model.showClipping ? L("Clipping: red = blown highlights, blue = blocked shadows") : L("Clipping warnings off"),
                  symbol: "exclamationmark.triangle", tone: model.showClipping ? .warning : .neutral)
    }

    /// The real RAW develop, replacing the camera's preview when it lands.
    private func requestDevelop(_ url: URL) {
        store.develop(url) { [weak self] d in
            guard let self, let d else { return }
            self.deliver(d, animated: false)
        }
    }

    func requestFullDecode(for url: URL) {
        guard !requestedFull.contains(url.path), store.cached(url, full: true) == nil else { return }
        // A RAW develops at screen size first; a full-size develop on top would only compete with it.
        guard !store.isDeveloping(url) else { return }
        requestedFull.insert(url.path)
        updateStatus()
        // Debounced so a pinch that passes through does not pay for a decode it no longer needs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            // Re-checked after the delay: a new picture's first layout, or a pinch passing
            // through, must not pay for a decode nobody needs any more.
            guard self.canvas.needsFull(url) else {
                self.requestedFull.remove(url.path)
                return
            }
            self.store.load(url, full: true) { [weak self] d in
                guard let self else { return }
                self.requestedFull.remove(url.path)
                if let d { self.deliver(d, animated: false) } else { self.updateStatus() }
            }
        }
    }

    // MARK: - Metadata

    private func report(for item: ImageItem) -> MetadataReport {
        if let p = probes[item.url.path] { return p.report }
        probeLater(item)
        return .empty
    }

    private func probeLater(_ item: ImageItem) {
        let path = item.url.path
        guard probing.insert(path).inserted else { return }
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let probe = MetadataReader.probe(url: item.url, item: item)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.probing.remove(path)
                    guard generation == self.scanGeneration else { return }
                    self.probes[path] = probe
                    self.updateReports()
                }
            }
        }
    }

    private func updateReports() {
        model.report = model.current.map(report(for:)) ?? .empty
        let pane = model.activePane > 0 ? model.activePane : (model.isComparing ? 1 : 0)
        model.compareReport = model.item(forPane: pane).map(report(for:)) ?? .empty
        model.mirrored = canvas.viewport(pane: model.activePane).mirror
        updatePaneCaptions()
    }

    private func startMetadataPass() {
        let items = model.items
        guard !items.isEmpty else { return }
        let focus = model.index
        let generation = scanGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var results: [String: ImageProbe] = [:]
            for item in items[max(0, focus - 12)..<min(items.count, focus + 13)] {
                results[item.url.path] = MetadataReader.probe(url: item.url, item: item)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.scanGeneration else { return }
                    self.probes.merge(results) { old, _ in old }
                    self.updateReports()
                    self.objectsChangedForFilmstrip()
                }
            }
        }
    }

    private func objectsChangedForFilmstrip() { model.objectWillChange.send() }

    func isAnimated(_ item: ImageItem) -> Bool { (probes[item.url.path]?.frameCount ?? 1) > 1 }

    func activePaneChanged() {
        let active = min(model.activePane, max(0, model.paneCount - 1))
        model.analysis = model.item(forPane: active).flatMap { analyses[$0.url.path]?.analysis }
        updateReports()
        updateStatus()
    }

    /// Spinner, inspector footer and zoom label for what is on screen now.
    func updateStatus() {
        let pane = min(model.activePane, max(0, model.paneCount - 1))
        if let s = canvas.shown(pane: 0) {
            let preview = s.preview.map { CGFloat($0.width) } ?? 0
            let needed = s.pixelSize.width * canvas.viewport(pane: 0).scale * 0.98
            model.isProvisional = s.full == nil && preview < needed && store.isLoading(s.url, full: true)
        } else {
            model.isProvisional = false
        }
        if let s = canvas.shown(pane: pane) {
            func dims(_ i: CGImage) -> String { "\(i.width)×\(i.height)" }
            var parts: [String] = []
            if let p = s.preview { parts.append(L("preview %@", dims(p))) }
            if let f = s.full { parts.append(L("full %@", dims(f))) }
            model.decodeSummary = parts.joined(separator: " · ")
            model.renderSummary = canvas.refineInfo(pane: pane)
            if let img = canvas.displayedImage(pane: pane) {
                let name = (img.colorSpace?.name as String?)?.replacingOccurrences(of: "kCGColorSpace", with: "") ?? "—"
                let depth = "\(img.bitsPerComponent)-bit"
                model.colorSpaceSummary = s.isHDR ? "\(name) · \(depth) · HDR" : "\(name) · \(depth)"
            }
        } else {
            model.decodeSummary = ""
            model.renderSummary = ""
        }
        updateZoomLabel()
    }

    // MARK: - Prefetch

    private func prefetchNeighbours() {
        guard model.items.count > 1 else { return }
        let count = model.items.count
        let zoomed = override != nil || prefs.zoomMode == .actual
        var deltas: [Int] = []
        for d in 1...max(1, prefs.prefetchDepth) { deltas += [d, -d] }
        let focused = Set((0..<model.paneCount).compactMap { model.item(forPane: $0)?.url })
        for (n, d) in deltas.enumerated() {
            let url = model.items[((model.index + d) % count + count) % count].url
            guard !focused.contains(url) else { continue }
            store.load(url, full: zoomed && n < 2, urgent: false) { [weak self] d in
                // The pictures either side are developed too, so arriving shows the real RAW.
                if n < 2, d?.isEmbedded == true { self?.store.develop(url, urgent: false) { _ in } }
            }
        }
    }

    private func warmThumbnails() {
        guard model.showFilmstrip, !model.items.isEmpty else { return }
        let slice = model.items[max(0, model.index - 32)..<min(model.items.count, model.index + 33)].map(\.url)
        Task.detached(priority: .utility) {
            for url in slice { _ = await ThumbStore.shared.thumb(url) }
        }
    }

    // MARK: - Navigation

    @objc func nextImage(_ sender: Any?) { step(1) }
    @objc func previousImage(_ sender: Any?) { step(-1) }
    @objc func firstImage(_ sender: Any?) { jump(toStart: true) }
    @objc func lastImage(_ sender: Any?) { jump(toStart: false) }

    private func step(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        if model.isComparing, !NSEvent.modifierFlags.contains(.command) {
            movePane(delta, pane: model.activePane)
        } else if model.isComparing {
            moveAllPanes(delta)
        } else {
            movePrimary(delta)
        }
    }

    private func movePrimary(_ delta: Int) {
        guard model.items.count > 1 else { return }
        guard let next = model.advance(delta, loop: prefs.loopFolder) else {
            showToast(delta > 0 ? "End of folder" : "Start of folder", symbol: "arrow.turn.down.left")
            return
        }
        if (delta > 0 && next < model.index) || (delta < 0 && next > model.index) {
            showToast(delta > 0 ? "Back to the first picture" : "On to the last picture", symbol: "arrow.triangle.2.circlepath")
        }
        select(next)
    }

    private func movePane(_ delta: Int, pane: Int) {
        guard let current = model.index(forPane: pane) else { return }
        if pane == 0, hasUnsavedEdits { return settleEdits { [weak self] in self?.movePane(delta, pane: pane) } }
        let count = model.items.count
        let taken = Set((0..<model.paneCount).compactMap { model.index(forPane: $0) })
        var next = current
        for _ in 0..<count {
            next += delta
            if prefs.loopFolder { next = ((next % count) + count) % count }
            guard model.items.indices.contains(next) else { return }
            if !taken.contains(next) { break }
        }
        guard !taken.contains(next) else { return }
        if pane == 0 {
            model.setPrimary(next)
        } else {
            model.compareIndices[pane - 1] = next
        }
        model.pruneSelection()
        navigated()
        refreshCurrent(animated: prefs.animateTransitions)
    }

    private func moveAllPanes(_ delta: Int) {
        guard let next = model.advance(delta, loop: prefs.loopFolder) else { return }
        if hasUnsavedEdits { return settleEdits { [weak self] in self?.moveAllPanes(delta) } }
        let shift = next - model.index, count = model.items.count
        model.setPrimary(next)
        model.compareIndices = model.compareIndices.map { (($0 + shift) % count + count) % count }
        model.pruneSelection()
        navigated()
        refreshCurrent(animated: prefs.animateTransitions)
    }

    private func jump(toStart: Bool) {
        guard !model.items.isEmpty else { return }
        select(toStart ? 0 : model.items.count - 1)
    }

    // MARK: - Zoom

    /// Applies the zoom mode (or the user's own zoom) to every pane, or just one.
    private func applyZoom(animated: Bool, only: Int? = nil) {
        guard let canvas else { return }
        let mode = prefs.zoomMode
        let syncedOverride = override != nil && (prefs.syncZoom || isOverlayLayout)
        for pane in 0..<model.paneCount where only == nil || only == pane {
            guard let fit = canvas.fitScale(pane: pane) else { continue }
            var vp = canvas.viewport(pane: pane)
            if pane == 0 {
                vp.scale = ZoomMath.scale(mode: mode, override: override, fit: fit)
            } else if syncedOverride, let o0 = canvas.orientedSize(pane: 0), let oi = canvas.orientedSize(pane: pane), oi.width > 0 {
                vp.scale = canvas.viewport(pane: 0).scale * o0.width / oi.width
            } else {
                vp.scale = ZoomMath.scale(mode: mode, override: nil, fit: fit)
            }
            vp.scale = min(max(vp.scale, ZoomMath.steps[0]), ZoomMath.steps[ZoomMath.steps.count - 1])
            canvas.setViewport(vp, pane: pane, animated: animated)
        }
        updateZoomLabel()
    }

    private var isOverlayLayout: Bool { model.paneCount == 2 && prefs.compareLayout.requiresExactlyTwo }

    func applyZoomMode(_ mode: ZoomMode) {
        prefs.zoomMode = mode
        model.zoomMode = mode
        override = mode.keepsZoom && canvas.shown(pane: 0) != nil ? canvas.viewport(pane: 0).scale : nil
        if let override, mode.keepsZoom { prefs.rememberedScale = override }
        if !mode.keepsZoom { recentre() }
        applyZoom(animated: true)
        fitWindowToPicture(animated: true)
        showToast(mode.title, symbol: mode.symbol)
    }

    private func recentre() {
        for pane in 0..<model.paneCount {
            var vp = canvas.viewport(pane: pane)
            vp.center = CGPoint(x: 0.5, y: 0.5)
            canvas.setViewport(vp, pane: pane, animated: false)
        }
    }

    @objc func setZoomModeFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, Self.zoomModes.indices.contains(item.tag) else { return }
        applyZoomMode(Self.zoomModes[item.tag])
    }

    @objc func zoomIn(_ sender: Any?) { zoomStep(up: true) }
    @objc func zoomOut(_ sender: Any?) { zoomStep(up: false) }

    private func zoomStep(up: Bool) {
        let pane = min(model.activePane, model.paneCount - 1)
        guard canvas.shown(pane: pane) != nil else { return }
        let target = ZoomMath.step(from: canvas.viewport(pane: pane).scale, up: up)
        let rects = canvas.paneRects(in: canvas.bounds.size)
        guard rects.indices.contains(pane) else { return }
        let r = rects[pane]
        canvas.zoom(pane: pane, to: target, about: CGPoint(x: r.midX, y: r.midY), animated: true)
        userZoomed()
        // Best Fit: zoom from the keyboard, menus or toolbar takes the window along, up to the
        // screen. A pinch keeps the window.
        fitWindowToPicture(animated: true, scale: override)
        showToast(model.zoomLabel, symbol: up ? "plus.magnifyingglass" : "minus.magnifyingglass")
    }

    /// A zoom picked from the toolbar's menu, about the centre of the active pane.
    func zoom(toPercent percent: Int) {
        let pane = min(model.activePane, model.paneCount - 1)
        guard canvas.shown(pane: pane) != nil else { return }
        let rects = canvas.paneRects(in: canvas.bounds.size)
        guard rects.indices.contains(pane) else { return }
        let r = rects[pane]
        canvas.zoom(pane: pane, to: CGFloat(percent) / 100, about: CGPoint(x: r.midX, y: r.midY), animated: true)
        userZoomed()
        fitWindowToPicture(animated: true, scale: override)
        showToast(model.zoomLabel, symbol: "plus.magnifyingglass")
    }

    /// Z and two-finger double-tap: 100 % about the pointer, or back to the mode.
    @objc func toggleActualSize(_ sender: Any?) {
        var point = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        if let w = window {
            let p = canvas.convert(w.mouseLocationOutsideOfEventStream, from: nil)
            if canvas.bounds.contains(p) { point = p }
        }
        smartZoom(pane: canvas.paneIndex(at: point), at: point)
    }

    private func smartZoom(pane: Int, at point: CGPoint) {
        guard canvas.shown(pane: pane) != nil else { return }
        if abs(canvas.viewport(pane: pane).scale - 1) < 0.001 {
            override = prefs.zoomMode == .actual ? canvas.fitScale(pane: 0) : nil
            if override == nil || !prefs.zoomMode.keepsZoom { recentre() }
            applyZoom(animated: true)
            fitWindowToPicture(animated: true)
        } else {
            canvas.zoom(pane: pane, to: 1, about: point, animated: true)
            userZoomed()
            fitWindowToPicture(animated: true, scale: override)
        }
        showToast(model.zoomLabel, symbol: "1.magnifyingglass")
    }

    @objc func resetZoom(_ sender: Any?) {
        override = nil
        recentre()
        applyZoom(animated: true)
        fitWindowToPicture(animated: true)
        showToast(prefs.zoomMode.title, symbol: prefs.zoomMode.symbol)
    }

    /// The user zoomed or panned by hand: that zoom now wins over the mode.
    private func userZoomed() {
        let wasFollowingMode = override == nil
        override = canvas.viewport(pane: 0).scale
        if prefs.zoomMode.keepsZoom { prefs.rememberedScale = override ?? 1 }
        updateZoomLabel()
        updateStatus()
        // Neighbours switch to full decodes once, when the zoom becomes the user's, not on
        // every event of a pinch.
        if wasFollowingMode { prefetchNeighbours() }
    }

    /// Best Fit: the window takes the picture's real size, shrunk to the screen, keeping its centre.
    /// With `scale`, the size of the picture at that zoom instead.
    func fitWindowToPicture(animated: Bool, scale: CGFloat? = nil) {
        guard prefs.zoomMode == .bestFit, override == nil || scale != nil, !model.isComparing, let window,
              !window.styleMask.contains(.fullScreen), let o = canvas.orientedSize(pane: 0),
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let b = screen.backingScaleFactor
        let points = CGSize(width: o.width / b, height: o.height / b)
        // The picture fits in what the pinned strip leaves; the window adds the strip back.
        let strip = model.filmstripPinned && model.showFilmstrip && model.items.count > 1 ? FilmstripView.dockedHeight : 0
        let panel = canvasRightInset
        let room = CGSize(width: visible.width - panel, height: visible.height - strip)
        let minimum = CGSize(width: max(0, window.contentMinSize.width - panel), height: max(0, window.contentMinSize.height - strip))
        var size = scale.map { ZoomMath.bestFitContentSize(imagePoints: points, scale: $0, visible: room, minimum: minimum) }
            ?? ZoomMath.bestFitContentSize(imagePoints: points, visible: room, minimum: minimum)
        size.height += strip
        size.width += panel
        var f = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        f.origin.x = min(max(window.frame.midX - f.width / 2, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(window.frame.midY - f.height / 2, visible.minY), visible.maxY - f.height)
        f = f.integral
        guard f != window.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                window.animator().setFrame(f, display: true)
            }
        } else {
            window.setFrame(f, display: true, animate: false)
        }
    }

    private func updateZoomLabel() {
        guard canvas.shown(pane: 0) != nil else { model.zoomLabel = "—"; return }
        let p = canvas.viewport(pane: 0).scale * 100
        let label = p < 10 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%"
        if model.zoomLabel != label { model.zoomLabel = label }
    }

    // MARK: - Transform

    @objc func rotateRight(_ sender: Any?) { rotate(by: 1) }
    @objc func rotateLeft(_ sender: Any?) { rotate(by: -1) }

    func rotate(by steps: Int) {
        let pane = min(model.activePane, model.paneCount - 1)
        guard canvas.shown(pane: pane) != nil else { return }
        var vp = canvas.viewport(pane: pane)
        vp.rotation = ((vp.rotation + steps) % 4 + 4) % 4
        vp.center = CGPoint(x: 0.5, y: 0.5)
        // The new framing is worked out first so the turn and the refit are one animation.
        if override == nil, let fit = canvas.fitScale(pane: pane, rotation: vp.rotation) {
            vp.scale = ZoomMath.scale(mode: prefs.zoomMode, override: nil, fit: fit)
        }
        canvas.setViewport(vp, pane: pane, animated: true)
        updateZoomLabel()
        fitWindowToPicture(animated: true)
        showToast(steps > 0 ? "Rotated right" : "Rotated left", symbol: steps > 0 ? "rotate.right" : "rotate.left")
        updateDocumentEdited()
    }

    @objc func toggleMirror(_ sender: Any?) {
        let pane = min(model.activePane, model.paneCount - 1)
        guard canvas.shown(pane: pane) != nil else { return }
        var vp = canvas.viewport(pane: pane)
        vp.mirror.toggle()
        canvas.setViewport(vp, pane: pane, animated: true)
        model.mirrored = vp.mirror
        updateDocumentEdited()
        showToast(vp.mirror ? "Mirrored" : "Mirror off", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
    }

    // MARK: - Panels

    @objc func toggleInspector(_ sender: Any?) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            model.showInspector.toggle()
            // One card on the right at a time; the Light panel has its own histogram.
            if model.showInspector { model.showLight = false }
        }
        updateStatus()
        revealChrome()
    }

    /// T: pinned, or back to auto-hide (it appears at the bottom edge and goes away by itself).
    @objc func toggleFilmstrip(_ sender: Any?) {
        model.showFilmstrip = true
        model.filmstripPinned.toggle()
        if !model.filmstripPinned { model.filmstripRevealed = false }
        prefs.showFilmstrip = true
        prefs.filmstripPinned = model.filmstripPinned
        warmThumbnails()
        showToast(model.filmstripPinned ? "Filmstrip pinned" : "Filmstrip auto-hides",
                  symbol: model.filmstripPinned ? "pin" : "rectangle.bottomthird.inset.filled")
    }

    @objc func toggleShortcuts(_ sender: Any?) {
        withAnimation(Chrome.spring) { model.showShortcuts.toggle() }
    }

    @objc func toggleHUD(_ sender: Any?) {
        prefs.showHUD.toggle()
        model.showHUD = prefs.showHUD
        showToast(prefs.showHUD ? "Info pill on" : "Info pill off", symbol: "text.bubble")
    }

    // MARK: - Compare

    @objc func toggleCompare(_ sender: Any?) {
        if model.isComparing {
            model.endCompare()
            showToast("Comparison cleared", symbol: "rectangle")
        } else {
            guard model.items.count > 1 else {
                showToast("Need at least two pictures", symbol: "rectangle.split.2x1")
                return
            }
            model.beginCompare(with: model.index + 1 < model.items.count ? model.index + 1 : model.index - 1)
            showToast("Two-up  ·  ⌘-click to add, ⇧-click for a range", symbol: "rectangle.split.2x1")
        }
        refreshCurrent(animated: true)
        fitWindowToPicture(animated: true)
    }

    /// Compares the current picture with the one at `index` (the screenshot and video script).
    func compare(with index: Int) {
        guard model.items.indices.contains(index), index != model.index else { return }
        if model.isComparing { model.endCompare() }
        model.beginCompare(with: index)
        refreshCurrent(animated: true)
    }

    /// D: start comparing with the next picture, or add the next one to the comparison.
    func compareNext() { model.isComparing ? addNextToComparison() : toggleCompare(nil) }

    private func addNextToComparison() {
        guard !model.items.isEmpty else { return }
        if model.paneCount >= ViewerModel.maxPanes {
            model.endCompare()
            showToast("Comparison cleared", symbol: "rectangle")
            refreshCurrent(animated: true)
            return
        }
        let taken = Set((0..<model.paneCount).compactMap { model.index(forPane: $0) })
        let count = model.items.count
        for offset in 1..<max(2, count) {
            let candidate = (model.index + offset) % count
            if !taken.contains(candidate) {
                model.toggleCompare(with: candidate)
                showToast(L("%ld-up sync view", model.paneCount), symbol: model.paneCount > 2 ? "square.grid.2x2" : "rectangle.split.2x1")
                refreshCurrent(animated: true)
                return
            }
        }
    }

    @objc func cycleCompareLayout(_ sender: Any?) {
        guard model.isComparing else {
            showToast("Start a comparison first (D)", symbol: "rectangle.split.2x1")
            return
        }
        let order = CompareLayout.allCases.filter { !($0.requiresExactlyTwo && model.paneCount > 2) }
        let next = order[((order.firstIndex(of: prefs.compareLayout) ?? -1) + 1) % order.count]
        setLayout(next)
        showToast(Self.layoutToast(next), symbol: next.symbol)
    }

    /// What each layout is for, said where it is chosen.
    private static func layoutToast(_ layout: CompareLayout) -> String {
        switch layout {
        case .sideBySide: "Side by side"
        case .stacked: "Top & bottom"
        case .grid: "Grid"
        case .wipe: "Wipe · one picture over the other, drag the line"
        case .blink: "Blink · stacked, press B to flip between them"
        }
    }

    private func setLayout(_ layout: CompareLayout) {
        prefs.compareLayout = layout
        canvas.blinkShowsSecond = false
        refreshCurrent(animated: false)
        if override == nil { applyZoom(animated: false) } else { canvas.propagate(from: 0, force: isOverlayLayout) }
    }

    /// B: switch to blink, or flip between the two pictures.
    @objc func blink(_ sender: Any?) {
        guard model.isComparing else {
            showToast("Start a comparison first (D)", symbol: "rectangle.split.2x1")
            return
        }
        guard model.paneCount == 2 else {
            showToast("Blink needs exactly two pictures", symbol: "square.on.square.dashed", tone: .warning)
            return
        }
        if prefs.compareLayout != .blink {
            setLayout(.blink)
            showToast(Self.layoutToast(.blink), symbol: "square.on.square.dashed")
            return
        }
        canvas.blinkShowsSecond.toggle()
        updatePaneCaptions()
        revealChrome()
    }

    @objc func toggleSyncPan(_ sender: Any?) {
        prefs.syncPan.toggle()
        canvas.syncPan = prefs.syncPan
        showToast(prefs.syncPan ? "Pan synced" : "Pan independent", symbol: "arrow.left.and.right")
    }

    @objc func toggleSyncZoom(_ sender: Any?) {
        prefs.syncZoom.toggle()
        canvas.syncZoom = prefs.syncZoom
        showToast(prefs.syncZoom ? "Zoom synced" : "Zoom independent", symbol: "magnifyingglass")
    }

    // MARK: - Slideshow

    @objc func toggleSlideshow(_ sender: Any?) {
        slideshowTimer == nil ? startSlideshow() : stopSlideshow()
    }

    private func startSlideshow() {
        guard model.items.count > 1 else { return }
        let timer = Timer(timeInterval: max(1, prefs.slideshowInterval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.movePrimary(1) }
        }
        RunLoop.main.add(timer, forMode: .common)
        slideshowTimer = timer
        model.slideshowRunning = true
        showToast(L("Slideshow · every %lds", Int(prefs.slideshowInterval)), symbol: "play.rectangle")
    }

    private func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        model.slideshowRunning = false
        showToast("Slideshow stopped", symbol: "stop.rectangle")
    }

    // MARK: - File actions

    private var targetItem: ImageItem? { model.item(forPane: model.activePane) ?? model.current }

    /// The file itself (Finder pastes a copy) and its encoded bytes (editors paste the picture).
    @objc func copyCurrentImage(_ sender: Any?) {
        guard let item = targetItem else { return }
        let entry = NSPasteboardItem()
        entry.setString(item.url.absoluteString, forType: .fileURL)
        if let type = UTType(filenameExtension: item.url.pathExtension), let data = try? Data(contentsOf: item.url, options: .mappedIfSafe) {
            entry.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([entry])
        showToast(L("Copied %@", item.fileName), symbol: "doc.on.doc", tone: .success)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let item = targetItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc func openInDefaultApp(_ sender: Any?) {
        guard let item = targetItem else { return }
        NSWorkspace.shared.open(item.url)
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let item = targetItem else { return }
        if item.url == model.current?.url, hasUnsavedEdits { return settleEdits { [weak self] in self?.moveToTrash(sender) } }
        NSWorkspace.shared.recycle([item.url]) { [weak self] _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        self.showToast(error.localizedDescription, symbol: "exclamationmark.triangle", tone: .error)
                        return
                    }
                    self.store.forget(item.url)
                    self.probes.removeValue(forKey: item.url.path)
                    if let i = self.model.items.firstIndex(of: item) { self.model.remove(at: i) }
                    for pane in 0..<ViewerModel.maxPanes where self.canvas.shown(pane: pane)?.url == item.url {
                        self.canvas.clear(pane: pane)
                    }
                    self.navigated()
                    self.refreshCurrent(animated: true)
                    self.showToast(L("Moved %@ to Trash", item.fileName), symbol: "trash")
                }
            }
        }
    }

    @objc func presentOpenPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ImageFormats.typeIdentifiers.compactMap { UTType($0) } + [.folder]
        panel.prompt = L("Open")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FolderAccess.remember(url)
        open(urls: [url])
    }

    @objc func presentOpenFolderPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = L("Open Folder")
        panel.message = L("Choose a folder of pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FolderAccess.remember(url)
        loadFolder(url, selecting: nil)
    }

    func revealChrome() {
        if !model.chromeVisible { setChromeVisible(true) }
        idleSeconds = 0
        if !model.captionsVisible { model.captionsVisible = true }
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags.contains(.command) {
            switch chars {
            case "+", "=": zoomIn(nil); return true
            case "-", "_": zoomOut(nil); return true
            case "0" where flags == .command: resetZoom(nil); return true
            default: return false
            }
        }
        guard flags.subtracting(.shift).isEmpty else { return false }

        switch event.keyCode {
        case 123: step(-1); return true
        case 124: step(1); return true
        case 125: return nudge(1)
        case 126: return nudge(-1)
        case 36, 76: window?.toggleFullScreen(nil); return true   // Return, keypad Enter: like F
        case 115: jump(toStart: true); return true
        case 119: jump(toStart: false); return true
        case 48:
            guard model.isComparing else { return false }
            model.activePane = (model.activePane + 1) % model.paneCount
            activePaneChanged()
            showToast(L("Pane %ld active", model.activePane + 1), symbol: "cursorarrow.rays")
            return true
        case 53:
            if model.showShortcuts { toggleShortcuts(nil) }
            else if model.isComparing { toggleCompare(nil) }
            else if model.pickingWhite { toggleWhitePicker(nil) }
            else if model.showLight { toggleLight(nil) }
            else if model.showInspector { toggleInspector(nil) }
            else if slideshowTimer != nil { stopSlideshow() }
            else if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
            // Nothing left to dismiss: Esc does nothing more. ⌘W closes the window, ⌘Q quits.
            return true
        default: break
        }

        switch chars {
        case " ": flags.contains(.shift) ? step(-1) : step(1)
        case "1", "2", "3", "4", "5": applyZoomMode(Self.zoomModes[Int(chars)! - 1])
        case "z", "Z": toggleActualSize(nil)
        case "i", "I": toggleInspector(nil)
        case "e", "E": toggleLight(nil)
        case "\\": toggleOriginal(nil)
        case "t", "T": toggleFilmstrip(nil)
        case "s", "S": toggleSlideshow(nil)
        case "d", "D": compareNext()
        case "b", "B": blink(nil)
        case "l", "L": cycleCompareLayout(nil)
        case "p": toggleSyncPan(nil)
        case "P": toggleSyncZoom(nil)
        case "m", "M": toggleMirror(nil)
        case "]": rotateRight(nil)
        case "[": rotateLeft(nil)
        case "?": toggleShortcuts(nil)
        case "j", "J": toggleClipping(nil)
        case "/": toggleHUD(nil)
        case "f", "F": window?.toggleFullScreen(nil)
        case "g", "G": cycleBackground(nil)
        case "o": presentOpenPanel(nil)
        default: return false
        }
        return true
    }

    /// ↑/↓ pan a picture larger than its pane.
    private func nudge(_ direction: CGFloat) -> Bool {
        let pane = min(model.activePane, model.paneCount - 1)
        guard canvas.isPannable(pane: pane) else { return false }
        var vp = canvas.viewport(pane: pane)
        vp.center.y += direction * 0.06
        canvas.setViewport(vp, pane: pane, animated: true)
        canvas.propagate(from: pane, animated: true)
        return true
    }

    // MARK: - Idle

    private var idleSeconds: TimeInterval = 0
    /// The strip was put away for idleness; it stays away until the pointer moves.
    private var filmstripRested = false
    private static let idleTick: TimeInterval = 0.1
    private static let chromeGrace: TimeInterval = 2.5
    private static let captionGrace: TimeInterval = 7

    private func tickIdle() {
        guard let window, window.isKeyWindow else { return }
        updateFilmstripReveal(in: window)
        let location = NSEvent.mouseLocation
        let moved = hypot(location.x - lastPointerLocation.x, location.y - lastPointerLocation.y) > 1.5
        lastPointerLocation = location
        if moved {
            filmstripRested = false
            revealChrome()
            return
        }
        idleSeconds += Self.idleTick
        // A revealed (not pinned) strip goes away with the rest of the chrome, a little later
        // when the pointer is resting on the thumbnails themselves.
        if model.filmstripRevealed, !model.filmstripPinned {
            let p = window.convertPoint(fromScreen: location)
            let onStrip = p.y >= 0 && p.y <= 132
            if idleSeconds > (onStrip ? Self.captionGrace : Self.chromeGrace) {
                filmstripRested = true
                withAnimation(.easeOut(duration: 0.25)) { model.filmstripRevealed = false }
            }
        }
        if idleSeconds > Self.chromeGrace, model.chromeVisible, !model.showInspector, !model.showLight, !model.items.isEmpty,
           !(model.filmstripRevealed && !filmstripRested) {
            setChromeVisible(false)
            if window.styleMask.contains(.fullScreen) { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        if idleSeconds > Self.captionGrace, model.captionsVisible { model.captionsVisible = false }
    }

    private func updateFilmstripReveal(in window: NSWindow) {
        guard model.showFilmstrip, model.items.count > 1, !model.filmstripPinned else {
            if model.filmstripRevealed { model.filmstripRevealed = false }
            return
        }
        let p = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let threshold: CGFloat = model.filmstripRevealed ? 140 : 90
        let near = !filmstripRested && p.y <= threshold && p.y >= -24 && p.x >= 0 && p.x <= window.frame.width
        if near != model.filmstripRevealed {
            withAnimation(.easeOut(duration: 0.2)) { model.filmstripRevealed = near }
            if near { warmThumbnails() }
        }
    }

    private func setChromeVisible(_ visible: Bool) {
        model.chromeVisible = visible
        // The window's buttons come and go with the toolbar, and stay when it stays.
        let buttons = visible || prefs.toolbarBehavior == .always
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(kind)?.animator().alphaValue = buttons ? 1 : 0
            }
        }
    }

    /// `text` is shown in the user's language (an English key, or already translated).
    func showToast(_ text: String, symbol: String? = nil, tone: ToastMessage.Tone = .neutral) {
        let message = ToastMessage(text: L(text), symbol: symbol, tone: tone)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { model.toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.model.toast?.id == message.id else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.model.toast = nil }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) { syncChrome() }

    func windowDidChangeScreen(_ notification: Notification) {
        if let window { display.attach(window: window) }
        fitWindowToPicture(animated: false)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { revealChrome() }
    func windowDidExitFullScreen(_ notification: Notification) { fitWindowToPicture(animated: true) }

    func windowDidBecomeKey(_ notification: Notification) { window?.makeFirstResponder(canvas) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedEdits else { return true }
        settleEdits { [weak sender] in sender?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let frame = window?.frame { prefs.saveWindowFrame(frame) }
        slideshowTimer?.invalidate()
        idleTimer?.invalidate()
        onClose?(self)
    }
}

// MARK: - CanvasDelegate

extension ViewerWindowController: CanvasDelegate {
    func canvasRequestsStep(_ delta: Int, pane: Int) {
        if model.isComparing, !isOverlayLayout { model.activePane = pane }
        step(delta)
    }

    func canvasViewportChanged(pane: Int) {
        if model.isComparing, !isOverlayLayout, model.activePane != pane {
            model.activePane = pane
            updateReports()
        }
        userZoomed()
    }

    func canvasNeedsFull(_ url: URL) {
        if keepsEdits(url) { return requestEditedFull(url) }
        requestFullDecode(for: url)
    }

    func canvasNeedsDetail(_ url: URL) {
        if keepsEdits(url) { return }
        guard !requestedDetail.contains(url.path), store.cachedDetail(url) == nil else { return }
        requestedDetail.insert(url.path)
        // Debounced and re-checked like the full decode: this one can be gigabytes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            guard self.canvas.needsDetail(url) else { self.requestedDetail.remove(url.path); return }
            self.showToast("Loading every pixel…", symbol: "square.grid.3x3.fill")
            self.store.loadDetail(url) { [weak self] d in
                guard let self else { return }
                self.requestedDetail.remove(url.path)
                guard let d else { return }
                self.deliver(d, animated: false)
                self.showToast(L("Full detail · %ld × %ld", Int(d.pixelSize.width), Int(d.pixelSize.height)),
                               symbol: "checkmark.seal", tone: .success)
            }
        }
    }
    func canvasToggleFullScreen() { window?.toggleFullScreen(nil) }

    func canvasSmartZoom(pane: Int, at point: CGPoint) { smartZoom(pane: pane, at: point) }

    func canvasDidResize() {
        if override == nil { applyZoom(animated: false) }
        updatePaneCaptions()
    }

    func canvasRefined(pane: Int) {
        if pane == min(model.activePane, model.paneCount - 1) { model.renderSummary = canvas.refineInfo(pane: pane) }
    }

    func canvasWipeMoved() { updatePaneCaptions() }

    func canvasPicked(_ point: CGPoint) { pickedWhite(at: point) }

    func canvasRotateGesture(_ quarterTurns: Int) { rotate(by: quarterTurns) }

    func canvasPickedColour(_ hex: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        showToast(L("Copied %@", hex), symbol: "eyedropper", tone: .success)
    }

    func canvasContextMenu(pane: Int) -> NSMenu? {
        guard model.item(forPane: pane) != nil else { return nil }
        if model.isComparing, model.activePane != pane, !isOverlayLayout {
            model.activePane = pane
            activePaneChanged()
        }
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        add("Copy Image", "doc.on.doc", #selector(copyCurrentImage(_:)))
        add("Reveal in Finder", "folder", #selector(revealInFinder(_:)))
        add("Open in Default App", "arrow.up.forward.app", #selector(openInDefaultApp(_:)))
        menu.addItem(.separator())
        add("Actual Size / Back", "1.magnifyingglass", #selector(toggleActualSize(_:)))
        add("Rotate Left", "rotate.left", #selector(rotateLeft(_:)))
        add("Rotate Right", "rotate.right", #selector(rotateRight(_:)))
        add("Mirror", "arrow.left.and.right.righttriangle.left.righttriangle.right", #selector(toggleMirror(_:)))
        menu.addItem(.separator())
        add(model.isComparing ? "Clear Comparison" : "Compare", "rectangle.split.2x1", #selector(toggleCompare(_:)))
        add("Show Information", "info.circle", #selector(toggleInspector(_:)))
        menu.addItem(.separator())
        add("Move to Trash", "trash", #selector(moveToTrash(_:)))
        return menu
    }
}

// MARK: - Hosting views

/// Never intercepts the mouse. Used for the text-only HUD.
final class PassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A chrome panel. AppKit's own hit testing does the rest; this only refuses clicks while faded out.
final class FadeHostingView: NSHostingView<AnyView> {
    var isInteractive = true
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive, alphaValue > 0.01, !isHidden else { return nil }
        return super.hitTest(point)
    }
}

final class DropContainerView: NSView {
    var onDrop: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { isValid(sender) ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { isValid(sender) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = readURLs(sender), !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
    private func isValid(_ sender: NSDraggingInfo) -> Bool { !(readURLs(sender)?.isEmpty ?? true) }
    private func readURLs(_ sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }
}

final class PicttyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
