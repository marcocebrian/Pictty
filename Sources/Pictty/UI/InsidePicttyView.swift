// "Inside Pictty": the mascot shows what happens behind every picture. Every line here is
// something the engine actually does.

import SwiftUI

struct InsidePicttyView: View {
    private struct Feature: Identifiable {
        let symbol: String
        let colors: [Color]
        let title: String
        let text: String
        var id: String { title }
    }

    private static let blue = [Color(hex: 0x4285F4), Color(hex: 0x34A8F0)]
    private static let green = [Color(hex: 0x34A853), Color(hex: 0x00ACC1)]
    private static let yellow = [Color(hex: 0xFBBC04), Color(hex: 0xF57C3B)]
    private static let red = [Color(hex: 0xEA4335), Color(hex: 0xC2185B)]
    private static let violet = [Color(hex: 0xA05CE0), Color(hex: 0x7B61FF)]

    private static let features: [Feature] = [
        Feature(symbol: "sparkles", colors: violet, title: "Always the best quality",
                text: "Every time the picture stops, Pictty redraws exactly what you see, pixel for pixel, with Lanczos, the sharpest classic resampling. No blur, no jagged edges."),
        Feature(symbol: "leaf", colors: green, title: "Small details stay alive",
                text: "Shrinking is done in linear light, the way real light adds up. Foliage, stars and fine textures keep their sparkle instead of turning grey and muddy."),
        Feature(symbol: "plus.magnifyingglass", colors: blue, title: "Crisp when you zoom in",
                text: "Up to 300 %, enlarging uses Lanczos too: clean edges without the soft blur of simple scaling. Beyond that, smooth GPU filtering."),
        Feature(symbol: "cpu", colors: violet, title: "Hardware accelerated",
                text: "The GPU moves, zooms and turns the picture at your display's full refresh rate, up to 120 Hz. The sharp redraw runs on Accelerate, Apple's vector maths, without slowing anything."),
        Feature(symbol: "bolt", colors: yellow, title: "Instant",
                text: "A screen-sized picture appears first, the full one only when you zoom in, and the next pictures are already waiting."),
        Feature(symbol: "camera.aperture", colors: red, title: "Real RAW",
                text: "Apple's own RAW engine develops every camera file. You see the camera's preview straight away while it works."),
        Feature(symbol: "sun.max", colors: yellow, title: "True HDR",
                text: "HDR photos shine as bright as your screen allows: gain maps, PQ and HLG, using the brightness headroom your display has right now."),
        Feature(symbol: "square.grid.3x3.fill", colors: blue, title: "Giant pictures, every pixel",
                text: "Panoramas beyond 16,384 pixels, the GPU's limit, still show every real pixel at 100 %."),
        Feature(symbol: "scribble.variable", colors: violet, title: "Vectors always sharp",
                text: "SVG is drawn from the vector itself at every zoom, never from an enlarged picture."),
        Feature(symbol: "doc.on.doc", colors: green, title: "Every format",
                text: "JPEG, HEIC, AVIF, JPEG XL, WebP, PNG, TIFF, GIF, OpenEXR, PSD, SVG and RAW from hundreds of cameras."),
        Feature(symbol: "paintpalette", colors: red, title: "True colour",
                text: "Every picture is colour-managed for your display's own profile. Transparency shows over black, glass or a checkerboard."),
        Feature(symbol: "memorychip", colors: green, title: "Light on memory",
                text: "When macOS runs short of memory, Pictty instantly frees everything it can decode again."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                TimelineView(.animation) { context in
                    PicttyBuddy(time: context.date.timeIntervalSinceReferenceDate)
                }
                .frame(width: 92, height: 92)
                Text("Hi! I'm the Pictty orb. This is why your pictures look so good here.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(SpeechBubble().fill(.white.opacity(0.08)))
                    .overlay(SpeechBubble().stroke(.white.opacity(0.1), lineWidth: 0.5))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3),
                      spacing: 10) {
                ForEach(Self.features) { f in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            SymbolTile(symbol: f.symbol, colors: f.colors, size: 24)
                            Text(LocalizedStringKey(f.title))
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                        Text(LocalizedStringKey(f.text))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
                }
            }
        }
    }
}

/// A rounded bubble with a little tail on the left, pointing at the orb.
struct SpeechBubble: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: 14, style: .continuous)
        p.move(to: CGPoint(x: r.minX, y: r.midY - 7))
        p.addLine(to: CGPoint(x: r.minX - 8, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY + 7))
        p.closeSubpath()
        return p
    }
}
