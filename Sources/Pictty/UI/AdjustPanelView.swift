// The editing panel, in the inspector's place on the right. Its first section is Light:
// exposure, contrast, brightness, highlights and shadows, with the live histogram above them.
//
// While the algorithms are being compared, each slider has three small numbered buttons: the
// candidates. The winner stays and the buttons go.

import PicttyCore
import SwiftUI

struct LightPanelView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var prefs: Preferences
    let controller: ViewerWindowController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))
            if let reason = model.lightUnavailable {
                unavailable(reason)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let analysis = model.analysis {
                            HistogramCard(analysis: analysis, showClipping: model.showClipping, style: $prefs.histogramStyle) {
                                controller.toggleClipping(nil)
                            }
                        }
                        lightCard
                        engineFooter
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                Divider().overlay(.white.opacity(0.08))
                actions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassCard(tint: 0.8, scrim: 0.62)
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 4))
    }

    private var edited: Bool { !model.light.isNeutral }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("ADJUST")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                BeforeAfterButton(isOn: model.showingOriginal, enabled: edited) { controller.setShowingOriginal($0) }
                GlyphButton(symbol: "arrow.counterclockwise", help: "Reset every slider") { controller.resetLight(nil) }
                    .disabled(!edited)
                    .opacity(edited ? 1 : 0.4)
                GlyphButton(symbol: "xmark", help: "Close (E)") { controller.toggleLight(nil) }
            }
            if let item = model.current {
                HStack(spacing: 10) {
                    SymbolTile(symbol: "slider.horizontal.3", colors: [Color(hex: 0xFBBC04), Color(hex: 0xF57C3B)], size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.fileName)
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Group {
                            if model.showingOriginal {
                                Label("Showing the original", systemImage: "eye")
                                    .foregroundStyle(Color(hex: 0xFBBC04))
                            } else if edited {
                                Label("Edited · only on screen until saved", systemImage: "circle.fill")
                                    .foregroundStyle(Color(hex: 0xF57C3B).opacity(0.95))
                            } else {
                                Label("Untouched", systemImage: "checkmark.circle")
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .labelStyle(TightLabel())
                        .contentTransition(.opacity)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 11)
        .animation(.easeOut(duration: 0.18), value: model.showingOriginal)
        .animation(.easeOut(duration: 0.18), value: edited)
    }

    private func unavailable(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.below.square.and.square.filled")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Light

    private var lightCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SymbolTile(symbol: "sun.max.fill", colors: [Color(hex: 0xFBBC04), Color(hex: 0xEA4335)], size: 22)
                Text("Light")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                if model.lightEngine == .pictty {
                    Text("ALGORITHM")
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(.white.opacity(0.38))
                }
            }
            ForEach(LightControl.allCases) { control in
                LightRow(control: control, adjustments: model.light, showsAlgorithms: model.lightEngine == .pictty) {
                    controller.setLight($0)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }

    private var engineFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: model.lightEngine == .appleRAW ? "camera.aperture" : "cpu")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                Text(model.lightEngine == .appleRAW ? "APPLE RAW ENGINE" : "PICTTY ENGINE")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                if !model.lightTiming.isEmpty {
                    Text(model.lightTiming.components(separatedBy: " · ").dropFirst().joined(separator: " · "))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Text(model.lightEngine == .appleRAW
                 ? "Camera RAWs develop in Apple's engine for now: exposure in the develop, then Core Image's own tone filters."
                 : "Linear light in half float on the GPU. Each numbered button picks a candidate algorithm for that slider.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.03)))
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            PanelButton(title: "Revert", symbol: "arrow.uturn.backward", iconOnly: true, enabled: edited) { controller.resetLight(nil) }
            Spacer(minLength: 0)
            PanelButton(title: edited ? "Save As…" : "Convert…", symbol: "square.and.arrow.down.on.square",
                        enabled: !model.isSaving) { controller.saveEditsAs(nil) }
            if let item = model.current, controller.canSaveInPlace(item.url) {
                PanelButton(title: "Save", symbol: "square.and.arrow.down", prominent: true,
                            enabled: edited && !model.isSaving) { controller.saveEdits(nil) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - A slider row

private struct LightRow: View {
    let control: LightControl
    let adjustments: LightAdjustments
    let showsAlgorithms: Bool
    let change: (LightAdjustments) -> Void

    private var value: Double { control.value(adjustments) }
    private var algorithm: Int { control.algorithm(adjustments) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(L(control.title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .onTapGesture(count: 2) { set(0) }
                Spacer(minLength: 4)
                if showsAlgorithms {
                    AlgorithmPicker(control: control, selection: algorithm) { n in
                        var a = adjustments
                        control.setAlgorithm(n, in: &a)
                        change(a)
                    }
                }
                Text(readout)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(value == 0 ? .white.opacity(0.45) : Color.accentColor)
                    .frame(width: 40, alignment: .trailing)
                    .contentTransition(.numericText(value: value))
                    .onTapGesture(count: 2) { set(0) }
                    .help("Double-click to reset")
            }
            LightSlider(value: value, range: control.range, track: track) { set($0) }
            if showsAlgorithms {
                Text(L(control.algorithms[algorithm - 1].name))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(value == 0 ? 0.3 : 0.5))
                    .contentTransition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: algorithm)
    }

    private func set(_ v: Double) {
        var a = adjustments
        control.set(v, in: &a)
        if a != adjustments { change(a) }
    }

    private var readout: String {
        if control == .exposure { return value == 0 ? "0.00" : String(format: "%+.2f", value) }
        let n = Int((value * 100).rounded())
        return n == 0 ? "0" : String(format: "%+d", n)
    }

    /// What the slider does, painted on its track.
    private var track: [Color] {
        switch control {
        case .exposure: [Color(white: 0.04), Color(white: 0.96)]
        case .contrast: [Color(white: 0.42), Color(white: 0.55), Color(white: 0.02), Color(white: 1)]
        case .brightness: [Color(white: 0.18), Color(white: 0.82)]
        case .highlights: [Color(white: 0.5), Color(white: 1)]
        case .shadows: [Color(white: 0), Color(white: 0.5)]
        }
    }
}

/// The three candidates, as numbered dots.
private struct AlgorithmPicker: View {
    let control: LightControl
    let selection: Int
    let choose: (Int) -> Void
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...3, id: \.self) { n in
                let on = n == selection
                Text("\(n)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? .white : .white.opacity(hovered == n ? 0.9 : 0.55))
                    .frame(width: 17, height: 17)
                    .background {
                        Circle().fill(on ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x4285F4), Color(hex: 0x6A4CE0)],
                                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                         : AnyShapeStyle(Color.white.opacity(hovered == n ? 0.16 : 0.07)))
                    }
                    .overlay(Circle().strokeBorder(.white.opacity(on ? 0.3 : 0.12), lineWidth: 0.5))
                    .shadow(color: on ? Color(hex: 0x4285F4).opacity(0.7) : .clear, radius: 4)
                    .contentShape(Circle())
                    .onHover { hovered = $0 ? n : (hovered == n ? nil : hovered) }
                    .onTapGesture { choose(n) }
                    .help("(\(n)) \(L(control.algorithms[n - 1].name)): \(L(control.algorithms[n - 1].detail))")
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityLabel(L("Algorithm %ld: %@", n, L(control.algorithms[n - 1].name)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selection)
    }
}

/// A centre-zero slider: the track shows what it does, the fill grows from zero, and zero holds
/// the knob a little so it is easy to come back to. ⌥ drags finely.
private struct LightSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let track: [Color]
    let change: (Double) -> Void

    @State private var dragStart: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, knob: CGFloat = 14
            let usable = w - knob
            let span = range.upperBound - range.lowerBound
            let x = { (v: Double) in knob / 2 + CGFloat((v - range.lowerBound) / span) * usable }
            let zero = x(0), here = x(value)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                    .opacity(0.5)
                    .frame(height: 4)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                Rectangle()
                    .fill(.white.opacity(0.4))
                    .frame(width: 1, height: 9)
                    .offset(x: zero - 0.5)
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x4285F4), Color(hex: 0x34A8F0)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: abs(here - zero), height: 4)
                    .offset(x: min(here, zero))
                    .shadow(color: Color(hex: 0x4285F4).opacity(0.8), radius: 3)
                    .opacity(value == 0 ? 0 : 1)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .scaleEffect(dragStart != nil ? 1.18 : (hovering ? 1.07 : 1))
                    .offset(x: here - knob / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil {
                            // A press on the track jumps there; a press on the knob grabs it.
                            let onKnob = abs(g.startLocation.x - here) <= knob
                            dragStart = onKnob ? value : range.lowerBound + Double((g.startLocation.x - knob / 2) / usable) * span
                        }
                        let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1
                        var v = dragStart! + Double(g.translation.width / usable) * span * fine
                        // A detent at zero.
                        if abs(v) < span * 0.012 { v = 0 }
                        change(min(max(v, range.lowerBound), range.upperBound))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: dragStart != nil)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue(Text(String(format: "%.2f", value)))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 40
            change(min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound))
        }
    }
}

/// Press and hold for the original; let go for the edit. \ toggles it from the keyboard.
private struct BeforeAfterButton: View {
    let isOn: Bool
    let enabled: Bool
    let press: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "rectangle.lefthalf.inset.filled")
            .font(.system(size: 12.5, weight: .medium))
            .frame(width: 27, height: 25)
            .foregroundStyle(isOn ? Color(hex: 0xFBBC04) : .white.opacity(enabled ? 0.85 : 0.35))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOn ? Color(hex: 0xFBBC04).opacity(0.2) : (hovering && enabled ? .white.opacity(0.13) : .clear)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onLongPressGesture(minimumDuration: 60, maximumDistance: 60, perform: {}, onPressingChanged: { pressing in
                if enabled { press(pressing) }
            })
            .help("Hold to see the original (\\)")
    }
}

/// A rounded glass button for the panel's foot.
private struct PanelButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var iconOnly = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if iconOnly {
                    Image(systemName: symbol).frame(width: 14)
                } else {
                    Label(L(title), systemImage: symbol).labelStyle(TightLabel())
                }
            }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, iconOnly ? 7 : 11)
                .padding(.vertical, 6)
                .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.35))
                .background {
                    Capsule().fill(prominent && enabled
                                   ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x4285F4), Color(hex: 0x6A4CE0)],
                                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                                   : AnyShapeStyle(Color.white.opacity(hovering && enabled ? 0.14 : 0.08)))
                }
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: prominent && enabled ? Color(hex: 0x4285F4).opacity(0.5) : .clear, radius: 6)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(iconOnly ? L(title) : "")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
