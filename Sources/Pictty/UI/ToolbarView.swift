// The hover toolbar. It lives in its own exactly-sized AppKit hosting view so
// AppKit's own hit testing decides what is clickable, and the picture keeps
// every pixel that is not actually chrome.
//
// Tooltips are drawn by hand. AppKit's own take about two seconds to appear,
// which is long enough that nobody discovers anything, and there is no API to
// ask it to hurry up. A 200 ms delay and our own bubble is both faster and
// better looking.

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
            glyph("1.square", "Actual size — 100% (Z)", isOn: model.zoomMode == .actual) {
                controller.applyZoomMode(.actual)
            }
            glyph("arrow.up.left.and.arrow.down.right", "Best fit — the window adapts (2)",
                  isOn: model.zoomMode == .bestFit) {
                controller.applyZoomMode(.bestFit)
            }
            glyph("arrow.up.left.and.down.right.magnifyingglass", "Fit to window (3)",
                  isOn: model.zoomMode == .fitWindow) {
                controller.applyZoomMode(.fitWindow)
            }
            glyph("pin", "Remember zoom (4)", isOn: model.zoomMode == .remember) {
                controller.applyZoomMode(.remember)
            }
            glyph("lock", "Lock zoom & window (5)", isOn: model.zoomMode == .locked) {
                controller.applyZoomMode(.locked)
            }

            separator

            glyph("minus.magnifyingglass", "Zoom out (⌘−)") { controller.zoomOut(nil) }
            ZoomPicker(label: model.zoomLabel) { controller.zoom(toPercent: $0) }
            glyph("plus.magnifyingglass", "Zoom in (⌘+)") { controller.zoomIn(nil) }

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
    let action: () -> Void

    @State private var hovering = false
    @State private var armed = false
    @State private var armTask: Task<Void, Never>?
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .symbolEffect(.bounce.down, value: taps)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 27, height: 25)
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

    private var foreground: Color {
        if isOn { return Color.accentColor.mix(with: .white, by: 0.25) }
        if emphasized { return .white.opacity(0.92) }
        return .white.opacity(hovering ? 0.95 : 0.62)
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

/// The zoom figure, which is also a menu of the usual zooms.
private struct ZoomPicker: View {
    let label: String
    let choose: (Int) -> Void
    @State private var hovering = false

    static let percents = [50, 75, 100, 150, 200]

    var body: some View {
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
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.6))
                .frame(minWidth: 46, minHeight: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(L("Zoom (click for 50–200 %)"))
    }
}
