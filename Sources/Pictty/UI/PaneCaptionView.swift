// The caption for one subdivision while comparing.
//
// It is centred on its own pane and carries a quiet monochrome plate. The
// plate is not decoration: white type alone disappears over a bright sky or a
// snowfield, and a caption you cannot read is worse than no caption. It stays
// black and white — no colour, no border — so it reads as part of the picture
// rather than as a control.
//
// Content is what you actually compare by: file name, pixel dimensions, and
// the exposure triangle, in that order.
//
// It outlives the rest of the overlay by several seconds: the toolbar is a
// control surface you look at deliberately, but these are the labels for the
// things in front of you, and hiding them the moment the pointer settles means
// nobody ever finishes reading one.

import SwiftUI

struct PaneCaptionView: View {
    let caption: ViewerModel.PaneCaption
    let visible: Bool

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(caption.ordinal)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(caption.isActive ? 0.7 : 0.42))

                Text(caption.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(caption.isActive ? 0.97 : 0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if caption.isHDR {
                    HDRBadge(headroom: caption.headroom, compact: true)
                }
            }

            if !caption.hint.isEmpty {
                Text(caption.hint)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor.mix(with: .white, by: 0.3))
                    .lineLimit(1)
            }

            if !detailText.isEmpty {
                Text(detailText)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(caption.isActive ? 0.6 : 0.42))
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        // Never wider than the pane it belongs to, so a long name cannot spill
        // into its neighbour and make the layout read as broken.
        // Hugs its text, but never wider than its pane.
        .frame(maxWidth: max(110, caption.rect.width - 60))
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .liquidGlassCard(radius: 11, tint: caption.isActive ? 0.5 : 0.42)
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(caption.isActive ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.45), value: visible)
        .animation(.easeInOut(duration: 0.2), value: caption.isActive)
        .allowsHitTesting(false)
    }

    /// Dimensions and the exposure triangle, joined only where both exist.
    private var detailText: String {
        [caption.size, caption.exposure]
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
    }
}
