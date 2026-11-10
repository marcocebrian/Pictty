// The hover toolbar. It lives in its own exactly-sized AppKit hosting view so
// AppKit's own hit testing decides what is clickable, and the picture keeps
// every pixel that is not actually chrome.
//
// Tooltips are drawn by hand. AppKit's own take about two seconds to appear,
// which is long enough that nobody discovers anything, and there is no API to
// ask it to hurry up. A 200 ms delay and our own bubble is both faster and
// better looking.

import PicttyCore
import SwiftUI

/// Which button the pointer is resting on, and where to put its label.
struct TooltipRequest: Equatable {
    var text: String
    var midX: CGFloat
}

struct TooltipKey: PreferenceKey {
    static let defaultValue: TooltipRequest? = nil
    static func reduce(value: inout TooltipRequest?, nextValue: () -> TooltipRequest?) {
        value = nextValue() ?? value
    }
}

struct ToolbarView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var prefs: Preferences
    let controller: ViewerWindowController

    static let coordinateSpace = "pictty.toolbar"
    /// How long the pointer must rest before a label appears.
    static let tooltipDelay: TimeInterval = 0.2

    var body: some View {
        if model.chromeReady { toolbar }
    }

    private var toolbar: some View {
        pill
            .padding(.top, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(name: Self.coordinateSpace)
            .overlayPreferenceValue(TooltipKey.self) { request in
                if let request {
                    TooltipBubble(text: request.text)
                        .position(x: request.midX, y: 54)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: 0)
    }

    // MARK: - The pill

    private var pill: some View {
        HStack(spacing: 2) {
            ZoomModeMenu(mode: model.zoomMode) { controller.applyZoomMode($0) }
            ZoomControl(label: model.zoomLabel, zoomOut: { controller.zoomOut(nil) },
                        zoomIn: { controller.zoomIn(nil) }, choose: { controller.zoom(toPercent: $0) })

            separator

            glyph("rotate.left", "Rotate left ([)") { controller.rotateLeft(nil) }
            glyph("rotate.right", "Rotate right (])") { controller.rotateRight(nil) }
            glyph("arrow.left.and.right.righttriangle.left.righttriangle.right",
                  "Mirror (M)", isOn: model.mirrored) { controller.toggleMirror(nil) }

            separator

            CompareButton(model: model, prefs: prefs, controller: controller)

            separator

            glyph("rectangle.bottomthird.inset.filled", "Pin filmstrip (T)", isOn: model.filmstripPinned) {
                controller.toggleFilmstrip(nil)
            }
            glyph("info.circle", "Information (I)", isOn: model.showInspector) {
                controller.toggleInspector(nil)
            }
            glyph("slider.horizontal.3", "Adjust (E)", isOn: model.showLight) {
                controller.toggleLight(nil)
            }
            glyph("crop", "Crop (C)", isOn: model.cropping) {
                controller.toggleCrop(nil)
            }
            if NeuralUpscaler.shared.isAvailable {
                EnlargeButton(model: model, controller: controller)
            }
            BackgroundButton(model: model, controller: controller)
            glyph("pencil.tip.crop.circle", "Annotate (⇧⌘A)", isOn: model.annotating) {
                controller.toggleAnnotate(nil)
            }
            glyph(model.slideshowRunning ? "pause.rectangle" : "play.rectangle",
                  model.slideshowRunning ? "Stop slideshow (S)" : "Slideshow (S)",
                  isOn: model.slideshowRunning) {
                controller.toggleSlideshow(nil)
            }
            glyph("arrow.up.left.and.arrow.down.right.circle", "Full screen (F)") {
                controller.window?.toggleFullScreen(nil)
            }

            separator

            glyph("folder", "Open folder (⌥O)") { controller.presentOpenFolderPanel(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .fixedSize()
        .liquidGlassCapsule(tint: 0.42, shadow: 10)
    }

    private func glyph(_ symbol: String, _ help: String, isOn: Bool = false,
                       action: @escaping () -> Void) -> some View {
        GlyphButton(symbol: symbol, help: help, isOn: isOn, action: action)
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .frame(width: 0.5, height: 13)
            .padding(.horizontal, 4)
    }
}

// MARK: - Tooltip

struct TooltipBubble: View {
    let text: String

    var body: some View {
        Text(L(text))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.94))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .transition(.opacity)
    }
}

// MARK: - Reusable glyph button

struct GlyphButton: View {
    let symbol: String
    var help: String = ""
    var isOn: Bool = false
    var emphasized: Bool = false
    var size: CGFloat = 12.5
    var width: CGFloat = 27
    var height: CGFloat = 25
    let action: () -> Void

    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: size < 11 ? .bold : .medium))
                .symbolEffect(.bounce.down, value: taps)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: width, height: height)
                .foregroundStyle(foreground)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOn ? Color.accentColor.opacity(hovering ? 0.3 : 0.2)
                                   : (hovering ? Color.white.opacity(0.13) : Color.clear))
                )
                .animation(.easeOut(duration: 0.14), value: hovering)
                .animation(.easeOut(duration: 0.18), value: isOn)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .toolbarTooltip(help, hovering: $hovering)
    }

    private var foreground: Color {
        if isOn { return Color.accentColor.mix(with: .white, by: 0.25) }
        if emphasized { return .white.opacity(0.92) }
        return .white.opacity(hovering ? 0.95 : 0.62)
    }
}

/// The toolbar's own quick tooltip over a control, and its hover state.
private struct ToolbarTooltip: ViewModifier {
    let help: String
    @Binding var hovering: Bool
    @State private var armed = false
    @State private var armTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            // `.help()` would put AppKit's two-second tooltip on top of ours.
            .accessibilityLabel(L(help))
            .onHover { inside in
                hovering = inside
                armTask?.cancel()
                guard inside, !help.isEmpty else {
                    armed = false
                    return
                }
                armTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(ToolbarView.tooltipDelay * 1_000_000_000))
                    guard !Task.isCancelled, hovering else { return }
                    armed = true
                }
            }
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: TooltipKey.self,
                        value: armed
                            ? TooltipRequest(text: help,
                                             midX: geometry.frame(in: .named(ToolbarView.coordinateSpace)).midX)
                            : nil
                    )
                }
            )
            .onDisappear {
                armTask?.cancel()
                armed = false
            }
    }
}

extension View {
    func toolbarTooltip(_ help: String, hovering: Binding<Bool>) -> some View {
        modifier(ToolbarTooltip(help: help, hovering: hovering))
    }
}

/// The quick tooltip for anything that keeps no hover state of its own.
private struct QuickTip: ViewModifier {
    let help: String
    @State private var hovering = false
    func body(content: Content) -> some View { content.toolbarTooltip(help, hovering: $hovering) }
}

extension View {
    func quickTip(_ help: String) -> some View { modifier(QuickTip(help: help)) }

    /// A bar at the bottom of the window (crop, annotate): its buttons' tooltips, shown just above it.
    /// The host is taller than the bar, which sits at its bottom, so there is room for them.
    func bottomBarTooltips() -> some View {
        self
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .coordinateSpace(name: ToolbarView.coordinateSpace)
            .overlayPreferenceValue(TooltipKey.self) { request in
                if let request {
                    GeometryReader { geo in
                        TooltipBubble(text: request.text)
                            .position(x: request.midX, y: geo.size.height - 9 - 40 - 16)
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

/// Presses sink a little, and spring back.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Every way to compare behind one button: it shows the layout in use (lit while comparing) and opens
/// a strip of the five layouts, the two syncs and Stop. Choosing a layout starts comparing.
private struct CompareButton: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var prefs: Preferences
    let controller: ViewerWindowController
    @State private var hovering = false

    var body: some View {
        Button {
            model.comparePickerOpen.toggle()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: model.isComparing ? prefs.compareLayout.symbol : "rectangle.split.2x1")
                    .font(.system(size: 12.5, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.7)
            }
            .frame(width: 34, height: 25)
            .foregroundStyle(model.isComparing ? Color.accentColor.mix(with: .white, by: 0.25)
                                               : .white.opacity(hovering || model.comparePickerOpen ? 0.95 : 0.62))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(model.isComparing ? Color.accentColor.opacity(hovering ? 0.3 : 0.2)
                                            : .white.opacity(hovering || model.comparePickerOpen ? 0.13 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .toolbarTooltip(model.comparePickerOpen ? "" : "Compare (D)", hovering: $hovering)
        .popover(isPresented: $model.comparePickerOpen, arrowEdge: .bottom) {
            ComparePicker(model: model, prefs: prefs, controller: controller)
        }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: model.isComparing)
    }
}

/// Enlarge: one button next to Crop; its strip holds 2×, 4× and Off. Past 8 MP (as cropped) or on
/// an HDR picture it stays dim, and says why.
private struct EnlargeButton: View {
    @ObservedObject var model: ViewerModel
    let controller: ViewerWindowController
    @State private var hovering = false

    var body: some View {
        let refusal = controller.offersEnlarge ? controller.enlargeRefusal : nil
        let usable = controller.offersEnlarge && refusal == nil
        let on = model.enlarge != nil
        Button {
            if let refusal { return controller.showToast(ViewerWindowController.refusalText(refusal), symbol: "exclamationmark.triangle") }
            guard usable else { return }
            NeuralUpscaler.shared.warmUp()
            model.enlargePickerOpen.toggle()
        } label: {
            HStack(spacing: 2) {
                if let f = model.enlarge {
                    Text("\(f)×").font(.system(size: 11.5, weight: .bold, design: .rounded))
                } else {
                    // The enlarge arrows with a sparkle: the AI one, not Resize.
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11.5, weight: .medium))
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 7.5, weight: .bold))
                                .offset(x: 5, y: -5)
                        }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.7)
            }
            .frame(width: 34, height: 25)
            .foregroundStyle(on ? Color.accentColor.mix(with: .white, by: 0.25)
                                : .white.opacity(!usable ? 0.3 : hovering || model.enlargePickerOpen ? 0.95 : 0.62))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? Color.accentColor.opacity(hovering ? 0.3 : 0.2)
                             : .white.opacity(usable && (hovering || model.enlargePickerOpen) ? 0.13 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .toolbarTooltip(model.enlargePickerOpen ? "" : refusal.map { ViewerWindowController.refusalText($0) } ?? "AI Enlarge",
                        hovering: $hovering)
        .popover(isPresented: $model.enlargePickerOpen, arrowEdge: .bottom) {
            HStack(spacing: 1) {
                ForEach(EnlargeRule.factors, id: \.self) { f in
                    CompareTile(symbol: "", text: "\(f)×", title: "AI Enlarge \(f)×", help: "AI Enlarge \(f)×", isOn: model.enlarge == f) {
                        model.enlargePickerOpen = false
                        controller.setEnlarge(f)
                    }
                }
                Rectangle().fill(.primary.opacity(0.12)).frame(width: 0.5, height: 13).padding(.horizontal, 4)
                CompareTile(symbol: "xmark", title: "Turn AI Enlarge off", help: "Turn AI Enlarge off", isOn: false) {
                    model.enlargePickerOpen = false
                    controller.setEnlarge(nil)
                }
                .disabled(model.enlarge == nil)
                .opacity(model.enlarge == nil ? 0.35 : 1)
            }
            .padding(4)
        }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: on)
    }
}

/// Remove background: one button; its strip holds the fills and Off.
private struct BackgroundButton: View {
    @ObservedObject var model: ViewerModel
    let controller: ViewerWindowController
    @State private var hovering = false

    var body: some View {
        let usable = controller.offersBackground
        let on = model.background != nil
        Button {
            guard usable else { return }
            model.backgroundPickerOpen.toggle()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "person.and.background.dotted")
                    .font(.system(size: 12.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.7)
            }
            .frame(width: 34, height: 25)
            .foregroundStyle(on ? Color.accentColor.mix(with: .white, by: 0.25)
                                : .white.opacity(!usable ? 0.3 : hovering || model.backgroundPickerOpen ? 0.95 : 0.62))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? Color.accentColor.opacity(hovering ? 0.3 : 0.2)
                             : .white.opacity(usable && (hovering || model.backgroundPickerOpen) ? 0.13 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .toolbarTooltip(model.backgroundPickerOpen ? "" : "Remove Background", hovering: $hovering)
        .popover(isPresented: $model.backgroundPickerOpen, arrowEdge: .bottom) {
            HStack(spacing: 1) {
                tile("checkerboard.rectangle", "Transparent", .transparent)
                tile("square.fill", "White", .white, tint: .white)
                tile("square.fill", "Black", .black, tint: .black)
                CompareTile(symbol: "paintpalette", title: "Colour…", help: "Colour…", isOn: isColour) {
                    model.backgroundPickerOpen = false
                    controller.pickBackgroundColour()
                }
                tile("camera.aperture", "Blurred", .blurred)
                Rectangle().fill(.primary.opacity(0.12)).frame(width: 0.5, height: 13).padding(.horizontal, 4)
                CompareTile(symbol: "xmark", title: "Keep the background", help: "Keep the background", isOn: false) {
                    model.backgroundPickerOpen = false
                    controller.setBackground(nil)
                }
                .disabled(model.background == nil)
                .opacity(model.background == nil ? 0.35 : 1)
            }
            .padding(4)
        }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: on)
    }

    private var isColour: Bool { if case .colour = model.background { true } else { false } }

    private func tile(_ symbol: String, _ title: String, _ fill: BackgroundFill, tint: Color? = nil) -> some View {
        CompareTile(symbol: symbol, title: title, help: title, isOn: model.background == fill) {
            model.backgroundPickerOpen = false
            controller.setBackground(fill)
        }
    }
}

/// The strip under the Compare button: one row of tiles, each an icon with its name.
private struct ComparePicker: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var prefs: Preferences
    let controller: ViewerWindowController

    var body: some View {
        HStack(spacing: 1) {
            ForEach(CompareLayout.allCases) { layout in
                let unavailable = model.items.count < 2 || (layout.requiresExactlyTwo && model.paneCount > 2)
                CompareTile(symbol: layout.symbol, title: shortTitle(layout),
                            help: L(shortTitle(layout)) + " · " + help(layout, unavailable: unavailable),
                            isOn: model.isComparing && prefs.compareLayout == layout) {
                    // A layout chosen is the end of the visit: the strip closes, the pictures show.
                    model.comparePickerOpen = false
                    controller.compare(layout: layout)
                }
                .disabled(unavailable)
                .opacity(unavailable ? 0.35 : 1)
            }

            divider

            CompareTile(symbol: "arrow.up.and.down.and.arrow.left.and.right", title: "Pan together", help: "Sync pan (P)",
                        isOn: prefs.syncPan) { controller.toggleSyncPan(nil) }
            CompareTile(symbol: "plus.magnifyingglass", title: "Zoom together", help: "Sync zoom (⇧P)",
                        isOn: prefs.syncZoom) { controller.toggleSyncZoom(nil) }

            divider

            // Always there, so the strip keeps its size; only lit up while comparing.
            CompareTile(symbol: "xmark", title: "Stop", help: "Stop comparing (Esc)") {
                model.comparePickerOpen = false
                controller.toggleCompare(nil)
            }
            .disabled(!model.isComparing)
            .opacity(model.isComparing ? 1 : 0.35)
        }
        .padding(4)
        .fixedSize()
        .animation(.easeOut(duration: 0.18), value: model.isComparing)
    }

    private func shortTitle(_ layout: CompareLayout) -> String {
        switch layout {
        case .sideBySide: "Side by Side"
        case .stacked: "Top & Bottom"
        case .grid: "Grid"
        case .wipe: "Wipe"
        case .blink: "Blink"
        }
    }

    private func help(_ layout: CompareLayout, unavailable: Bool) -> String {
        if model.items.count < 2 { return L("Need at least two pictures") }
        if unavailable { return L("%@ needs exactly two pictures", L(layout.title)) }
        switch layout {
        case .sideBySide: return L("Left and right")
        case .stacked: return L("One above the other")
        case .grid: return L("Two across, for three or four pictures")
        case .wipe: return L("One over the other: drag the line")
        case .blink: return L("One over the other: B flips between them")
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.12))
            .frame(width: 0.5, height: 13)
            .padding(.horizontal, 4)
    }
}

/// One icon of the strip, as small as the toolbar's own, lit when it is the one in use; its name
/// is the tooltip.
private struct CompareTile: View {
    let symbol: String
    /// Words in place of the symbol ("2×").
    var text: String?
    let title: String
    let help: String
    var isOn = false
    let action: () -> Void
    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Group {
                if let text {
                    Text(text).font(.system(size: 12, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5, weight: .medium))
                        .symbolEffect(.bounce.down, value: taps)
                }
            }
                .frame(width: 27, height: 25)
                .foregroundStyle(isOn ? Color.accentColor : .primary.opacity(hovering ? 0.95 : 0.7))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn ? Color.accentColor.opacity(hovering ? 0.24 : 0.16)
                                   : .primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(L(help))
        .accessibilityLabel(L(title))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: isOn)
    }
}

/// The five zoom modes behind one button: it shows the mode in use and opens them as a list.
private struct ZoomModeMenu: View {
    let mode: ZoomMode
    let choose: (ZoomMode) -> Void
    @State private var hovering = false

    /// Each mode as the menu lists it, with its key.
    private static let entries: [(mode: ZoomMode, title: String)] = [
        (.actual, "Actual size — 100% (Z)"),
        (.bestFit, "Best fit — the window adapts (2)"),
        (.fitWindow, "Fit to window (3)"),
        (.remember, "Remember zoom (4)"),
        (.locked, "Lock zoom & window (5)"),
    ]

    var body: some View {
        Menu {
            ForEach(Self.entries, id: \.mode) { entry in
                Toggle(isOn: Binding(get: { mode == entry.mode }, set: { _ in choose(entry.mode) })) {
                    Label(L(entry.title), systemImage: entry.mode.symbol)
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.7)
            }
            .frame(width: 34, height: 25)
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.62))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.13 : 0)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .toolbarTooltip("Zoom mode (1–5)", hovering: $hovering)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: mode)
    }
}

/// Zoom out, the zoom figure (also a menu of the usual zooms) and zoom in, in one small capsule.
private struct ZoomControl: View {
    let label: String
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    let choose: (Int) -> Void
    @State private var hovering = false

    static let percents = [50, 75, 100, 150, 200]

    var body: some View {
        HStack(spacing: 0) {
            step("minus", "Zoom out (⌘−)", zoomOut)
            Menu {
                ForEach(Self.percents, id: \.self) { p in
                    Button {
                        choose(p)
                    } label: {
                        if label == "\(p)%" { Label("\(p) %", systemImage: "checkmark") } else { Text("\(p) %") }
                    }
                }
            } label: {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.62))
                    .frame(minWidth: 34, minHeight: 21)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .toolbarTooltip("Zoom (click for 50–200 %)", hovering: $hovering)
            step("plus", "Zoom in (⌘+)", zoomIn)
        }
        .padding(.horizontal, 1)
        .background(Capsule().fill(.white.opacity(0.07)))
        .padding(.horizontal, 3)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func step(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        GlyphButton(symbol: symbol, help: help, size: 9.5, width: 18, height: 21, action: action)
    }
}
