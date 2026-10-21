// The always-on layer. Everything here is *text over the picture* — no bars,
// no boxes competing with the image, just translucent type that fades the
// moment the viewer stops moving.

import SwiftUI

// MARK: - Root HUD

struct HUDOverlay: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        // Nothing until the picture's first frame is up; the pill follows a frame later.
        Group {
            if model.chromeReady {
                GeometryReader { geometry in
                    content(size: geometry.size)
                }
            }
        }
        // Pane rectangles come from the canvas in window points, so this layer must not be
        // shifted by the titlebar's safe area.
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func content(size: CGSize) -> some View {
        ZStack {
            if model.items.isEmpty && !model.isScanning {
                EmptyStateView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if let failed = model.failedPath, model.current?.url.path == failed {
                Label("Can’t decode \((failed as NSString).lastPathComponent)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }

            if model.isComparing {
                // One caption per subdivision, each attached to its own pane.
                // A single centred pill would name only the first picture and
                // leave the other three anonymous.
                ForEach(model.paneCaptions) { caption in
                    // Centred on the pane it describes, just above its bottom edge, and
                    // above the filmstrip when it is up, so the strip never hides a name.
                    PaneCaptionView(caption: caption, visible: model.captionsVisible)
                        .position(x: caption.rect.midX,
                                  y: min(caption.rect.maxY, size.height - (model.filmstripVisible ? 142 : 0)) - 30)
                }
            } else if model.showHUD, model.current != nil && !prefs.pillFields.isEmpty || model.isScanning {
                VStack {
                    Spacer()
                    infoPill
                        .padding(.bottom, filmstripInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

            VStack {
                if let toast = model.toast {
                    ToastView(message: toast)
                        .id(toast.id)
                        .padding(.top, 82)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.82, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -8)),
                            removal: .scale(scale: 0.94).combined(with: .opacity)))
                }
                Spacer()
            }

            // Work going on in the picture, top left: the RAW develop, the noise reduction.
            if model.denoiseProgress != nil || model.denoiseDone, model.current != nil, !model.isComparing {
                VStack {
                    HStack {
                        DenoiseBadge(progress: model.denoiseProgress, everyPixel: model.denoiseFull)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, model.rawStatus == nil ? 62 : 106)
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading)))
                .animation(Chrome.spring, value: model.denoiseProgress == nil)
            }

            if let raw = model.rawStatus, model.current != nil, !model.isComparing {
                VStack {
                    HStack {
                        RawBadge(status: raw)
                        Spacer()
                    }
                    Spacer()
                }
                // Below the toolbar row, which spans narrow windows.
                .padding(.top, 62)
                .padding(.leading, 18)
                // Developing is news, so it stays up; once developed it comes and goes with the chrome.
                .opacity(raw == .developing || model.chromeVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.32), value: model.chromeVisible)
                .animation(Chrome.spring, value: raw)
                .transition(.opacity)
            }

            if model.showShortcuts {
                ZStack {
                    Color.black.opacity(0.35)
                    ShortcutsView()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if let text = model.loadingText {
                LoadingBadge(text: text)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: model.items.isEmpty)
        .animation(.easeInOut(duration: 0.28), value: model.isScanning)
        .animation(.easeInOut(duration: 0.25), value: model.showHUD)
        .animation(.smooth(duration: 0.28), value: model.filmstripVisible)
        .frame(width: size.width, height: size.height)
    }

    private var filmstripInset: CGFloat {
        model.filmstripVisible ? 152 : 26
    }

    // MARK: Bottom pill

    private var infoPill: some View {
        VStack(spacing: 3) {
            if let item = model.current {
                let report = model.report
                if shows(.name) {
                    HStack(spacing: 8) {
                        Text(item.displayName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if model.isProvisional {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                                .frame(width: 10, height: 10)
                        }
                    }
                }

                // The facts the user picked, in the pill's own order, a dot between each.
                let facts = facts(item, report)
                if !facts.isEmpty || report.isHDR || model.slideshowRunning {
                    HStack(spacing: 9) {
                        ForEach(Array(facts.enumerated()), id: \.element.field) { n, fact in
                            if n > 0 { dot }
                            if fact.field == .position {
                                Label(fact.text, systemImage: "photo.stack").monospacedDigit()
                            } else {
                                Text(fact.text).monospacedDigit()
                            }
                        }
                        if report.isHDR {
                            HDRBadge(headroom: report.contentHeadroom)
                        }
                        if model.slideshowRunning {
                            if !facts.isEmpty { dot }
                            Label("Slideshow", systemImage: "play.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                }

                let lower = [shows(.camera) ? report.cameraLine : nil,
                             shows(.exposure) ? report.exposureLine : nil,
                             shows(.captured) ? report.capturedLine : nil].compactMap { $0 }
                if !lower.isEmpty {
                    Text(lower.joined(separator: "  ·  "))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(.top, 1)
                }
            } else if model.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("Reading folder…")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .liquidGlassCapsule(tint: 0.44, shadow: 12)
        .opacity(model.chromeVisible || model.items.isEmpty || prefs.pillBehavior == .always ? 1 : 0)
        .animation(.easeInOut(duration: 0.32), value: model.chromeVisible)
    }

    private func shows(_ field: PillField) -> Bool { prefs.pillFields.contains(field) }

    /// The middle row of the pill.
    private func facts(_ item: ImageItem, _ report: MetadataReport) -> [(field: PillField, text: String)] {
        prefs.pillFields.compactMap { field in
            switch field {
            case .position: (field, model.positionLabel)
            case .fileSize: (field, item.formattedFileSize)
            // Size and megapixels read as one fact, as they always have.
            case .dimensions:
                (field, [report.headline.isEmpty ? "—" : report.headline,
                         shows(.megapixels) && !report.subheadline.isEmpty ? L(report.subheadline) : nil]
                    .compactMap { $0 }.joined(separator: "  "))
            case .megapixels: report.subheadline.isEmpty || shows(.dimensions) ? nil : (field, L(report.subheadline))
            case .format: (field, item.fileExtension)
            case .name, .exposure, .camera, .captured: nil
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(.white.opacity(0.22))
            .frame(width: 2.5, height: 2.5)
    }
}

// MARK: - Pieces

/// Marks a picture whose highlights go beyond SDR white.
///
/// Monochrome on purpose, and identical wherever it appears — the centred pill
/// when there is one picture, and the per-pane caption when there are several.
/// The point is to be recognised at a glance, not to decorate.
struct HDRBadge: View {
    var headroom: Float = 1
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 2 : 3) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: compact ? 7 : 8, weight: .bold))
            Text("HDR")
                .font(.system(size: compact ? 8 : 8.5, weight: .heavy, design: .rounded))
                .tracking(0.4)
        }
        .foregroundStyle(.black.opacity(0.85))
        .padding(.horizontal, compact ? 4 : 5)
        .padding(.vertical, compact ? 1 : 1.5)
        .background(
            Capsule(style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(white: 0.82)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .help(headroom > 1.0001 ? L("High dynamic range — %.1f× SDR white", headroom) : L("High dynamic range"))
    }
}

struct ToastView: View {
    let message: ToastMessage
    @State private var bounce = 0

    var body: some View {
        HStack(spacing: 9) {
            if let symbol = message.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: bounce)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            }
            Text(message.text)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.94))
        }
        .padding(.leading, message.symbol == nil ? 14 : 6)
        .padding(.trailing, 15)
        .padding(.vertical, 6)
        .liquidGlassCapsule(tint: 0.5, shadow: 14)
        .onAppear { bounce += 1 }
    }

    private var tint: [Color] {
        switch message.tone {
        case .neutral: [Color(hex: 0x4285F4), Color(hex: 0x7B61FF)]
        case .success: [Color(hex: 0x34A853), Color(hex: 0x00ACC1)]
        case .warning: [Color(hex: 0xFBBC04), Color(hex: 0xF57C3B)]
        case .error: [Color(hex: 0xEA4335), Color(hex: 0xC2185B)]
        }
    }
}

/// Shown while a picture decodes or a RAW develops: Pictty's little buddy, a soft gradient orb
/// that breathes and wobbles, bounces, looks around and blinks while it works.
struct LoadingBadge: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.animation) { context in
                PicttyBuddy(time: context.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: 84, height: 84)
            TimelineView(.periodic(from: .now, by: 0.4)) { context in
                let dots = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 4
                Text(text.replacingOccurrences(of: "…", with: "") + String(repeating: ".", count: dots))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 140)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(maxWidth: 340)
        .liquidGlassCard(radius: 22, tint: 0.5)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

/// The orb, drawn for one moment in time.
struct PicttyBuddy: View {
    let time: TimeInterval

    var body: some View {
        Canvas { ctx, size in
            let t = time
            let radius = size.width * 0.32
            // Bounce: up and down, squashing a little when it lands.
            let hop = abs(sin(t * 2.4))
            let squash = 1 + 0.06 * (1 - hop) * (1 - hop)
            let c = CGPoint(x: size.width / 2, y: size.height / 2 + radius * 0.2 - CGFloat(hop) * radius * 0.22)
            let body = Self.blob(center: c, radius: radius, time: t, sx: squash, sy: 2 - squash)

            // A white body with a blue accent drifting round it, melted in rather than meeting at
            // a point. The orb is always these colours, wherever it appears.
            let colors: [Color] = [.white, .white, Color(hex: 0xE8F0FE), Color(hex: 0x8AB4F8),
                                   Color(hex: 0x4285F4), Color(hex: 0xD2E3FC), .white]
            let shading = GraphicsContext.Shading.conicGradient(Gradient(colors: colors), center: c, angle: .degrees(t * 50))
            let wide = Path(ellipseIn: CGRect(x: c.x - radius * 1.6, y: c.y - radius * 1.6, width: radius * 3.2, height: radius * 3.2))

            ctx.drawLayer { glow in
                glow.addFilter(.blur(radius: radius * 0.45))
                glow.opacity = 0.55
                glow.fill(body, with: .color(Color(hex: 0x4285F4)))
            }
            ctx.drawLayer { fill in
                fill.clip(to: body)
                fill.addFilter(.blur(radius: radius * 0.38))
                fill.fill(wide, with: shading)
            }
            // A soft shine, top left.
            ctx.fill(body, with: .radialGradient(
                Gradient(colors: [.white.opacity(0.5), .white.opacity(0)]),
                center: CGPoint(x: c.x - radius * 0.35, y: c.y - radius * 0.45), startRadius: 0, endRadius: radius * 0.85))

            // Face: eyes that glance about and blink, and a pale blush.
            let look = CGPoint(x: CGFloat(sin(t * 0.9)) * radius * 0.14, y: CGFloat(sin(t * 0.6)) * radius * 0.05)
            let open = Self.blink(t)
            for side in [-1.0, 1.0] {
                let ex = c.x + CGFloat(side) * radius * 0.3 + look.x
                let eye = CGRect(x: ex - radius * 0.105, y: c.y - radius * 0.1 + look.y - radius * 0.19 * open,
                                 width: radius * 0.21, height: radius * 0.38 * open)
                ctx.fill(Path(roundedRect: eye, cornerRadius: radius * 0.105), with: .color(Color(hex: 0x1A237E)))
                let cheek = CGRect(x: ex + CGFloat(side) * radius * 0.12 - radius * 0.11, y: c.y + radius * 0.2 + look.y,
                                   width: radius * 0.22, height: radius * 0.12)
                ctx.fill(Path(ellipseIn: cheek), with: .color(Color(hex: 0x8AB4F8).opacity(0.6)))
            }
        }
    }

    /// A circle that wobbles a little at two slow frequencies, so it looks alive, not spun.
    static func blob(center c: CGPoint, radius r: CGFloat, time t: TimeInterval, sx: CGFloat, sy: CGFloat) -> Path {
        var path = Path()
        let n = 72
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            let wobble = 1 + 0.03 * sin(3 * a + t * 1.6) + 0.018 * sin(5 * a - t * 1.1)
            let p = CGPoint(x: c.x + CGFloat(cos(a) * wobble) * r * sx, y: c.y + CGFloat(sin(a) * wobble) * r * sy)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }

    /// Open (1) most of the time; a quick blink every 2.8 s, a double blink every third time.
    static func blink(_ t: TimeInterval) -> CGFloat {
        let cycle = t.truncatingRemainder(dividingBy: 8.4)
        for start in [2.8, 5.6, 8.0] where cycle >= start && cycle < start + 0.18 {
            return CGFloat(max(0.12, abs(cos((cycle - start) / 0.18 * .pi))))
        }
        return 1
    }
}

/// Floats in the top-left corner over a RAW: the RAW chip, and while the real develop runs,
/// the orb bobbing beside it.
struct RawBadge: View {
    let status: ViewerModel.RawStatus
    @State private var floating = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: status == .developed ? "checkmark.seal.fill" : "camera.aperture")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(status == .developed ? Color(hex: 0x34A853) : .white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                Text("RAW")
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .liquidGlassCapsule(tint: 0.5, shadow: 8)

            if status == .developing {
                HStack(spacing: 2) {
                    TimelineView(.animation) { context in
                        PicttyBuddy(time: context.date.timeIntervalSinceReferenceDate)
                    }
                    .frame(width: 38, height: 38)
                    // Only the character floats; the words and the capsule stay put.
                    .offset(y: floating ? -2.5 : 2.5)
                    .animation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true), value: floating)
                    Text("developing")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.6), radius: 3)
                }
                .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
                                        removal: .scale(scale: 1.3).combined(with: .opacity).combined(with: .offset(y: -10))))
            }
        }
        .onAppear { floating = true }
    }
}

/// The noise reduction at work, like the RAW develop: the network's own capsule, Pictty's little
/// character keeping it company, and how far it is. A moment of "noise reduced" when it is done.
struct DenoiseBadge: View {
    /// nil once done.
    let progress: Double?
    /// Going over every pixel (zoomed in, or saving) rather than the picture on screen.
    let everyPixel: Bool
    @State private var floating = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: progress == nil ? "checkmark.seal.fill" : "wand.and.sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(progress == nil ? Color(hex: 0x34A853) : Color(hex: 0xB9A8FF))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: progress != nil)
                Text("NOISE")
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .liquidGlassCapsule(tint: 0.5, shadow: 8)

            if let progress {
                HStack(spacing: 2) {
                    TimelineView(.animation) { context in
                        PicttyBuddy(time: context.date.timeIntervalSinceReferenceDate)
                    }
                    .frame(width: 38, height: 38)
                    // Only the character floats; the words and the capsule stay put.
                    .offset(y: floating ? -2.5 : 2.5)
                    .animation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true), value: floating)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(everyPixel ? "reducing noise in every pixel" : "reducing noise")
                            Text("\(Int((progress * 100).rounded())) %")
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                                .contentTransition(.numericText(value: progress))
                        }
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        // A fine line filling up, in the network's colour.
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.15))
                                Capsule()
                                    .fill(LinearGradient(colors: [Color(hex: 0x9C8CF0), Color(hex: 0x6A4CE0)],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(3, geo.size.width * progress))
                                    .shadow(color: Color(hex: 0x9C8CF0).opacity(0.7), radius: 3)
                            }
                        }
                        .frame(width: 120, height: 3)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .animation(.easeOut(duration: 0.2), value: progress)
                }
                .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
                                        removal: .scale(scale: 1.3).combined(with: .opacity).combined(with: .offset(y: -10))))
            } else {
                Text("noise reduced")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .transition(.opacity)
            }
        }
        .animation(Chrome.spring, value: progress == nil)
        .onAppear { floating = true }
    }
}

struct EmptyStateView: View {
    @State private var appear = false

    var body: some View {
        VStack(spacing: 18) {
            PicttyMark(size: 84, animate: true)
                .shadow(color: Color(hex: 0x4285F4).opacity(0.35), radius: 24)
                .scaleEffect(appear ? 1 : 0.92)
                .opacity(appear ? 1 : 0)
            VStack(spacing: 6) {
                Text("Drop pictures or a folder here")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Text("Every format ImageIO reads, plus RAW, HDR, GIF and SVG")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }
            HStack(spacing: 14) {
                hint("Open", ["⌘", "O"])
                hint("Folder", ["⌥", "⌘", "O"])
                hint("Settings", ["⌘", ","])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlassCapsule(tint: 0.35, shadow: 8)
            .opacity(appear ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.05)) { appear = true } }
    }

    private func hint(_ title: String, _ keys: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { KeyCap(text: $0) }
            Text(L(title))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.leading, 2)
        }
    }
}
