import AppKit
import ImageIO
import PicttyCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Every open window; the first one is where the developer hooks act.
    private var controllers: [ViewerWindowController] = []
    private var controller: ViewerWindowController? { controllers.first }
    /// The window menu commands and opened files go to: the key one, else the last used.
    private var current: ViewerWindowController? {
        controllers.first { $0.window?.isKeyWindow == true }
            ?? controllers.first { $0.window?.isMainWindow == true } ?? controllers.last
    }
    private var pendingOpen: [URL] = []
    private let launchPath: String?
    private let recentMenu = NSMenu(title: "Open Recent")

    init(launchPath: String?) {
        self.launchPath = launchPath
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        let controller = makeWindow()

        // Files handed over by Finder / `open -a Pictty`, or on the command line.
        if !pendingOpen.isEmpty {
            controller.open(urls: pendingOpen)
            pendingOpen.removeAll()
        } else if let launchPath {
            controller.open(urls: [URL(fileURLWithPath: launchPath)])
        } else if let session = Preferences.shared.savedSession() {
            // Launched on its own: back to the folder and picture of last time. Files from
            // Finder arrive before this point and start a fresh session instead.
            controller.restoreSession(folder: session.folder, file: session.file)
        }
        // Developer hooks for screenshots: launch without taking focus, with panels open.
        let env = ProcessInfo.processInfo.environment
        if env["PICTTY_BACKGROUND"] != "1" { NSApp.activate(ignoringOtherApps: true) }
        if let script = env["PICTTY_SCRIPT"] { DevScript.run(script, controller: controller, app: self) }
        if let show = env["PICTTY_SHOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                for part in show.split(separator: ",") {
                    switch part {
                    case "compare": controller.toggleCompare(nil)
                    case "inspector": controller.toggleInspector(nil)
                    case "filmstrip": controller.toggleFilmstrip(nil)
                    case "settings": self.showSettings()
                    case "inside":
                        self.showSettings(at: .inside)
                    case "defaults": self.showSettings(at: .defaults)
                    case "information": self.showSettings(at: .information)
                    case "about": self.showAbout()
                    case "clipping": controller.toggleClipping(nil)
                    case "loupe":
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            let b = controller.canvas.bounds
                            controller.canvas.showLoupe(at: CGPoint(x: b.midX * 0.9, y: b.midY * 0.8))
                        }
                    case "shortcuts": controller.toggleShortcuts(nil)
                    case "loading": controller.model.loadingText = "Developing RAW…"
                    case "light": controller.toggleLight(nil)
                    case let light where light.hasPrefix("light="):
                        // light=<exposure>/<contrast>/<brightness>/<highlights>/<shadows>[/<temperature>/<tint>[/<balance>]]
                        //   [;algos=<highlights><shadows>][;grade=<hue>:<amount>/<hue>:<amount>/<hue>:<amount>]
                        let parts = light.dropFirst(6).split(separator: ";").map(String.init)
                        let f = parts[0].split(separator: "/").map(String.init)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            var a = Adjustments()
                            let order: [AdjustmentControl] = AdjustmentControl.light + [.temperature, .tint, .balance]
                            for (i, c) in order.enumerated() where i < f.count { c.set(Double(f[i]) ?? 0, in: &a) }
                            for extra in parts.dropFirst() {
                                if extra.hasPrefix("algos="), extra.count >= 8 {
                                    let d = Array(extra.dropFirst(6)).compactMap { Int(String($0)) }
                                    if d.count == 2 { a.highlightsAlgorithm = d[0]; a.shadowsAlgorithm = d[1] }
                                } else if extra.hasPrefix("grade=") {
                                    for (range, g) in zip(ToneRange.allCases, extra.dropFirst(6).split(separator: "/")) {
                                        let v = g.split(separator: ":").compactMap { Double($0) }
                                        if v.count == 2 { range.set(ColourShift(hue: v[0], amount: v[1]), in: &a) }
                                    }
                                }
                            }
                            controller.setLight(a)
                        }
                    case let crop where crop.hasPrefix("crop@"):
                        // crop@<seconds>[:<ratio id>[:<radius>]]: starts cropping, picks a ratio, rounds the corners.
                        let spec = crop.dropFirst(5).split(separator: ":").map(String.init)
                        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(spec[0]) ?? 2)) {
                            controller.startCrop()
                            if spec.count > 1 { controller.setCropRatio(CropRatio.with(id: spec[1])) }
                            if spec.count > 2, let r = Double(spec[2]) { controller.setCropRadius(r) }
                        }
                    case let done where done.hasPrefix("cropdone@"):
                        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(done.dropFirst(9)) ?? 4)) { controller.commitCrop() }
                    case let auto where auto.hasPrefix("autowb@"):
                        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(auto.dropFirst(7)) ?? 2)) { controller.autoWhiteBalance(nil) }
                    case let turn where turn.hasPrefix("rotate@"):
                        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(turn.dropFirst(7)) ?? 2)) { controller.rotateRight(nil) }
                    case "stress":
                        // Every slider and algorithm at 60 Hz for four seconds, zooming to 100 % and
                        // back and flipping before/after on the way, the way hands do it.
                        var tick = 0
                        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
                            MainActor.assumeIsolated {
                                tick += 1
                                var a = controller.model.light
                                let c = AdjustmentControl.allCases[tick % 5]
                                c.set(sin(Double(tick) / 9) * (c == .exposure ? 3 : 1), in: &a)
                                if tick % 23 == 0 { c.setAlgorithm(tick % 3 + 1, in: &a) }
                                controller.setLight(a)
                                if tick % 70 == 0 { controller.applyZoomMode(tick % 140 == 0 ? .bestFit : .actual) }
                                if tick % 45 == 0 { controller.toggleOriginal(nil) }
                                if tick > 240 { timer.invalidate(); NSLog("stress done") }
                            }
                        }
                    case let save where save.hasPrefix("save@") || save.hasPrefix("saveas@"):
                        // Save, or the Save As sheet, after a delay.
                        let delay = Double(save.split(separator: "@").last ?? "") ?? 4
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            save.hasPrefix("saveas") ? controller.saveEditsAs(nil) : controller.saveEdits(nil)
                        }
                    case let view where view.hasPrefix("adjustview="):
                        // The whole Adjust panel, unscrolled, as a PNG: adjustview=<path>[@seconds]
                        let spec = view.dropFirst(11).split(separator: "@")
                        DispatchQueue.main.asyncAfter(deadline: .now() + (spec.count > 1 ? Double(spec[1]) ?? 4 : 4)) {
                            let host = NSHostingView(rootView: AdjustPanelView(model: controller.model, prefs: Preferences.shared,
                                                                               controller: controller)
                                .frame(width: 318, height: 1500))
                            host.frame = CGRect(x: 0, y: 0, width: 318, height: 1500)
                            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                            window.isReleasedWhenClosed = false
                            window.backgroundColor = .black
                            window.contentView = host
                            window.orderBack(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                                host.cacheDisplay(in: host.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(spec[0])))
                                window.close()
                            }
                        }
                    case let view where view.hasPrefix("exportview="):
                        // The Save As settings on their own, as a PNG: exportview=<path>[@<format>]
                        let spec = view.dropFirst(11).split(separator: "@")
                        var o = ExportOptions()
                        if spec.count > 1, let f = ExportFormat(rawValue: String(spec[1])) { o.format = f }
                        let settings = ExportSettings(options: o, isHDR: true, hasAlpha: true,
                                                      pixelSize: CGSize(width: 6000, height: 4000), edited: true)
                        let host = NSHostingView(rootView: ExportSettingsView(settings: settings))
                        host.appearance = NSAppearance(named: .aqua)
                        host.frame.size = host.fittingSize
                        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                        // ARC owns it; AppKit releasing it again on close crashed the run loop.
                        window.isReleasedWhenClosed = false
                        window.contentView = host
                        window.orderBack(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                            host.cacheDisplay(in: host.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(spec[0])))
                            window.close()
                        }
                    case let dump where dump.hasPrefix("dump="):
                        // The picture the canvas shows, as a PNG: dump=<path>[@seconds]
                        let spec = dump.dropFirst(5).split(separator: "@")
                        DispatchQueue.main.asyncAfter(deadline: .now() + (spec.count > 1 ? Double(spec[1]) ?? 4 : 4)) {
                            guard let image = controller.canvas.shown(pane: 0)?.preview,
                                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: String(spec[0])) as CFURL,
                                                                             "public.png" as CFString, 1, nil) else { return }
                            CGImageDestinationAddImage(dest, image, nil)
                            CGImageDestinationFinalize(dest)
                        }
                    case let all where all.hasPrefix("snapall="):
                        // Every window, as <prefix>-<n>.png.
                        let prefix = String(all.dropFirst(8))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            for (n, w) in NSApp.windows.enumerated() where w.isVisible {
                                guard let view = w.contentView,
                                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                                view.cacheDisplay(in: view.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?
                                    .write(to: URL(fileURLWithPath: "\(prefix)-\(n).png"))
                            }
                        }
                    case let snap where snap.hasPrefix("snap="):
                        // Renders the window's chrome to a PNG, wherever the window is.
                        // snap=<path>[@seconds]
                        let spec = snap.dropFirst(5).split(separator: "@")
                        let path = String(spec[0])
                        let delay = spec.count > 1 ? Double(spec[1]) ?? 3.5 : 3.5
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard let view = controller.window?.contentView,
                                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                            view.cacheDisplay(in: view.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                        }
                    case let later where later.hasPrefix("inspector@"):
                        // Toggles the inspector again after a delay, to watch it go.
                        let delay = Double(later.dropFirst(10)) ?? 3
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { controller.toggleInspector(nil) }
                    case let step where step.hasPrefix("next@") || step.hasPrefix("prev@"):
                        // Moves to the next or previous picture after a delay.
                        let delay = Double(step.dropFirst(5)) ?? 2
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            step.hasPrefix("next") ? controller.nextImage(nil) : controller.previousImage(nil)
                        }
                    case let route where route.hasPrefix("finder="):
                        // What a double-click in Finder does: finder=<path>@<seconds>.
                        let spec = route.dropFirst(7).split(separator: "@")
                        let delay = spec.count > 1 ? Double(spec[1]) ?? 1.5 : 1.5
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.application(NSApp, open: [URL(fileURLWithPath: String(spec[0]))])
                        }
                    case let open where open.hasPrefix("open="):
                        // What a drop does: open a file from somewhere else.
                        let path = String(open.dropFirst(5))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            controller.open(urls: [URL(fileURLWithPath: path)])
                        }
                    default: break
                    }
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !controllers.isEmpty else { pendingOpen.append(contentsOf: urls); return }
        windowFor(urls).open(urls: urls)
    }

    /// Where a picture opened from Finder goes: the window already showing its folder (it is
    /// selected there), else an empty window, else a new one, so the pictures you were looking
    /// at stay where they were.
    private func windowFor(_ urls: [URL]) -> ViewerWindowController {
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        if let first = urls.first {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory)
            let folder = canonical(isDirectory.boolValue ? first : first.deletingLastPathComponent())
            if let showing = controllers.first(where: { $0.model.folderURL.map(canonical) == folder }) {
                showing.window?.makeKeyAndOrderFront(nil)
                return showing
            }
        }
        if let empty = controllers.first(where: { $0.model.items.isEmpty }) {
            empty.window?.makeKeyAndOrderFront(nil)
            return empty
        }
        return makeWindow()
    }

    /// A new viewer window, cascaded from the frontmost one.
    @discardableResult
    private func makeWindow() -> ViewerWindowController {
        let controller = ViewerWindowController()
        if let front = current?.window, let window = controller.window {
            window.setFrame(front.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        controller.onClose = { [weak self] closed in
            // Let go after AppKit has finished closing the window.
            DispatchQueue.main.async { self?.controllers.removeAll { $0 === closed } }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Edits only on screen are settled first, one window at a time; then quitting asks again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let edited = controllers.first(where: \.hasUnsavedEdits) else { return .terminateNow }
        edited.window?.makeKeyAndOrderFront(nil)
        edited.settleEdits(cancelled: { sender.reply(toApplicationShouldTerminate: false) }) {
            sender.reply(toApplicationShouldTerminate: false)
            DispatchQueue.main.async { sender.terminate(nil) }
        }
        return .terminateLater
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()
        typealias C = ViewerWindowController

        func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: L(title))
            build(menu)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) {
            // The icon is looked up by the English title, then the title is shown translated.
            let item = menu.addItem(withTitle: L(title), action: action, keyEquivalent: key)
            if let name = Self.symbols[title] { item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil) }
            item.keyEquivalentModifierMask = mods
            item.tag = tag
        }

        _ = submenu("Pictty") { m in
            add(m, "About Pictty", #selector(showAbout)); m.items.last?.target = self
            m.addItem(.separator())
            add(m, "Settings…", #selector(showSettings as () -> Void), ","); m.items.last?.target = self
            add(m, "Make Pictty the Default Viewer…", #selector(showDefaultViewer)); m.items.last?.target = self
            m.addItem(.separator())
            add(m, "Hide Pictty", #selector(NSApplication.hide(_:)), "h")
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            add(m, "Quit Pictty", #selector(NSApplication.terminate(_:)), "q")
        }

        _ = submenu("File") { m in
            add(m, "Open…", #selector(C.presentOpenPanel(_:)), "o")
            add(m, "Open Folder…", #selector(C.presentOpenFolderPanel(_:)), "o", [.command, .option])
            let recent = NSMenuItem(title: L("Open Recent"), action: nil, keyEquivalent: "")
            recent.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            recentMenu.delegate = self
            recent.submenu = recentMenu
            m.addItem(recent)
            m.addItem(.separator())
            add(m, "Save", #selector(C.saveEdits(_:)), "s")
            add(m, "Save As…", #selector(C.saveEditsAs(_:)), "s", [.command, .shift])
            add(m, "Revert to Original", #selector(C.revertEdits(_:)))
            m.addItem(.separator())
            add(m, "Copy Image", #selector(C.copyCurrentImage(_:)), "c")
            add(m, "Reveal in Finder", #selector(C.revealInFinder(_:)), "r")
            add(m, "Open With Default App", #selector(C.openInDefaultApp(_:)), "o", [.command, .shift])
            m.addItem(.separator())
            add(m, "Move to Trash", #selector(C.moveToTrash(_:)), "\u{8}")
            m.addItem(.separator())
            add(m, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        }

        _ = submenu("View") { m in
            for (i, mode) in ViewerWindowController.zoomModes.enumerated() {
                add(m, mode.title, #selector(C.setZoomModeFromMenu(_:)), "\(i + 1)", tag: i)
            }
            m.addItem(.separator())
            add(m, "Zoom In", #selector(C.zoomIn(_:)), "+")
            add(m, "Zoom Out", #selector(C.zoomOut(_:)), "-")
            add(m, "Actual Size / Back", #selector(C.toggleActualSize(_:)), "z", [])
            add(m, "Reset Zoom", #selector(C.resetZoom(_:)), "0")
            m.addItem(.separator())

            let background = NSMenuItem(title: L("Background"), action: nil, keyEquivalent: "")
            background.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
            let bm = NSMenu(title: L("Background"))
            for (i, b) in CanvasBackground.allCases.enumerated() {
                add(bm, b.title, #selector(C.setBackgroundFromMenu(_:)), tag: i)
                bm.items.last?.image = NSImage(systemSymbolName: b.symbol, accessibilityDescription: nil)
            }
            add(bm, "Next Background", #selector(C.cycleBackground(_:)), "g", [])
            background.submenu = bm
            m.addItem(background)
            m.addItem(.separator())

            add(m, "Rotate Right", #selector(C.rotateRight(_:)), "]", [])
            add(m, "Rotate Left", #selector(C.rotateLeft(_:)), "[", [])
            add(m, "Mirror", #selector(C.toggleMirror(_:)), "m", [])
            m.addItem(.separator())
            add(m, "Show Filmstrip", #selector(C.toggleFilmstrip(_:)), "t", [])
            add(m, "Show Information", #selector(C.toggleInspector(_:)), "i", [])
            add(m, "Adjust", #selector(C.toggleLight(_:)), "e", [])
            add(m, "Crop", #selector(C.toggleCrop(_:)), "c", [])
            add(m, "Show Original", #selector(C.toggleOriginal(_:)), "y", [])
            add(m, "Show Info Pill", #selector(C.toggleHUD(_:)), "/", [])
            add(m, "Clipping Warnings", #selector(C.toggleClipping(_:)), "j", [])
            m.addItem(.separator())
            add(m, "Compare", #selector(C.toggleCompare(_:)), "d", [])
            add(m, "Cycle Compare Layout", #selector(C.cycleCompareLayout(_:)), "l", [])
            add(m, "Blink", #selector(C.blink(_:)), "b", [])
            add(m, "Sync Pan", #selector(C.toggleSyncPan(_:)), "p", [])
            add(m, "Sync Zoom", #selector(C.toggleSyncZoom(_:)), "p", [.shift])
            m.addItem(.separator())
            add(m, "Slideshow", #selector(C.toggleSlideshow(_:)), "s", [])
            add(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }

        _ = submenu("Go") { m in
            add(m, "Next Image", #selector(C.nextImage(_:)), "\u{F703}", [])
            add(m, "Previous Image", #selector(C.previousImage(_:)), "\u{F702}", [])
            add(m, "First Image", #selector(C.firstImage(_:)), "\u{F729}", [])
            add(m, "Last Image", #selector(C.lastImage(_:)), "\u{F72B}", [])
        }

        let window = submenu("Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
        }
        NSApp.windowsMenu = window

        let help = submenu("Help") { m in
            add(m, "Keyboard Shortcuts", #selector(C.toggleShortcuts(_:)), "?", [])
            add(m, "Inside Pictty", #selector(showInsidePictty)); m.items.last?.target = self
            m.addItem(.separator())
            add(m, "Pictty Website", #selector(openWebsite)); m.items.last?.target = self
            add(m, "More Apps at noxdrop.com", #selector(openNoxdrop)); m.items.last?.target = self
        }
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    /// A symbol for every command, so the menus read at a glance.
    private static let symbols: [String: String] = [
        "About Pictty": "info.circle", "Settings…": "gearshape", "Hide Pictty": "eye.slash",
        "Hide Others": "rectangle.on.rectangle.slash", "Show All": "rectangle.on.rectangle", "Quit Pictty": "power",
        "Open…": "photo.badge.plus", "Open Folder…": "folder", "Open Recent": "clock.arrow.circlepath",
        "Copy Image": "doc.on.doc", "Reveal in Finder": "finder", "Open With Default App": "arrow.up.forward.app",
        "Move to Trash": "trash", "Close Window": "xmark.rectangle",
        "Actual Size": "1.square", "Best Fit": "arrow.up.left.and.arrow.down.right",
        "Fit to Window": "arrow.up.left.and.down.right.magnifyingglass", "Remember Zoom": "pin", "Lock Zoom & Window": "lock",
        "Zoom In": "plus.magnifyingglass", "Zoom Out": "minus.magnifyingglass",
        "Actual Size / Back": "1.magnifyingglass", "Reset Zoom": "arrow.counterclockwise",
        "Background": "circle.lefthalf.filled", "Next Background": "arrow.triangle.2.circlepath",
        "Rotate Right": "rotate.right", "Rotate Left": "rotate.left",
        "Mirror": "arrow.left.and.right.righttriangle.left.righttriangle.right",
        "Show Filmstrip": "rectangle.bottomthird.inset.filled", "Show Information": "info.circle",
        "Show Info Pill": "text.bubble", "Compare": "rectangle.split.2x1",
        "Cycle Compare Layout": "square.grid.2x2", "Blink": "square.on.square.dashed",
        "Sync Pan": "arrow.left.and.right", "Sync Zoom": "magnifyingglass", "Slideshow": "play.rectangle",
        "Enter Full Screen": "arrow.up.left.and.arrow.down.right.circle",
        "Next Image": "chevron.right", "Previous Image": "chevron.left",
        "First Image": "backward.end", "Last Image": "forward.end",
        "Minimize": "minus.rectangle", "Zoom": "plus.rectangle", "Keyboard Shortcuts": "keyboard", "Make Pictty the Default Viewer…": "checkmark.seal", "Inside Pictty": "sparkles", "Pictty Website": "safari", "More Apps at noxdrop.com": "square.grid.2x2", "Clipping Warnings": "exclamationmark.triangle",
        "Save": "square.and.arrow.down", "Save As…": "square.and.arrow.down.on.square", "Adjust": "slider.horizontal.3",
        "Show Original": "rectangle.lefthalf.inset.filled", "Revert to Original": "arrow.uturn.backward", "Crop": "crop",
    ]

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let recents = Preferences.shared.recentFolders
        for path in recents {
            let item = menu.addItem(withTitle: (path as NSString).lastPathComponent,
                                    action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = path
            item.toolTip = path
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.target = self
        }
        if recents.isEmpty { menu.addItem(withTitle: L("No Recent Folders"), action: nil, keyEquivalent: "") }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        current?.open(urls: [URL(fileURLWithPath: path)])
    }

    @objc private func showAbout() { AuxWindows.showAbout() }

    @objc private func showSettings() {
        AuxWindows.showSettings(prefs: Preferences.shared)
    }

    @objc func showDefaultViewer() { showSettings(at: .defaults) }

    @objc func showInsidePictty() { showSettings(at: .inside) }

    @objc func openWebsite() { NSWorkspace.shared.open(URL(string: "https://www.noxdrop.com/pictty.html")!) }

    @objc func openNoxdrop() { NSWorkspace.shared.open(URL(string: "https://noxdrop.com")!) }

    func showSettings(at section: SettingsView.Section) {
        SettingsRouter.shared.section = section
        showSettings()
    }
}
