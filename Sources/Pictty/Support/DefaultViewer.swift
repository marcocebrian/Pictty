// Making Pictty the app that opens pictures from Finder.
//
// Launch Services keeps one default app per file type (UTI), and a camera's RAW type does not
// inherit the choice made for its parent: a .RW2 has its own entry, as does every other
// format. Finder's "Change All…" only covers the one extension picked. So Pictty sets the types
// people actually have, one by one, through NSWorkspace. macOS asks the user to confirm each
// one (the older LSSetDefaultRoleHandlerForContentType now succeeds without changing
// anything), so the list is short, the common formats come first, and types Pictty already
// opens are never asked again. The result is read back from Launch Services.

import AppKit
import PicttyCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DefaultViewer: ObservableObject {
    static let shared = DefaultViewer()

    struct Group: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let colors: [Color]
        let types: [UTType]
        /// A few extensions to name the group by.
        var sample: String {
            let names = types.compactMap { $0.preferredFilenameExtension?.uppercased() }
            var seen = Set<String>()
            let unique = names.filter { seen.insert($0).inserted }
            return unique.prefix(8).joined(separator: " · ") + (unique.count > 8 ? " …" : "")
        }
    }

    /// Who opens each type now, by type identifier.
    @Published private(set) var handlers: [String: URL] = [:]
    @Published private(set) var working = false
    @Published var message: String?

    let groups: [Group]

    private init() {
        // Each type costs the user one confirmation from macOS, so only the formats people
        // really have, as Finder types them: by extension, most common first. A camera RAW
        // extension can map to several identifiers (.orf has three); Finder uses this one.
        func types(_ extensions: [String]) -> [UTType] {
            var seen = Set<String>()
            return extensions.compactMap { UTType(filenameExtension: $0, conformingTo: .image) }
                .filter { !$0.identifier.hasPrefix("dyn.") && seen.insert($0.identifier).inserted }
        }
        groups = [
            Group(id: "photos", title: "Photos", symbol: "photo",
                  colors: [Color(hex: 0x4285F4), Color(hex: 0x34A8F0)],
                  types: types(["jpg", "heic", "png", "webp", "avif", "jxl", "tiff", "gif", "heif", "bmp"])),
            Group(id: "raw", title: "Camera RAW", symbol: "camera.aperture",
                  colors: [Color(hex: 0xF57C3B), Color(hex: 0xEA4335)],
                  types: types(["dng", "cr3", "nef", "arw", "raf", "rw2", "cr2", "orf", "pef", "nrw", "rwl", "3fr", "iiq"])),
            Group(id: "pro", title: "HDR, layers and vectors", symbol: "sparkles",
                  colors: [Color(hex: 0xA05CE0), Color(hex: 0x7B61FF)],
                  types: types(["exr", "hdr", "psd", "svg", "tga"])),
        ].filter { !$0.types.isEmpty }
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { DefaultViewer.shared.refresh() }
        }
    }

    var allTypes: [UTType] { groups.flatMap(\.types) }

    /// Reads the current default app of every type back from Launch Services.
    func refresh() {
        var next: [String: URL] = [:]
        for type in allTypes {
            if let app = NSWorkspace.shared.urlForApplication(toOpen: type) { next[type.identifier] = app }
        }
        if next != handlers { handlers = next }
    }

    static func isPictty(_ app: URL?) -> Bool {
        guard let app else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    func owned(_ group: Group) -> Int { group.types.filter { Self.isPictty(handlers[$0.identifier]) }.count }

    /// Distinct apps other than Pictty that open part of the group now, most types first.
    func others(_ group: Group) -> [URL] {
        var counts: [URL: Int] = [:]
        for type in group.types {
            guard let app = handlers[type.identifier], !Self.isPictty(app) else { continue }
            counts[app.standardizedFileURL, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Whether Finder opens JPEGs with Pictty: the one that matters for a nudge.
    var opensJPEG: Bool { Self.isPictty(handlers[UTType.jpeg.identifier]) }

    var ownedCount: Int { allTypes.filter { Self.isPictty(handlers[$0.identifier]) }.count }

    /// Whether this copy runs from an Applications folder. Launch Services binds the choice to
    /// the bundle identifier, but a copy left in Downloads or a build folder is easily deleted,
    /// and Finder then falls back to another app.
    var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Sets Pictty (or `app`) as the default for every type of the given groups.
    func claim(_ groupIDs: Set<String>, for app: URL = Bundle.main.bundleURL) async {
        guard !working else { return }
        working = true
        message = nil
        defer { working = false; refresh() }
        // Only what is not already set: each one is a confirmation for the user.
        let target = Bundle(url: app)?.bundleIdentifier
        let types = groups.filter { groupIDs.contains($0.id) }.flatMap(\.types).filter { type in
            guard let current = handlers[type.identifier] else { return true }
            return Bundle(url: current)?.bundleIdentifier != target
        }
        for type in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            } catch {
                // The user turned one down: stop asking, keep what was accepted.
                refresh()
                message = L("Stopped: macOS kept its choice for %@.", type.preferredFilenameExtension?.uppercased() ?? type.identifier)
                return
            }
        }
        refresh()
    }

    /// How many confirmations claiming these groups will take.
    func pending(_ groupIDs: Set<String>) -> Int {
        groups.filter { groupIDs.contains($0.id) }.flatMap(\.types).filter { !Self.isPictty(handlers[$0.identifier]) }.count
    }

    /// Gives every type back to Preview.
    func restorePreview() async {
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        await claim(Set(groups.map(\.id)), for: preview)
    }
}

// MARK: - Settings page

struct DefaultViewerView: View {
    @ObservedObject var viewer = DefaultViewer.shared
    @State private var chosen: Set<String> = Set(DefaultViewer.shared.groups.map(\.id))

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            hero
            VStack(spacing: 0) {
                ForEach(viewer.groups) { group in row(group) }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))

            if let message = viewer.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Color(hex: 0xFBBC04))
            }
            if !viewer.isInApplications {
                Label(L("Pictty is running from %@. Move it to Applications first, so Finder can always find it.",
                        Bundle.main.bundleURL.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")),
                      systemImage: "folder.badge.questionmark")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Finder opens these with Pictty on a double-click. Any other app can still be picked with Open With.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button(L("Give back to Preview")) { Task { await viewer.restorePreview() } }
                    .buttonStyle(.link)
                    .font(.system(size: 11, design: .rounded))
                    .disabled(viewer.working || viewer.ownedCount == 0)
            }
        }
    }

    private var hero: some View {
        let total = viewer.allTypes.count, owned = viewer.ownedCount
        let done = owned == total
        return HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 54, height: 54)
                .overlay(alignment: .bottomTrailing) {
                    if done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white, Color(hex: 0x34A853))
                            .offset(x: 4, y: 4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(done ? L("Pictty opens all your pictures") : L("Open pictures with Pictty"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                Text(L("Default for %ld of %ld picture types", owned, total))
                    .font(.system(size: 11.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                ProgressView(value: Double(owned), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(done ? Color(hex: 0x34A853) : Color.accentColor)
                    .frame(maxWidth: 220)
            }
            Spacer(minLength: 12)
            Button {
                Task { await viewer.claim(chosen) }
            } label: {
                HStack(spacing: 6) {
                    if viewer.working { ProgressView().controlSize(.small) }
                    Text(L("Make Pictty the Default"))
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewer.working || chosen.isEmpty || chosenDone)
            .overlay(alignment: .bottom) {
                let n = viewer.pending(chosen)
                if n > 0 && !viewer.working {
                    Text(n == 1 ? L("macOS will ask you once") : L("macOS will ask you %ld times", n))
                        .font(.system(size: 10.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize()
                        .offset(y: 20)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0x4285F4, opacity: 0.22), Color(hex: 0xA05CE0, opacity: 0.16)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: done)
    }

    /// Every chosen group already opens with Pictty.
    private var chosenDone: Bool {
        viewer.groups.filter { chosen.contains($0.id) }.allSatisfy { viewer.owned($0) == $0.types.count }
    }

    private func row(_ group: DefaultViewer.Group) -> some View {
        let owned = viewer.owned(group), all = owned == group.types.count
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { chosen.contains(group.id) },
                                     set: { if $0 { chosen.insert(group.id) } else { chosen.remove(group.id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            SymbolTile(symbol: group.symbol, colors: group.colors, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(group.title))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text(group.sample)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            if all {
                Label(L("Pictty"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x34A853))
            } else {
                HStack(spacing: -6) {
                    ForEach(viewer.others(group).prefix(3), id: \.self) { app in
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 22, height: 22)
                            .help(app.deletingPathExtension().lastPathComponent)
                    }
                }
                Text(L("%ld of %ld", owned, group.types.count))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 0.5).padding(.leading, 46) }
    }
}

// MARK: - Nudge

/// The orb, in the empty window, offering to open pictures from Finder while another app
/// opens JPEGs there.
struct DefaultNudgeView: View {
    static let dismissedKey = "defaultNudgeDismissed"
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimelineView(.animation) { context in
                PicttyBuddy(time: context.date.timeIntervalSinceReferenceDate)
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 8) {
                Text("Hey there! Want me to open your pictures when you double-click them in Finder?")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L("Yes, use Pictty…")) {
                        NSApp.sendAction(#selector(AppDelegate.showDefaultViewer), to: nil, from: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(L("Not now"), action: dismiss)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: 330, alignment: .leading)
            .modifier(BubbleGlass())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The speech bubble in Liquid Glass where the system has it, frosted before.
private struct BubbleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.tint(.black.opacity(0.22)), in: SpeechBubble())
                .environment(\.colorScheme, .dark)
        } else {
            content
                .background(SpeechBubble().fill(.black.opacity(0.35)))
                .background(SpeechBubble().fill(.ultraThinMaterial))
                .overlay(SpeechBubble().stroke(.white.opacity(0.12), lineWidth: 0.5))
                .environment(\.colorScheme, .dark)
        }
    }
}
