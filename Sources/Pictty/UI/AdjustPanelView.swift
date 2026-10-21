// The Adjust panel, on the right of the window, which makes room for it. The live histogram
// first, then Light (exposure, contrast, brightness, highlights, shadows) and Colour: white
// balance, with Auto and an eyedropper, vibrance and saturation, and colour grading on three wheels.
//
// Contrast, brightness, highlights and shadows still have numbered buttons: the candidates being
// compared. The winner stays and the buttons go.

import PicttyCore
import SwiftUI

struct AdjustPanelView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var prefs: Preferences
    let controller: ViewerWindowController

    var body: some View {
        // Nothing at all while the panel is put away: a hidden panel must never cost the picture
        // a millisecond, at launch or on any change of the model.
        if model.showLight { panel }
    }

    private var panel: some View {
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
                        lightSection
                        colourSection
                        detailSection
                        engineFooter
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassCard(tint: 0.8, scrim: 0.62)
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 4))
    }

    private var a: Adjustments { model.light }
    private var edited: Bool { !a.isNeutral || model.crop != nil }
    private func change(_ new: Adjustments) { controller.setLight(new) }

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
                                Label("Edited · ⌘S to save", systemImage: "circle.fill")
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

    private var lightSection: some View {
        SectionCard(title: "Light", symbol: "sun.max.fill", colors: [Color(hex: 0xFBBC04), Color(hex: 0xEA4335)],
                    canReset: !a.isLightNeutral, reset: { change(a.lightReset) }) {
            ForEach(AdjustmentControl.light) { control in
                SliderRow(control: control, adjustments: a, showsAlgorithms: model.lightEngine == .pictty, change: change)
            }
        }
    }

    // MARK: Colour

    private var colourSection: some View {
        SectionCard(title: "Colour", symbol: "paintpalette.fill", colors: [Color(hex: 0xA05CE0), Color(hex: 0xEA4335)],
                    canReset: !a.isWhiteBalanceNeutral || !a.isSaturationNeutral || !a.isGradingNeutral, reset: { change(a.colourReset) }) {
            HStack(spacing: 6) {
                SubHeading("WHITE BALANCE")
                Spacer()
                PillButton(title: "Auto", symbol: "wand.and.stars", help: "Find the light the picture was taken under and take it out") {
                    controller.autoWhiteBalance(nil)
                }
                PillButton(title: nil, symbol: "eyedropper", isOn: model.pickingWhite,
                           help: "Click something in the picture that should be neutral grey") {
                    controller.toggleWhitePicker(nil)
                }
            }
            ForEach(AdjustmentControl.whiteBalance) { control in
                SliderRow(control: control, adjustments: a, showsAlgorithms: false, change: change)
            }

            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.vertical, 2)

            HStack {
                SubHeading("SATURATION")
                Spacer()
            }
            ForEach(AdjustmentControl.saturationControls) { control in
                SliderRow(control: control, adjustments: a, showsAlgorithms: false, change: change)
            }

            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.vertical, 2)

            HStack {
                SubHeading("COLOUR GRADING")
                Spacer()
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(ToneRange.allCases) { range in
                    GradeWheel(range: range, shift: range.shift(a)) { shift in
                        var new = a
                        range.set(shift, in: &new)
                        change(new)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            SliderRow(control: .balance, adjustments: a, showsAlgorithms: false, change: change)
                .opacity(a.isGradingNeutral ? 0.55 : 1)
        }
    }

    // MARK: Detail

    private var detailSection: some View {
        SectionCard(title: "Detail", symbol: "camera.aperture", colors: [Color(hex: 0x34A8F0), Color(hex: 0x00897B)],
                    canReset: !a.isDetailNeutral, reset: { change(a.detailReset) }) {
            ForEach(AdjustmentControl.detail) { control in
                SliderRow(control: control, adjustments: a, showsAlgorithms: false, change: change)
            }
            if model.offersDenoise {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.vertical, 2)
                HStack(spacing: 6) {
                    SubHeading("NOISE REDUCTION")
                    if model.denoising {
                        ProgressView().controlSize(.mini)
                        Text("Denoising…")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    PillButton(title: "Auto", symbol: "wand.and.stars",
                               help: "Measure the picture's noise and take out as much as it needs") {
                        controller.autoDenoise(nil)
                    }
                }
                SliderRow(control: .denoise, adjustments: a, showsAlgorithms: false, change: change)
                Text(model.lightEngine == .appleRAW ? "Apple's RAW noise reduction, from the camera's own default up."
                                                    : "NAFNet, a neural network for real camera noise, on this Mac's GPU. Nothing leaves it.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.denoising)
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
                 ? "Camera RAWs develop in Apple's engine for now: exposure and white balance in the develop, then Core Image's own tone filters."
                 : "Linear light in half float on the GPU.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                KeyCap(text: "⌘S")
                Text("Save").foregroundStyle(.white.opacity(0.5))
                KeyCap(text: "⇧⌘S").padding(.leading, 6)
                Text("Save As…").foregroundStyle(.white.opacity(0.5))
                KeyCap(text: "Y").padding(.leading, 6)
                Text("Original").foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 10.5))
            .padding(.top, 2)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.03)))
    }
}

// MARK: - Building blocks

private struct SectionCard<Content: View>: View {
    let title: String
    let symbol: String
    let colors: [Color]
    let canReset: Bool
    let reset: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                SymbolTile(symbol: symbol, colors: colors, size: 22)
                Text(L(title))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(canReset ? 0.7 : 0.2))
                .disabled(!canReset)
                .help(L("Reset %@", L(title)))
            }
            content()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }
}

private struct SubHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(L(text))
            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(.white.opacity(0.42))
    }
}

/// A small capsule button for a section's own actions.
private struct PillButton: View {
    let title: String?
    let symbol: String
    var isOn = false
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .symbolEffect(.bounce, value: taps)
                if let title { Text(L(title)) }
            }
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, title == nil ? 7 : 9)
            .padding(.vertical, 4)
            .foregroundStyle(isOn ? .white : .white.opacity(0.85))
            .background {
                Capsule().fill(isOn ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x4285F4), Color(hex: 0x6A4CE0)],
                                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.white.opacity(hovering ? 0.15 : 0.08)))
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: isOn ? Color(hex: 0x4285F4).opacity(0.6) : .clear, radius: 5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L(help))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - A slider row

private struct SliderRow: View {
    let control: AdjustmentControl
    let adjustments: Adjustments
    let showsAlgorithms: Bool
    let change: (Adjustments) -> Void

    private var value: Double { control.value(adjustments) }
    private var candidates: [(id: Int, name: String, detail: String)] { showsAlgorithms ? control.algorithms : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: control.symbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(value == 0 ? 0.45 : 0.85))
                    .frame(width: 15)
                Text(L(control.title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer(minLength: 4)
                if candidates.count > 1, let id = control.algorithm(adjustments) {
                    AlgorithmPicker(candidates: candidates, selection: id) { n in
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
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { set(0) }
            LightSlider(value: value, range: control.range, track: track) { set($0) }
            if candidates.count > 1, let id = control.algorithm(adjustments), let c = candidates.first(where: { $0.id == id }) {
                Text(L(c.name))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(value == 0 ? 0.3 : 0.5))
                    .contentTransition(.opacity)
            }
        }
        .help(L("Double-click to reset"))
    }

    private func set(_ v: Double) {
        var a = adjustments
        control.set(v, in: &a)
        if a != adjustments { change(a) }
    }

    private var readout: String {
        if control == .exposure { return value == 0 ? "0.00" : String(format: "%+.2f", value) }
        let n = Int((value * 100).rounded())
        // One-sided sliders (sharpening, noise reduction) have no sign to show.
        if control.range.lowerBound == 0 { return "\(n)" }
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
        case .temperature: [Color(hex: 0x3F7DFF), Color(white: 0.82), Color(hex: 0xFFAE3A)]
        case .tint: [Color(hex: 0x39C85A), Color(white: 0.82), Color(hex: 0xE24BD3)]
        case .vibrance: [Color(white: 0.5), Color(hex: 0xC9A27E), Color(hex: 0x2FB4E8), Color(hex: 0xA44CE8)]
        case .saturation: [Color(white: 0.5), Color(hex: 0xE8504A), Color(hex: 0xF6C343), Color(hex: 0x3DC46A)]
        case .balance: [Color(white: 0.08), Color(white: 0.5), Color(white: 0.95)]
        case .texture: [Color(white: 0.35), Color(hex: 0x8D9BA8), Color(hex: 0xD7E3EC)]
        case .clarity: [Color(white: 0.3), Color(hex: 0x9FB6C9), Color(white: 0.95)]
        case .sharpening: [Color(white: 0.3), Color(hex: 0x64B5F6)]
        case .denoise: [Color(hex: 0x6A4CE0), Color(hex: 0x9C8CF0), Color(hex: 0xE0DAFF)]
        }
    }
}

/// The candidates, as numbered dots.
private struct AlgorithmPicker: View {
    let candidates: [(id: Int, name: String, detail: String)]
    let selection: Int
    let choose: (Int) -> Void
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { i, c in
                let on = c.id == selection
                Text("\(i + 1)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? .white : .white.opacity(hovered == c.id ? 0.9 : 0.55))
                    .frame(width: 17, height: 17)
                    .background {
                        Circle().fill(on ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x4285F4), Color(hex: 0x6A4CE0)],
                                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                         : AnyShapeStyle(Color.white.opacity(hovered == c.id ? 0.16 : 0.07)))
                    }
                    .overlay(Circle().strokeBorder(.white.opacity(on ? 0.3 : 0.12), lineWidth: 0.5))
                    .shadow(color: on ? Color(hex: 0x4285F4).opacity(0.7) : .clear, radius: 4)
                    .contentShape(Circle())
                    .onHover { hovered = $0 ? c.id : (hovered == c.id ? nil : hovered) }
                    .onTapGesture { choose(c.id) }
                    .help("(\(i + 1)) \(L(c.name)): \(L(c.detail))")
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityLabel(L("Algorithm %ld: %@", i + 1, L(c.name)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selection)
    }
}

/// A centre-zero slider: the track shows what it does, the fill grows from zero, and zero holds
/// the knob a little so it is easy to come back to. ⌥ drags finely; a double-click resets.
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
                            // A double-click anywhere on the slider resets it.
                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                dragStart = .nan
                                change(0)
                                return
                            }
                            // A press on the track jumps there; a press on the knob grabs it.
                            let onKnob = abs(g.startLocation.x - here) <= knob
                            dragStart = onKnob ? value : range.lowerBound + Double((g.startLocation.x - knob / 2) / usable) * span
                        }
                        guard let start = dragStart, !start.isNaN else { return }
                        let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1
                        var v = start + Double(g.translation.width / usable) * span * fine
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

// MARK: - Colour wheel

/// One tonal range's colour: the angle is the colour, the distance from the centre how much of it.
/// Drag anywhere on the wheel; ⇧ keeps the colour and changes only the amount, ⌥ moves finely,
/// a double-click goes back to none. The wheel glows with what it is set to.
private struct GradeWheel: View {
    let range: ToneRange
    let shift: ColourShift
    let change: (ColourShift) -> Void

    @State private var dragging = false
    @State private var fineFrom: (start: CGPoint, puck: CGPoint)?
    @State private var ignoring = false
    @State private var hovering = false

    private static let size: CGFloat = 74
    private static let hues: [Color] = stride(from: 0.0, through: 360, by: 15).map {
        Color(hue: $0 / 360, saturation: 0.92, brightness: 0.98)
    }

    private var colour: Color { Color(hue: shift.hue / 360, saturation: 0.3 + 0.7 * shift.amount, brightness: 1) }

    var body: some View {
        let r = Self.size / 2
        let angle = shift.hue * .pi / 180
        let puck = CGPoint(x: r + CGFloat(cos(angle) * shift.amount) * (r - 6), y: r + CGFloat(sin(angle) * shift.amount) * (r - 6))
        VStack(spacing: 6) {
            Text(L(range.title))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            ZStack {
                // The glow of what the range is set to, behind the wheel.
                Circle()
                    .fill(colour)
                    .blur(radius: 12)
                    .opacity(shift.amount * (dragging ? 0.85 : 0.55))
                    .scaleEffect(1.05)
                Circle().fill(AngularGradient(colors: Self.hues, center: .center))
                // Colour fades towards a neutral centre: the middle is "none".
                Circle().fill(RadialGradient(colors: [Color(white: 0.26), Color(white: 0.26).opacity(0.6), .clear],
                                             center: .center, startRadius: 0, endRadius: r))
                Circle().fill(.black.opacity(0.2))
                Circle()
                    .strokeBorder(.white.opacity(0.1), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .padding(r * 0.5)
                Path { p in
                    p.move(to: CGPoint(x: r, y: 6)); p.addLine(to: CGPoint(x: r, y: Self.size - 6))
                    p.move(to: CGPoint(x: 6, y: r)); p.addLine(to: CGPoint(x: Self.size - 6, y: r))
                }
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
                Circle()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1)
                if shift.amount > 0 {
                    Path { p in p.move(to: CGPoint(x: r, y: r)); p.addLine(to: puck) }
                        .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 3, height: 3)
                Circle()
                    .fill(colour)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: shift.amount > 0 ? colour : .black.opacity(0.5), radius: dragging ? 7 : 4)
                    .scaleEffect(dragging ? 1.25 : (hovering ? 1.1 : 1))
                    .position(puck)
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .gesture(drag(r: r, puck: puck))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragging)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(L("Drag to tint the %@: the angle is the colour, the distance how much. ⇧ keeps the colour, ⌥ moves finely, double-click resets.",
                    L(range.title).lowercased()))
            HStack(spacing: 4) {
                if shift.amount > 0 {
                    Circle().fill(colour).frame(width: 6, height: 6)
                    Text("\(Int(shift.hue.rounded()))°")
                    Text("\(Int((shift.amount * 100).rounded()))").foregroundStyle(Color.accentColor)
                } else {
                    Text("—").foregroundStyle(.white.opacity(0.35))
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .frame(height: 12)
        }
        .accessibilityElement()
        .accessibilityLabel(L(range.title))
        .accessibilityValue(shift.amount > 0 ? "\(Int(shift.hue))°, \(Int(shift.amount * 100))" : L("None"))
    }

    private func drag(r: CGFloat, puck: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !dragging {
                    dragging = true
                    ignoring = (NSApp.currentEvent?.clickCount ?? 1) >= 2
                    if ignoring { return change(ColourShift(hue: shift.hue, amount: 0)) }
                    fineFrom = NSEvent.modifierFlags.contains(.option) ? (g.startLocation, puck) : nil
                }
                guard !ignoring else { return }
                var p = g.location
                if let fine = fineFrom {
                    p = CGPoint(x: fine.puck.x + (g.location.x - fine.start.x) * 0.25, y: fine.puck.y + (g.location.y - fine.start.y) * 0.25)
                }
                let v = CGPoint(x: p.x - r, y: p.y - r)
                var amount = min(1, Double(hypot(v.x, v.y) / (r - 6)))
                if amount < 0.04 { amount = 0 }
                var hue = atan2(Double(v.y), Double(v.x)) * 180 / .pi
                if hue < 0 { hue += 360 }
                if NSEvent.modifierFlags.contains(.shift), shift.amount > 0 { hue = shift.hue }
                change(ColourShift(hue: amount == 0 ? shift.hue : hue, amount: amount))
            }
            .onEnded { _ in
                dragging = false
                fineFrom = nil
                ignoring = false
            }
    }
}

// MARK: - Before and after

/// Press and hold for the original; let go for the edit. Y toggles it from the keyboard.
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
            .help("Hold to see the original (Y)")
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
