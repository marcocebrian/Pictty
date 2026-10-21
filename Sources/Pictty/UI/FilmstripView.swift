// The filmstrip is where the comparison starts: click to move the primary
// selection, ⌘-click to add up to three more. Every selected picture joins the
// canvas, locked to the same magnification and the same point of interest.

import AppKit
import SwiftUI

struct FilmstripView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var prefs: Preferences
    let controller: ViewerWindowController

    private let itemHeight: CGFloat = 76

    /// Pinned, the strip is a bar across the bottom of the window, this tall; the picture
    /// ends where it begins.
    static let dockedHeight: CGFloat = 142

    var body: some View {
        if !model.chromeReady {
            // The picture's first frame goes out alone; the strip follows a frame later.
        } else if model.filmstripPinned { docked } else { floating }
    }

    private var content: some View {
        VStack(spacing: 0) {
            transportBar
            strip
        }
    }

    /// Revealed at the bottom edge: a card floating over the picture.
    private var floating: some View {
        content
            .liquidGlassCard(tint: 0.45)
            // Room for the inspector beside it, animated with the inspector's own toggle.
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 10, trailing: 10 + (model.showInspector || model.showLight ? 318 : 0)))
    }

    /// Pinned: edge to edge under the picture, no gaps, no corners of its own (the window's
    /// rounded corners finish it), a hairline where the picture ends.
    private var docked: some View {
        content
            .padding(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: model.showInspector || model.showLight ? 324 : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(Color.black.opacity(0.62))
                    // The same breath of light along the top edge as the floating card.
                    LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
                }
                .environment(\.colorScheme, .dark)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
            }
    }

    // MARK: - Transport

    private var transportBar: some View {
        HStack(spacing: 2) {
            GlyphButton(symbol: "chevron.left", help: "Previous (←)") { controller.previousImage(nil) }
            GlyphButton(symbol: "chevron.right", help: "Next (→)") { controller.nextImage(nil) }

            separator

            compareControls

            separator

            GlyphButton(symbol: model.slideshowRunning ? "pause.rectangle" : "play.rectangle",
                        help: model.slideshowRunning ? "Stop slideshow (S)" : "Slideshow (S)",
                        isOn: model.slideshowRunning) {
                controller.toggleSlideshow(nil)
            }

            Spacer(minLength: 10)

            Text(selectionSummary)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 10)

            sortMenu

            GlyphButton(symbol: prefs.filmstripPinned ? "pin.slash" : "pin", help: prefs.filmstripPinned ? "Auto-hide filmstrip (T)" : "Pin filmstrip (T)", isOn: prefs.filmstripPinned) {
                controller.toggleFilmstrip(nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .frame(height: 30)
    }

    @ViewBuilder
    private var compareControls: some View {
        GlyphButton(symbol: "rectangle.split.2x1",
                    help: "Add a picture to the comparison (⌘-click a thumbnail)",
                    isOn: model.isComparing) {
            controller.toggleCompare(nil)
        }

        if model.isComparing {
            GlyphButton(symbol: prefs.compareLayout.symbol,
                        help: L("Layout (L): %@", L(prefs.compareLayout.title))) {
                controller.cycleCompareLayout(nil)
            }
            GlyphButton(symbol: "arrow.left.and.right",
                        help: "Sync pan (P)",
                        isOn: prefs.syncPan) {
                controller.toggleSyncPan(nil)
            }
            GlyphButton(symbol: "magnifyingglass",
                        help: "Sync zoom (⇧P)",
                        isOn: prefs.syncZoom) {
                controller.toggleSyncZoom(nil)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: sortBinding) {
                ForEach(SortOrder.allCases) { order in
                    Text(L(order.title)).tag(order)
                }
            }
            Toggle("Include subfolders", isOn: recursiveBinding)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("Sort order")
    }

    private var sortBinding: Binding<SortOrder> {
        Binding(get: { prefs.sortOrder },
                set: { newValue in
                    prefs.sortOrder = newValue
                    controller.rescanFolder()
                })
    }

    private var recursiveBinding: Binding<Bool> {
        Binding(get: { prefs.recursive },
                set: { newValue in
                    prefs.recursive = newValue
                    controller.rescanFolder()
                })
    }

    private var selectionSummary: String {
        guard !model.items.isEmpty else { return "" }
        var parts: [String] = [model.currentSubfolder.isEmpty ? model.folderLabel
                                                               : model.folderLabel + " › " + model.currentSubfolder.replacingOccurrences(of: "/", with: " › ")]
        if model.isComparing {
            parts.append(L("comparing %ld", model.paneCount))
        }
        return parts.joined(separator: "  ·  ")
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .frame(width: 0.5, height: 13)
            .padding(.horizontal, 4)
    }

    // MARK: - Strip

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        if let folder = folderStarting(at: index) {
                            HStack(spacing: 6) {
                                FolderDivider(path: folder, root: model.folderLabel, height: itemHeight,
                                              count: count(of: folder, from: index)) { controller.select(index) }
                                cell(for: item, at: index)
                            }
                        } else {
                            cell(for: item, at: index)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onAppear { if let id = id(at: model.index) { proxy.scrollTo(id, anchor: .center) } }
            // A new folder: start at the selection, not wherever the old strip was scrolled.
            .onChange(of: model.folderURL) { _, _ in
                if let id = id(at: model.index) { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.index) { _, newValue in
                scroll(proxy, to: newValue)
            }
            .onChange(of: model.compareIndices) { _, newValue in
                guard let last = newValue.last else { return }
                scroll(proxy, to: last)
            }
        }
        .frame(height: itemHeight + 20)
    }

    /// Cells are identified by file, so a new folder gets new cells rather than recycled ones
    /// still showing the old pictures; scrolling goes through the same identity.
    private func id(at index: Int) -> String? {
        model.items.indices.contains(index) ? model.items[index].id : nil
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        guard let id = id(at: index) else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// The subfolder that begins at `index`, when the folder has subfolders.
    private func folderStarting(at index: Int) -> String? {
        guard model.hasSubfolders, model.itemFolders.indices.contains(index) else { return nil }
        let folder = model.itemFolders[index]
        return index == 0 || model.itemFolders[index - 1] != folder ? folder : nil
    }

    /// How many pictures the run of `folder` starting at `index` holds.
    private func count(of folder: String, from index: Int) -> Int {
        var n = 0
        var i = index
        while model.itemFolders.indices.contains(i), model.itemFolders[i] == folder { n += 1; i += 1 }
        return n
    }

    private func cell(for item: ImageItem, at index: Int) -> some View {
        ThumbnailCell(item: item,
                      height: itemHeight,
                      ordinal: model.ordinal(for: index),
                      isActive: model.isComparing && model.index(forPane: model.activePane) == index,
                      isAnimated: controller.isAnimated(item),
                      folderTint: model.hasSubfolders && model.itemFolders.indices.contains(index)
                          ? FolderDivider.tint(model.itemFolders[index]) : nil)
        .onTapGesture { handleTap(index: index) }
        .contextMenu { contextMenu(for: item, at: index) }
    }

    @ViewBuilder
    private func contextMenu(for item: ImageItem, at index: Int) -> some View {
        Button("Open in Default App") { NSWorkspace.shared.open(item.url) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        if index != model.index {
            Button(model.compareIndices.contains(index) ? "Remove from Comparison"
                                                        : "Add to Comparison") {
                if !model.toggleCompare(with: index) {
                    controller.showToast("Four is the most Pictty will tile", symbol: "square.grid.2x2")
                }
                controller.refreshCurrent(animated: true)
            }
        }
        if model.isComparing {
            Button("Clear Comparison") { controller.toggleCompare(nil) }
        }
    }

    /// Click moves the primary selection.
    /// ⇧-click takes the whole run between here and the anchor.
    /// ⌘- or ⌥-click adds or removes one picture.
    private func handleTap(index: Int) {
        let flags = NSEvent.modifierFlags

        if flags.contains(.shift) {
            if !model.selectRange(to: index) {
                controller.showToast("Four is the most Pictty will tile — kept the first four",
                                     symbol: "square.grid.2x2")
            }
            controller.refreshCurrent(animated: true)
            return
        }

        if flags.contains(.command) || flags.contains(.option) {
            if !model.toggleCompare(with: index) {
                controller.showToast("Four is the most Pictty will tile",
                                     symbol: "square.grid.2x2")
            }
            model.selectionAnchor = index
            controller.refreshCurrent(animated: true)
            return
        }

        // A plain click on the primary with a comparison running clears it,
        // which is the quickest way back to one picture.
        if index == model.index {
            if model.isComparing { controller.toggleCompare(nil) }
            return
        }
        controller.select(index)
    }
}

// MARK: - Cell

private struct ThumbnailCell: View {
    let item: ImageItem
    let height: CGFloat
    /// One-based position on the canvas, or nil if not part of the comparison.
    let ordinal: Int?
    let isActive: Bool

    var isAnimated = false
    /// The colour of the subfolder the picture is in, when the folder has subfolders.
    var folderTint: Color?

    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(0.05))
            content
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(border)
        .overlay(alignment: .topTrailing) { badge }
        .overlay(alignment: .bottomLeading) { animationMark }
        .overlay(alignment: .bottom) {
            if let folderTint {
                Capsule().fill(folderTint).frame(height: 2.5).padding(.horizontal, 7).padding(.bottom, 3)
                    .shadow(color: .black.opacity(0.4), radius: 1)
            }
        }
        .shadow(color: ordinal == 1 ? Color.white.opacity(0.25) : (ordinal != nil ? Color.accentColor.opacity(0.45) : .clear),
                radius: 6)
        .scaleEffect(hovering && ordinal == nil ? 1.045 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        // Keyed on the file: whatever this cell showed before, it now shows this picture.
        .task(id: item.url) {
            let url = item.url
            if let hit = ThumbStore.shared.cached(url) { image = hit; return }
            image = nil
            let thumb = await ThumbStore.shared.thumb(url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = thumb }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
        } else {
            Image(systemName: "photo")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.white.opacity(0.2))
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(borderColor, lineWidth: borderWidth)
    }

    @ViewBuilder
    private var badge: some View {
        if let ordinal {
            Text("\(ordinal)")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 15, height: 15)
                .background(Circle().fill(ordinal == 1 ? Color.white : Color.accentColor))
                .padding(4)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 0.5)
        }
    }

    @ViewBuilder
    private var animationMark: some View {
        if isAnimated {
            Image(systemName: "film.stack")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(4)
        }
    }

    private var width: CGFloat {
        let aspect = image.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? (4.0 / 3.0)
        return max(30, min(190, height * max(0.28, min(3.2, aspect))))
    }

    private var borderColor: Color {
        if ordinal == 1 { return .white.opacity(0.92) }
        if ordinal != nil { return Color.accentColor }
        if isActive { return .white.opacity(0.6) }
        return hovering ? .white.opacity(0.3) : .white.opacity(0.08)
    }

    private var borderWidth: CGFloat {
        if ordinal != nil { return 2 }
        return hovering ? 1.2 : 0.75
    }
}

// MARK: - Subfolders

/// Where a subfolder's pictures begin in the strip: its name written up the card, its own colour,
/// and how many pictures follow. A click goes to the first of them.
struct FolderDivider: View {
    let path: String
    let root: String
    let height: CGFloat
    let count: Int
    let go: () -> Void
    @State private var hovering = false

    /// A colour of the folder's own, the same every time for the same path.
    static func tint(_ path: String) -> Color {
        guard !path.isEmpty else { return Color(white: 0.75) }
        var h: UInt32 = 5381
        for b in path.utf8 { h = (h &* 33) &+ UInt32(b) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.95)
    }

    private var name: String { path.isEmpty ? root : (path.split(separator: "/").last.map(String.init) ?? path) }

    var body: some View {
        let tint = Self.tint(path)
        VStack(spacing: 2) {
            Image(systemName: path.isEmpty ? "folder" : "folder.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            // Up the card, on two lines if it needs them, a little smaller before it is cut.
            Text(name)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: height - 30, height: 24)
                .rotationEffect(.degrees(-90))
                .frame(width: 24, height: height - 30)
            Text("\(count)")
                .font(.system(size: 8.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 30, height: height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(hovering ? 0.26 : 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.45), lineWidth: 0.75))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: go)
        .help(path.isEmpty ? root : root + " › " + path.replacingOccurrences(of: "/", with: " › "))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
