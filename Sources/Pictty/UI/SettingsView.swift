// The preferences window. A sidebar of sections, each a short list of rows: a symbol, a
// title, one line saying what it does, and the control. Every change applies at once.

import AppKit
import PicttyCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: Preferences

    enum Section: String, CaseIterable, Identifiable {
        case viewing, information, browsing, compare, defaults, inside, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .viewing: "Viewing"
            case .information: "Information"
            case .browsing: "Browsing"
            case .compare: "Compare"
            case .defaults: "Default Viewer"
            case .inside: "Inside Pictty"
            case .about: "About"
            }
        }
        var symbol: String {
            switch self {
            case .viewing: "eye"
            case .information: "list.bullet.rectangle"
            case .browsing: "photo.stack"
            case .compare: "rectangle.split.2x1"
            case .defaults: "checkmark.seal"
            case .inside: "sparkles"
            case .about: "info.circle"
            }
        }
        var colors: [Color] {
            switch self {
            case .viewing: [Color(hex: 0x4285F4), Color(hex: 0x34A8F0)]
            case .information: [Color(hex: 0x00ACC1), Color(hex: 0x34A853)]
            case .browsing: [Color(hex: 0xFBBC04), Color(hex: 0xF57C3B)]
            case .compare: [Color(hex: 0xA05CE0), Color(hex: 0x7B61FF)]
            case .defaults: [Color(hex: 0x34A853), Color(hex: 0x4285F4)]
            case .inside: [Color(hex: 0x4285F4), Color(hex: 0xA05CE0)]
            case .about: [Color(hex: 0x34A853), Color(hex: 0x00ACC1)]
            }
        }
    }

    @ObservedObject private var router = SettingsRouter.shared
    private var section: Section { router.section }
    @State private var language = AppLanguage.current

    private var languageNote: String {
        language == AppLanguage.atLaunch ? "The language Pictty speaks" : "Takes effect when Pictty restarts"
    }

    static let compareHelp = "D compares the next picture; ⌘-click thumbnails to add up to four, ⇧-click for a range. Tab picks the pane the keys act on.\n\nWipe lays one picture exactly over the other: left of the line is picture 1, right of it picture 2. Drag the line, or click anywhere, to slide between them.\n\nBlink stacks the two and shows one at a time; B flips between them, so anything that changed jumps out."

    static let informationHelp = "This page lets you customise the two places where Pictty tells you about the picture: the floating information panel on the right, and the info pill at the bottom of the window. Switch off what you don’t need and the rest moves up; changes show at once in every window."
    static let panelHelp = "The floating panel that opens on the right with I, or the ⓘ button in the toolbar. Each switch shows or hides one of its cards. Some cards only appear when the picture has something to show, such as Location for a photo with GPS. The filter button at the top of the panel has the same switches."
    static let pillHelp = "The small caption at the bottom of the window. Choose the details it shows; whether it hides by itself or stays up is under Viewing."

    /// A grey paragraph that explains a page or a group.
    private func note(_ text: String) -> some View {
        Text(L(text))
            .font(.system(size: 11.5, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A group's title, with what it is for below it.
    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title).uppercased())
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.7))
            note(detail)
        }
    }

    /// The pill's two settings as one choice: hides by itself, always visible, or off.
    private var pillSetting: Binding<String> {
        Binding(get: { prefs.showHUD ? prefs.pillBehavior.rawValue : "off" },
                set: { value in
                    prefs.showHUD = value != "off"
                    if let behavior = ChromeBehavior(rawValue: value) { prefs.pillBehavior = behavior }
                })
    }

    /// What each field of the pill looks like.
    private static func pillExample(_ field: PillField) -> String {
        switch field {
        case .name: "097.nef"
        case .position: "12 / 240"
        case .fileSize: "24.6 MB"
        case .dimensions: "6048 × 4024"
        case .megapixels: "24.3 MP"
        case .format: "NEF"
        case .exposure: "f/2.8  ·  1/250s  ·  ISO 400  ·  50mm"
        case .camera: "NIKON Z 6"
        case .captured: L("Date and time the shutter fired")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(.white.opacity(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L(section.title))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.bottom, 2)
                    content
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(section)
            .transition(.opacity)
        }
        .frame(width: 900, height: 600)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.16), value: section)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Section.allCases) { s in
                Button { router.section = s } label: {
                    HStack(spacing: 9) {
                        SymbolTile(symbol: s.symbol, colors: s.colors, size: 24)
                        Text(L(s.title))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .foregroundStyle(.white.opacity(section == s ? 0.97 : 0.7))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(section == s ? Color.white.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 40)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 200)
        .background(Color.black.opacity(0.25))
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .viewing:
            Group_ {
                Row("Zoom on open", "How a new picture is framed (1–5)", ZoomMode.fitWindow.symbol) {
                    Picker("", selection: $prefs.zoomMode) {
                        ForEach(ViewerWindowController.zoomModes, id: \.self) { Text(L($0.title)).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                }
                Row("Background", "Behind the picture and its transparency (G)", prefs.background.symbol) {
                    Picker("", selection: $prefs.background) {
                        ForEach(CanvasBackground.allCases) { Label(L($0.title), systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                }
            }
            Group_ {
                Row("Language", languageNote, "globe") {
                    Picker("", selection: $language) {
                        Text(L("System")).tag("")
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "Español").tag("es")
                    }
                    .labelsHidden().frame(width: 170)
                    .onChange(of: language) { _, value in AppLanguage.set(value) }
                }
                if language != AppLanguage.atLaunch {
                    HStack {
                        Spacer()
                        Button(L("Restart Pictty")) { AppLanguage.relaunch() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
            }
            Group_ {
                Row("Toolbar", "The buttons at the top of the window", "menubar.rectangle") {
                    Picker("", selection: $prefs.toolbarBehavior) {
                        ForEach(ChromeBehavior.allCases) { Text(L($0.title)).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                }
                Row("Info pill", "File name, size and exposure at the bottom (/)", "text.bubble") {
                    Picker("", selection: pillSetting) {
                        ForEach(ChromeBehavior.allCases) { Text(L($0.title)).tag($0.rawValue) }
                        Text(L("Off")).tag("off")
                    }
                    .labelsHidden().frame(width: 170)
                }
                Row("Filmstrip pinned", "Keep the strip up instead of revealing it at the bottom edge (T)",
                    "rectangle.bottomthird.inset.filled") {
                    Toggle("", isOn: $prefs.filmstripPinned).toggleStyle(.switch).labelsHidden()
                }
                Row("Crossfade", "Dissolve between pictures", "circle.lefthalf.filled") {
                    Toggle("", isOn: $prefs.animateTransitions).toggleStyle(.switch).labelsHidden()
                }
            }
        case .information:
            note(Self.informationHelp)
            heading("Information panel (I)", Self.panelHelp)
            Group_ {
                ForEach(InspectorSection.allCases) { section in
                    Row(section.title, section.detail, section.symbol) {
                        Toggle("", isOn: Binding(get: { prefs.shows(section) }, set: { prefs.setShows(section, $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            heading("Info pill (/)", Self.pillHelp)
                .padding(.top, 6)
            Group_ {
                ForEach(PillField.allCases) { field in
                    Row(field.title, Self.pillExample(field), field.symbol) {
                        Toggle("", isOn: Binding(get: { prefs.shows(field) }, set: { prefs.setShows(field, $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        case .browsing:
            Group_ {
                Row("Reopen where you left off", "Opening Pictty by itself comes back to the last folder and picture",
                    "clock.arrow.circlepath") {
                    Toggle("", isOn: $prefs.restoreSession).toggleStyle(.switch).labelsHidden()
                }
                Row("Sort by", "Order of the folder and the filmstrip", "arrow.up.arrow.down") {
                    Picker("", selection: $prefs.sortOrder) {
                        ForEach(SortOrder.allCases) { Text(L($0.title)).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                }
                Row("Include subfolders", "Everything below the folder, in one run", "folder.badge.plus") {
                    Toggle("", isOn: $prefs.recursive).toggleStyle(.switch).labelsHidden()
                }
                Row("Wrap around", "After the last picture comes the first", "arrow.triangle.2.circlepath") {
                    Toggle("", isOn: $prefs.loopFolder).toggleStyle(.switch).labelsHidden()
                }
            }
            if FolderAccess.isSandboxed { FolderAccessRows() }
            Group_ {
                Row("Slideshow interval", L("%ld seconds per picture (S)", Int(prefs.slideshowInterval)), "play.rectangle") {
                    Slider(value: $prefs.slideshowInterval, in: 1...30, step: 1).frame(width: 170)
                }
                Row("Decode ahead", prefs.prefetchDepth == 1 ? L("1 picture on each side, ready before you get there")
                    : L("%ld pictures on each side, ready before you get there", prefs.prefetchDepth),
                    "bolt.horizontal") {
                    Stepper("", value: $prefs.prefetchDepth, in: 0...6).labelsHidden()
                }
            }
        case .compare:
            Group_ {
                Row("Layout", "How the pictures share the window (L)", prefs.compareLayout.symbol) {
                    Picker("", selection: $prefs.compareLayout) {
                        ForEach(CompareLayout.allCases) { Label(L($0.title), systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                }
                Row("Sync pan", "Move one, move all (P)", "arrow.left.and.right") {
                    Toggle("", isOn: $prefs.syncPan).toggleStyle(.switch).labelsHidden()
                }
                Row("Sync zoom", "Zoom one, zoom all, matched by width (⇧P)", "magnifyingglass") {
                    Toggle("", isOn: $prefs.syncZoom).toggleStyle(.switch).labelsHidden()
                }
            }
            Text(L(Self.compareHelp))
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        case .defaults:
            DefaultViewerView()
        case .inside:
            InsidePicttyView()
        case .about:
            AboutView(compact: true)
        }
    }
}

/// The App Store build only: lets the user allow the home folder or the whole disk up front, so
/// opening a picture from a new folder never stops to ask.
private struct FolderAccessRows: View {
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        Group_ {
            Row("Folder access", FolderAccess.isAllowed(FolderAccess.disk) ? "Pictty can open every folder on this disk"
                : FolderAccess.isAllowed(FolderAccess.home) ? "Pictty can open every folder in your home folder"
                : "macOS asks once for each new folder; allow more here", "lock.open") {
                HStack(spacing: 8) {
                    Button(L("Home Folder…")) { FolderAccess.allow(FolderAccess.home) { refresh += 1 } }
                        .disabled(FolderAccess.isAllowed(FolderAccess.home))
                    Button(L("Whole Disk…")) { FolderAccess.allow(FolderAccess.disk) { refresh += 1 } }
                        .disabled(FolderAccess.isAllowed(FolderAccess.disk))
                }
            }
        }
    }
}

/// The page Settings shows, so a menu item can open it on a given one.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var section: SettingsView.Section = .viewing
}

/// A rounded group of rows.
private struct Group_<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
    }
}

private struct Row<Control: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder var control: Control

    init(_ title: String, _ detail: String, _ symbol: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.92))
                Text(L(detail)).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 0.5).padding(.leading, 46) }
    }
}

// MARK: - About

struct AboutView: View {
    var compact = false
    @State private var glow = false

    /// "Version 1.0 · build 241 · 18 Oct 2026": build.sh numbers every build and dates it.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        guard let stamp = info?["PicttyBuildDate"] as? String,
              let date = ISO8601DateFormatter().date(from: stamp) else { return L("Version %@ · build %@", short, build) }
        let day = date.formatted(.dateTime.day().month(.abbreviated).year())
        return L("Version %@ · build %@ · %@", short, build, day)
    }

    var body: some View {
        VStack(spacing: compact ? 10 : 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: compact ? 84 : 112, height: compact ? 84 : 112)
                .shadow(color: Color(hex: 0x4285F4).opacity(glow ? 0.45 : 0.15), radius: glow ? 26 : 12)
                // The mascot peeks out from behind the icon's corner.
                .overlay(alignment: .bottomTrailing) {
                    TimelineView(.animation) { context in
                        PicttyBuddy(time: context.date.timeIntervalSinceReferenceDate)
                    }
                    .frame(width: compact ? 44 : 56, height: compact ? 44 : 56)
                    .offset(x: compact ? 26 : 34, y: compact ? 10 : 14)
                }
                .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever()) { glow = true } }
            Text("Pictty")
                .font(.system(size: compact ? 24 : 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
            Text(version)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.45))
            Text("A fast, quiet viewer for pictures.\nEvery format ImageIO can read, RAW, HDR and SVG included.")
                .font(.system(size: 12, design: .rounded))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 2)
            VStack(spacing: 3) {
                Text("Marco Cebrián Muiño")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text("© 2026")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 8)
            Link(destination: URL(string: "https://noxdrop.com")!) {
                Label(L("More apps at noxdrop.com"), systemImage: "square.grid.2x2")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .padding(.top, 4)
            .help("noxdrop.com")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 8 : 34)
        .padding(.horizontal, 30)
    }
}

// MARK: - Windows

/// Dark, full-size-content panels for Settings and About.
@MainActor
enum AuxWindows {
    private static var settings: NSWindow?
    private static var about: NSWindow?

    static func showSettings(prefs: Preferences) {
        if settings == nil {
            settings = make(title: "Pictty Settings", view: AnyView(SettingsView(prefs: prefs)))
        }
        present(settings)
    }

    static func showAbout() {
        if about == nil {
            about = make(title: "About Pictty", view: AnyView(
                AboutView().frame(width: 380)))
        }
        present(about)
    }

    private static func make(title: String, view: AnyView) -> NSWindow {
        // Under the transparent titlebar too, so the glass runs to the top edge.
        let host = NSHostingView(rootView: AnyView(
            view
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ZStack { Color.black.opacity(0.55); Rectangle().fill(.ultraThinMaterial.opacity(0.6)) })
                .environment(\.colorScheme, .dark)
                .ignoresSafeArea()))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = title
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .black
        w.contentView = host
        w.center()
        return w
    }

    private static func present(_ w: NSWindow?) {
        w?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Language

/// The app's own language, independent of the system's: "" follows the system.
enum AppLanguage {
    private static var domain: [String: Any] {
        UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    }

    /// What is set now ("" for the system's choice).
    static var current: String { (domain["AppleLanguages"] as? [String])?.first ?? "" }

    /// What this run of Pictty started with.
    static let atLaunch = current

    static func set(_ code: String) {
        if code.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
