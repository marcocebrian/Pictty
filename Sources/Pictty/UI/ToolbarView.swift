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

            glyph("rectangle.split.2x1",
                  "Add another picture beside this one (D)",
                  isOn: model.isComparing) { controller.toggleCompare(nil) }
            if model.isComparing {
                glyph(prefs.compareLayout.symbol,
                      L("Layout (L): %@", L(prefs.compareLayout.title))) {
                    controller.cycleCompareLayout(nil)
                }
                glyph("arrow.left.and.right", "Sync pan (P)", isOn: prefs.syncPan) {
                    controller.toggleSyncPan(nil)
                }
                glyph("magnifyingglass", "Sync zoom (⇧P)", isOn: prefs.syncZoom) {
                    controller.toggleSyncZoom(nil)
                }
            }

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

/// Presses sink a little, and spring back.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
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
