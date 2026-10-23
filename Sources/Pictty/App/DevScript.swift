// Developer hook for screenshots and the demo video: a timed tour.
//   PICTTY_SCRIPT="1 next; 2.5 zoom 150; 4 reset; 5 loupe 0.4 0.5 0.6 0.4 2; …"
// Each step is "<seconds from launch> <action> [arguments]". Fractions are of the canvas.

import AppKit
import ImageIO

@MainActor
enum DevScript {
    static func run(_ script: String, controller c: ViewerWindowController, app: AppDelegate) {
        for step in script.split(separator: ";") {
            let words = step.split(separator: " ").map(String.init)
            guard words.count >= 2, let time = Double(words[0]) else { continue }
            let action = words[1]
            let n = words.dropFirst(2).compactMap(Double.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                perform(action, n, words.dropFirst(2).joined(separator: " "), c, app)
            }
        }
    }

    private static func perform(_ action: String, _ n: [Double], _ text: String,
                                _ c: ViewerWindowController, _ app: AppDelegate) {
        let canvas = c.canvas!
        func point(_ fx: Double, _ fy: Double) -> CGPoint {
            CGPoint(x: canvas.bounds.width * fx, y: canvas.bounds.height * fy)
        }
        switch action {
        case "open": c.open(urls: [URL(fileURLWithPath: (text as NSString).expandingTildeInPath)])
        case "next": c.nextImage(nil)
        case "prev": c.previousImage(nil)
        case "select": if let i = n.first { c.select(Int(i)) }
        case "mode": if let m = n.first { c.applyZoomMode(ViewerWindowController.zoomModes[Int(m) - 1]) }
        case "zoom": if let p = n.first { c.zoom(toPercent: Int(p)) }
        case "zoomin": c.zoomIn(nil)
        case "zoomout": c.zoomOut(nil)
        case "reset": c.resetZoom(nil)
        case "actual": c.toggleActualSize(nil)
        case "inspector": c.toggleInspector(nil)
        case "clipping": c.toggleClipping(nil)
        case "filmstrip": c.toggleFilmstrip(nil)
        case "shortcuts": c.toggleShortcuts(nil)
        case "hud": c.toggleHUD(nil)
        case "compare": c.toggleCompare(nil)
        case "add": c.compareNext()
        case "comparewith": if let i = n.first { c.compare(with: Int(i)) }
        case "layoutset": if let l = CompareLayout(rawValue: text) { c.prefs.compareLayout = l }
        case "layout": c.cycleCompareLayout(nil)
        case "blink": c.blink(nil)
        case "background": c.cycleBackground(nil)
        case "rotate": c.rotateRight(nil)
        case "print": c.printPicture(nil)
        case "printgo": c.printSession?.onPrint?()
        case "printphoto":
            // printphoto <i>: the i-th photo size of the open Print sheet.
            if let s = c.printSession, let i = n.first, s.photoSizes.indices.contains(Int(i)) {
                s.settings.sizing = .photo(s.photoSizes[Int(i)].size)
            }
        case "printfill": c.printSession?.settings.sizing = .fillPage
        case "printfit": c.printSession?.settings.sizing = .fitPage
        case "printupscale": c.printSession?.settings.upscale = (n.first ?? 1) != 0
        case "printcaption": c.printSession?.settings.caption = .details
        case "printmove":
            // printmove <dx> <dy>: the frame moved by points on the paper.
            if let s = c.printSession, n.count >= 2 {
                s.layout.center = s.layout.clamped(CGPoint(x: s.layout.center.x + n[0], y: s.layout.center.y + n[1]))
            }
        case "wipe":
            // wipe <to> [<from> <seconds>]: the split line, gliding when a duration is given.
            guard let to = n.first else { return }
            if n.count >= 3 { glide(seconds: n[2]) { t in canvas.wipeFraction = n[1] + (to - n[1]) * ease(t) } }
            else { canvas.wipeFraction = to }
        case "loupe":
            // loupe <x> <y> [<x2> <y2> <seconds>]
            guard n.count >= 2 else { return }
            if n.count >= 5 {
                glide(seconds: n[4]) { t in
                    let e = ease(t)
                    canvas.showLoupe(at: point(n[0] + (n[2] - n[0]) * e, n[1] + (n[3] - n[1]) * e))
                }
            } else {
                canvas.showLoupe(at: point(n[0], n[1]))
            }
        case "loupeoff": canvas.hideLoupe()
        case "settings":
            app.showSettings(at: SettingsView.Section(rawValue: text) ?? .viewing)
        case "closeaux": NSApp.windows.filter { $0 !== c.window && $0.isVisible }.forEach { $0.close() }
        case "reveal": c.revealChrome()
        case "focus": c.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        case "state":
            print("state items=\(c.model.items.count) folder=\(c.model.folderURL?.path ?? "-") sheet=\(c.window?.attachedSheet != nil) sandbox=\(FolderAccess.isSandboxed) frame=\(c.window.map { NSStringFromRect($0.frame) } ?? "-") zoom=\(c.model.zoomLabel)")
            fflush(stdout)
        case "snapshot":
            // snapshot <path>: what the canvas shows of the picture, as a PNG, for checking edits.
            if let image = canvas.displayedImage(pane: 0),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: (text as NSString).expandingTildeInPath) as CFURL,
                                                          "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    private static func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    /// Calls `body` with 0…1 at display rate for `seconds`.
    private static func glide(seconds: Double, _ body: @escaping @MainActor (Double) -> Void) {
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
            MainActor.assumeIsolated {
                let t = min(1, (CACurrentMediaTime() - start) / max(seconds, 0.01))
                body(t)
                if t >= 1 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
