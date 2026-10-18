// Every key, on one card. `?` shows it, `?` or Esc puts it away.

import SwiftUI

struct ShortcutsView: View {
    struct Group: Identifiable {
        let title: String
        let symbol: String
        let colors: [Color]
        let rows: [(keys: [String], text: String)]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Browse", symbol: "photo.stack", colors: [Color(hex: 0x4285F4), Color(hex: 0x34A8F0)], rows: [
            (["←", "→"], "Previous / next picture"),
            (["Space"], "Next picture (⇧ for previous)"),
            (["Home", "End"], "First / last picture"),
            (["S"], "Slideshow"),
            (["T"], "Pin the filmstrip or let it hide"),
            (["⌘", "O"], "Open a picture or folder"),
        ]),
        Group(title: "Zoom", symbol: "plus.magnifyingglass", colors: [Color(hex: 0x34A853), Color(hex: 0x00ACC1)], rows: [
            (["1", "–", "5"], "Actual · Best Fit · Fit · Remember · Lock"),
            (["Z"], "100 % at the pointer, and back"),
            (["⌘", "+"], "Zoom in"),
            (["⌘", "−"], "Zoom out"),
            (["⌘", "0"], "Back to the zoom mode"),
            (["↑", "↓"], "Pan a zoomed picture"),
        ]),
        Group(title: "Look closer", symbol: "eyedropper", colors: [Color(hex: 0xFBBC04), Color(hex: 0xF57C3B)], rows: [
            (["⌥"], "Hold for the loupe and colour picker"),
            (["⌥", "click"], "Copy the colour under the pointer"),
            (["J"], "Clipping warnings"),
            (["I"], "Information, with the histogram"),
            (["G"], "Background: glass, black, checkerboard"),
            (["/"], "Info pill"),
        ]),
        Group(title: "Compare", symbol: "rectangle.split.2x1", colors: [Color(hex: 0xA05CE0), Color(hex: 0x7B61FF)], rows: [
            (["D"], "Compare with the next picture (again to add)"),
            (["⌘", "click"], "Add a thumbnail to the comparison"),
            (["L"], "Layout: side by side, stacked, grid, wipe, blink"),
            (["B"], "Blink: flip between the two"),
            (["P"], "Sync pan  (⇧P sync zoom)"),
            (["Tab"], "Next pane"),
        ]),
        Group(title: "Picture", symbol: "wand.and.stars", colors: [Color(hex: 0xEA4335), Color(hex: 0xC2185B)], rows: [
            (["[", "]"], "Rotate left / right"),
            (["M"], "Mirror"),
            (["F", "↩"], "Full screen"),
            (["⌘", "C"], "Copy the picture"),
            (["⌘", "R"], "Reveal in Finder"),
            (["⌘", "⌫"], "Move to Trash"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SymbolTile(symbol: "keyboard", colors: [Color(hex: 0x4285F4), Color(hex: 0xA05CE0)], size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("Press ? or Esc to close")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top),
                                GridItem(.flexible(), spacing: 14, alignment: .top),
                                GridItem(.flexible(), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(Self.groups) { group in groupCard(group) }
            }
        }
        .padding(22)
        .frame(maxWidth: 940)
        .liquidGlassCard(radius: 22, tint: 0.8, scrim: 0.62)
        .padding(30)
    }

    private func groupCard(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                SymbolTile(symbol: group.symbol, colors: group.colors, size: 20)
                Text(LocalizedStringKey(group.title))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in
                            if key == "–" {
                                Text("–").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                            } else {
                                KeyCap(text: L(key))
                            }
                        }
                    }
                    .frame(minWidth: 58, alignment: .leading)
                    Text(LocalizedStringKey(row.text))
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }
}
