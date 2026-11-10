// Developer hook for screenshots and the demo video: a timed tour.
//   PICTTY_SCRIPT="1 next; 2.5 zoom 150; 4 reset; 5 loupe 0.4 0.5 0.6 0.4 2; …"
// Each step is "<seconds from launch> <action> [arguments]". Fractions are of the canvas.

import AppKit
import ImageIO
import PicttyCore
import SwiftUI

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
        case "comparepicker": c.model.comparePickerOpen.toggle()
        case "comparelayout": if let l = CompareLayout(rawValue: text) { c.compare(layout: l) }
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
        case "printmax": c.printSession?.maximize()
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
            print("state items=\(c.model.items.count) folder=\(c.model.folderURL?.path ?? "-") sheet=\(c.window?.attachedSheet != nil) sandbox=\(FolderAccess.isSandboxed) frame=\(c.window.map { NSStringFromRect($0.frame) } ?? "-") zoom=\(c.model.zoomLabel) comparing=\(c.model.isComparing) chrome=\(c.model.chromeVisible) strip=\(c.model.comparePickerOpen) enlargestrip=\(c.model.enlargePickerOpen)")
            fflush(stdout)
        case "snapshot":
            // snapshot <path>: what the canvas shows of the picture, as a PNG, for checking edits.
            if let image = canvas.displayedImage(pane: 0),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: (text as NSString).expandingTildeInPath) as CFURL,
                                                          "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        case "exposure":
            // exposure <ev>: the Exposure slider.
            if let ev = n.first { var a = c.model.light; a.exposure = ev; c.setLight(a) }
        case "crop": c.startCrop()
        case "cropbox":
            // cropbox <x> <y> <w> <h>: the crop frame being drawn, in 0…1 of the stored picture.
            if n.count >= 4 { c.model.cropDraft.rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]); c.updateCropOverlay() }
        case "cropdone": c.commitCrop()
        case "save": c.saveEdits(nil)
        case "saveto":
            // saveto <path>: Save As a JPEG there, without the panel.
            if let url = c.model.current?.url {
                var o = c.prefs.exportOptions
                o.format = text.hasSuffix(".png") ? .png : .jpeg
                c.export(url, to: URL(fileURLWithPath: text), options: o, then: nil, cancelled: nil)
            }
        case "dump":
            // dump: the edit state and what the canvas shows, on stdout.
            let s = canvas.shown(pane: 0)
            print("dump url=\(s?.url.lastPathComponent ?? "-") px=\(s.map { "\($0.pixelSize)" } ?? "-") preview=\(s?.preview.map { "\($0.width)x\($0.height)" } ?? "-") full=\(s?.full.map { "\($0.width)x\($0.height)" } ?? "-") light=\(c.model.light.exposure) crop=\(c.model.crop.map { "\($0.rect)" } ?? "-") edited=\(c.hasUnsavedEdits) enlarge=\(c.model.enlarge.map(String.init) ?? "-") enlarging=\(c.model.enlargeProgress.map { String(format: "%.2f", $0) } ?? "-") refusal=\(c.enlargeRefusal.map { "\($0)" } ?? "-") size=[\(c.model.report.headline)] anns=\(c.model.annotations.count) kinds=\(c.model.annotations.map(\.kind.rawValue).joined(separator: ",")) ovHidden=\(c.annotationOverlay?.isHidden ?? true) ovBase=\(c.annotationOverlay?.base != nil) um=\(c.window?.undoManager != nil) canUndo=\(c.canUndoAnnotation) cur=\(c.model.current?.url.lastPathComponent ?? "-") annotating=\(c.model.annotating) bg=\(c.model.background.map { "\($0)" } ?? "-") masking=\(c.model.maskWorking) mp=[\(c.model.report.subheadline)] session=\(c.lightSession != nil) frame=\(c.window.map { NSStringFromRect($0.frame) } ?? "-") win=\(c.window?.windowNumber ?? 0)")
            fflush(stdout)
        case "shot":
            // shot <path>: every visible window's layers as drawn (path, path-1, …), without a capture permission.
            for (k, window) in NSApp.windows.filter(\.isVisible).enumerated() {
                guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { continue }
                let scale = window.backingScaleFactor
                let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
                guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                ctx.scaleBy(x: scale, y: scale)
                if view.isFlipped { ctx.translateBy(x: 0, y: view.bounds.height); ctx.scaleBy(x: 1, y: -1) }
                layer.render(in: ctx)
                let path = window === c.window ? text : text.replacingOccurrences(of: ".png", with: "-\(k).png")
                if let image = ctx.makeImage(),
                   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    CGImageDestinationFinalize(dest)
                }
            }
        case "upscalefile":
            // upscalefile <in> <out.png> <factor>: Enlarge on a file, timed, with the memory it took.
            let parts = text.split(separator: " ").map(String.init)
            guard parts.count >= 3, let factor = Int(parts[2]), let decoded = ImageDecoder.full(URL(fileURLWithPath: parts[0])) else {
                print("upscale: needs <in> <out> <factor>"); fflush(stdout); return
            }
            let before = footprint()
            DispatchQueue.global(qos: .userInitiated).async {
                let t = CFAbsoluteTimeGetCurrent()
                // Sampled every 50 ms on its own thread, so no stage between progress reports is missed.
                final class Peak: @unchecked Sendable { var value: UInt64 = 0; var running = true }
                let peak = Peak()
                peak.value = before
                Thread.detachNewThread {
                    while peak.running { peak.value = max(peak.value, footprint()); Thread.sleep(forTimeInterval: 0.05) }
                }
                let out = NeuralUpscaler.shared.enlarge(decoded.image, factor: factor)
                peak.running = false
                let dt = CFAbsoluteTimeGetCurrent() - t
                if let out, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: parts[1]) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, out, nil)
                    CGImageDestinationFinalize(dest)
                }
                print(String(format: "upscale %d×%d → %@ in %.2f s, %.2f GB above the start", decoded.image.width, decoded.image.height,
                             out.map { "\($0.width)×\($0.height)" } ?? "nil", dt, Double(peak.value - before) / 1e9))
                fflush(stdout)
            }
        case "enlarge":
            // enlarge <0|2|4>: Enlarge off, 2× or 4×.
            if let f = n.first { c.setEnlarge(f == 0 ? nil : Int(f)) }
        case "original": c.toggleOriginal(nil)
        case "resize":
            // resize <w> <h>: Image Size without the sheet; resize 0 0 takes it off.
            if n.count >= 2 { c.setResize(n[0] > 0 ? CGSize(width: n[0], height: n[1]) : nil) }
        case "imagesize": c.showImageSize(nil)
        case "annotate": c.toggleAnnotate(nil)
        case "tipshot":
            // tipshot <path>: a bottom bar 100 high with a tooltip forced on over its second button.
            let bar = HStack(spacing: 3) {
                ForEach(0..<6) { i in
                    RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.4)).frame(width: 27, height: 25)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: TooltipKey.self, value: i == 1
                                ? TooltipRequest(text: "Arrow (A) · drag its middle to curve it",
                                                 midX: g.frame(in: .named(ToolbarView.coordinateSpace)).midX) : nil)
                        })
                }
            }
            .padding(6)
            .background(Capsule().fill(.black.opacity(0.5)))
            .bottomBarTooltips()
            .frame(width: 600, height: 100)
            .background(Color(white: 0.75))
            let r = ImageRenderer(content: bar)
            r.scale = 2
            if let image = r.cgImage, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: text) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        case "overlayshot":
            // overlayshot <path>: the annotation layer as it draws itself on screen.
            if let o = c.annotationOverlay, let rep = o.bitmapImageRepForCachingDisplay(in: o.bounds) {
                o.cacheDisplay(in: o.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: text))
            }
        case "barshot":
            // barshot <path>: the annotation bar, and the toolbar, drawn on their own over a grey.
            let view = VStack(spacing: 12) {
                AnnotationToolbarView(model: c.model, controller: c).frame(height: 56)
                ToolbarView(model: c.model, prefs: c.prefs, controller: c).frame(height: 70)
            }
            .frame(width: 1200, height: 160)
            .background(Color(white: 0.3))
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let image = r.cgImage, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: text) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        case "ann":
            // ann <kind> <x1> <y1> [<x2> <y2>] [text…]: a mark, in 0…1 of the picture before the crop.
            let w = text.split(separator: " ").map(String.init)
            guard let kind = w.first.flatMap(Annotation.Kind.init(rawValue:)), w.count >= 3,
                  let x1 = Double(w[1]), let y1 = Double(w[2]) else { return }
            let x2 = w.count >= 5 ? Double(w[3]) : nil, y2 = w.count >= 5 ? Double(w[4]) : nil
            var item = Annotation(kind: kind, a: CGPoint(x: x1, y: y1), b: x2.map { CGPoint(x: $0, y: y2 ?? y1) })
            if kind == .text { item.text = w.dropFirst(3).joined(separator: " ") }
            if kind == .arrow, w.count >= 6, let bend = Double(w[5]) { item.bend = bend }
            if kind == .highlighter, let x2, let y2 {
                item.points = (0...20).map { i in CGPoint(x: x1 + (x2 - x1) * Double(i) / 20, y: y1 + (y2 - y1) * Double(i) / 20 + 0.01 * sin(Double(i))) }
            }
            if kind == .magnifier { item.radius = 0.05 }
            c.addAnnotation(item)
        case "redact": c.smartRedact()
        case "undoann": c.undoAnnotation()
        case "redoann": c.redoAnnotation()
        case "undomenu": NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        case "redomenu": NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        case "bg":
            // bg <transparent|white|black|blurred|colour r g b|off>
            let w = text.split(separator: " ").map(String.init)
            switch w.first {
            case "transparent": c.setBackground(.transparent)
            case "white": c.setBackground(.white)
            case "black": c.setBackground(.black)
            case "blurred": c.setBackground(.blurred)
            case "colour" where w.count >= 4: c.setBackground(.colour(Double(w[1]) ?? 0, Double(w[2]) ?? 0, Double(w[3]) ?? 0))
            default: c.setBackground(nil)
            }
        case "bgpicker": c.model.backgroundPickerOpen.toggle()
        case "enlargepicker": c.model.enlargePickerOpen.toggle()
        case "badgeshot":
            // badgeshot <path>: the Enlarge badge mid-run, drawn on its own over a grey.
            let view = ZStack {
                Color(white: 0.35)
                WorkBadge(label: "ENLARGE", symbol: "arrow.up.left.and.arrow.down.right", progress: 0.42,
                          working: "enlarging 4×", done: "enlarged", colors: [Color(hex: 0x34A8F0), Color(hex: 0x4285F4)])
            }
            .frame(width: 360, height: 70)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let image = r.cgImage, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: text) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            }
        case "menus":
            // menus: every menu and its items, as the menu bar has them now.
            for top in NSApp.mainMenu?.items ?? [] {
                let items = (top.submenu?.items ?? []).map { $0.isSeparatorItem ? "|" : $0.title + ($0.isHidden ? "[hidden]" : "") + ($0.isAlternate ? "[alt]" : "") }
                print("menu \(top.submenu?.title ?? "-"): \(items.joined(separator: ", "))")
            }
            fflush(stdout)
        case "copytest":
            // copytest: Edit ▸ Copy through the responder chain, then what the pasteboard holds.
            NSPasteboard.general.clearContents()
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            print("pasteboard: \((NSPasteboard.general.types ?? []).map(\.rawValue).joined(separator: ", "))")
            fflush(stdout)
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    /// The app's memory, as Activity Monitor counts it.
    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
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
