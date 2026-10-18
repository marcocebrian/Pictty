// The installer DMG's window background (English, whatever the system language), drawn with the app's own orb so the two always match.
//   Pictty --dmg-background <dir>   → <dir>/background.png, background@2x.png (640×400 points)
// tools/release.sh places the icons at (170, 200) and (470, 200), in the same top-left points.

import AppKit
import SwiftUI

struct DMGBackground: View {
    static let size = CGSize(width: 640, height: 400)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xFFFFFF), Color(hex: 0xE8F0FE)], startPoint: .top, endPoint: .bottom)
            // Soft light under each icon slot.
            ForEach([170.0, 470.0], id: \.self) { x in
                Circle()
                    .fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: 100))
                    .frame(width: 200, height: 200)
                    .position(x: x, y: 200)
            }
            VStack(spacing: 4) {
                Text(verbatim: "Install Pictty")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x1A237E))
                Text(verbatim: "Drag Pictty onto the Applications folder")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color(hex: 0x1A237E).opacity(0.6))
            }
            .position(x: 320, y: 52)
            // The orb, between the two, cheering the drag on.
            PicttyBuddy(time: 1.15)
                .frame(width: 92, height: 92)
                .position(x: 320, y: 168)
            ZStack {
                Arrow(part: .shaft)
                    .stroke(Color(hex: 0x4285F4).opacity(0.75),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [0.1, 10]))
                Arrow(part: .head)
                    .stroke(Color(hex: 0x4285F4).opacity(0.75),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 120, height: 24)
            .position(x: 320, y: 228)
            Text(verbatim: "Then open Pictty once: the orb will offer to open all your pictures.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(hex: 0x1A237E).opacity(0.5))
                .position(x: 320, y: 352)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .light)
    }

    /// A dotted shaft and a solid head, drawn apart so only the shaft is dotted.
    private struct Arrow: Shape {
        enum Part { case shaft, head }
        let part: Part
        func path(in r: CGRect) -> Path {
            var p = Path()
            if part == .shaft {
                p.move(to: CGPoint(x: r.minX, y: r.midY))
                p.addLine(to: CGPoint(x: r.maxX - 14, y: r.midY))
                return p
            }
            p.move(to: CGPoint(x: r.maxX - 12, y: r.midY - 9))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX - 12, y: r.midY + 9))
            return p
        }
    }

    @MainActor
    static func write(to dir: URL) throws {
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: DMGBackground())
            renderer.scale = scale
            guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = NSSize(width: size.width, height: size.height)
            let name = scale == 1 ? "background.png" : "background@2x.png"
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
    }
}
