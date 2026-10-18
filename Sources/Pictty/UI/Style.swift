// One look for every floating surface: dark glass, a hairline edge, a soft shadow, continuous
// corners. Panels, the toolbar, toasts and chips all draw through here.

import SwiftUI

enum Chrome {
    static let panelRadius: CGFloat = 18
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

struct GlassCard<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Double = 0.42
    var shadow: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.black.opacity(tint))
                    // A breath of light along the top edge.
                    shape.fill(LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center))
                }
                .shadow(color: .black.opacity(0.38), radius: shadow, y: shadow / 3)
            }
            .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
            .clipShape(shape)
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func glassCard(radius: CGFloat = Chrome.panelRadius, tint: Double = 0.42, shadow: CGFloat = 18) -> some View {
        modifier(GlassCard(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint, shadow: shadow))
    }

    func glassCapsule(tint: Double = 0.42, shadow: CGFloat = 12) -> some View {
        modifier(GlassCard(shape: Capsule(style: .continuous), tint: tint, shadow: shadow))
    }

    /// Liquid Glass on macOS 26 and later: the system's own refracting, light-catching
    /// material, darkened by half of `tint` so white text stays legible over bright pictures.
    /// A panel full of small text also passes `scrim`: a dark layer inside the glass, so the
    /// picture shows only as a hint behind the text while the edges stay glass. Earlier
    /// systems get the frosted surface.
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(in shape: S, tint: Double = 0.42, shadow: CGFloat = 18,
                                         scrim: Double = 0) -> some View {
        if #available(macOS 26, *) {
            self
                .background(shape.fill(.black.opacity(scrim)))
                .glassEffect(.regular.tint(.black.opacity(tint * 0.5)), in: shape)
                .environment(\.colorScheme, .dark)
        } else {
            modifier(GlassCard(shape: shape, tint: tint, shadow: shadow))
        }
    }

    func liquidGlassCard(radius: CGFloat = Chrome.panelRadius, tint: Double = 0.42, shadow: CGFloat = 18,
                         scrim: Double = 0) -> some View {
        liquidGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint, shadow: shadow, scrim: scrim)
    }

    func liquidGlassCapsule(tint: Double = 0.42, shadow: CGFloat = 12) -> some View {
        liquidGlass(in: Capsule(style: .continuous), tint: tint, shadow: shadow)
    }
}

/// A symbol on a small rounded tile in a gradient, the way Settings and the inspector header
/// mark what a thing is.
struct SymbolTile: View {
    let symbol: String
    var colors: [Color] = [.blue, .indigo]
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}

/// A key cap, for shortcuts shown in the empty state and the toasts.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// The app's mark, drawn live: the gradient ring and the pupil from the icon.
struct PicttyMark: View {
    var size: CGFloat = 72
    var animate = false
    /// Drives the ring directly (for a TimelineView); `animate` spins it slowly on its own.
    var rotation: Angle? = nil
    @State private var turn = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(colors: [Color(hex: 0x4285F4), Color(hex: 0x34A8F0), Color(hex: 0x34A853),
                                             Color(hex: 0xFBBC04), Color(hex: 0xEA4335), Color(hex: 0xA05CE0),
                                             Color(hex: 0x4285F4)],
                                    center: .center),
                    lineWidth: size * 0.2)
                .rotationEffect(rotation ?? .degrees(turn ? 360 : 0))
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x3D5AFE), Color(hex: 0x1A237E)],
                                     center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: size * 0.22))
                .frame(width: size * 0.4, height: size * 0.4)
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: size * 0.07, height: size * 0.07)
                .offset(x: -size * 0.06, y: -size * 0.06)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animate else { return }
            withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) { turn = true }
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
