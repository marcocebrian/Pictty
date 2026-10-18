// Folder access for the sandboxed build (the Mac App Store's).
//
// A sandboxed app opened on one picture from Finder may read that picture and nothing else, so
// the filmstrip would hold one picture. Pictty asks once, with the folder already chosen in
// an Open panel, and keeps a security-scoped bookmark: the folder, and everything inside it,
// opens without asking from then on, across launches. A folder picked in Open Folder… or Open…
// is remembered the same way. Outside the sandbox (the notarised download) all of this is a
// no-op and nothing is asked.

import AppKit

@MainActor
enum FolderAccess {
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private static let key = "folderAccess"
    /// Bookmarks by folder path.
    private static var bookmarks: [String: Data] {
        get { Preferences.store.dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { Preferences.store.set(newValue, forKey: key) }
    }
    /// Folders opened for this run; access stays on until Pictty quits.
    private static var started: Set<String> = []
    /// Folders the user said no to in this run: not asked again until the next launch.
    private static var declined: Set<String> = []

    /// Turns on a remembered grant that covers `url` (the folder itself or one above it).
    static func restore(for url: URL) {
        guard isSandboxed else { return }
        let path = url.standardizedFileURL.path
        for (granted, data) in bookmarks where covers(granted, path) && !started.contains(granted) {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                          relativeTo: nil, bookmarkDataIsStale: &stale) else {
                bookmarks[granted] = nil
                continue
            }
            if resolved.startAccessingSecurityScopedResource() {
                started.insert(granted)
                if stale { remember(resolved) }
            }
        }
    }

    /// Keeps the access the user just gave to `url` (from an Open panel or a dropped folder).
    static func remember(_ url: URL) {
        guard isSandboxed,
              let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        let path = url.standardizedFileURL.path
        var all = bookmarks
        // A grant on a folder makes the grants inside it redundant.
        for granted in all.keys where covers(path, granted) { all[granted] = nil }
        all[path] = data
        bookmarks = all
        if url.startAccessingSecurityScopedResource() { started.insert(path) }
    }

    /// Whether the folder still needs the user's permission before it can be listed.
    static func needsPermission(_ folder: URL) -> Bool {
        guard isSandboxed else { return false }
        restore(for: folder)
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil
    }

    /// Asks for `folder` in an Open panel on `window`, once per run; `done(true)` once it may be listed.
    static func ask(for folder: URL, on window: NSWindow?, done: @escaping (Bool) -> Void) {
        let path = folder.standardizedFileURL.path
        guard !declined.contains(path) else { return done(false) }
        let panel = makePanel(at: folder,
                              message: L("To show the other pictures in “%@”, Pictty needs your permission once.", folder.lastPathComponent))
        let shortcuts = PanelShortcuts(panel: panel)
        panel.accessoryView = shortcuts.view
        panel.isAccessoryViewDisclosed = true
        present(panel, on: window) { response in
            // Home Folder and Whole Disk close this panel and open one on that place: the
            // sandboxed panel runs out of process and ignores a new directory while it is up.
            if let place = shortcuts.jump {
                return DispatchQueue.main.async {
                    allow(place, on: window) { done(!needsPermission(folder)) }
                }
            }
            guard response == .OK, let url = panel.url else {
                declined.insert(path)
                return done(false)
            }
            remember(url)
            done(!needsPermission(folder))
        }
    }

    /// The user's real home folder; inside the sandbox `NSHomeDirectory()` is the app's container.
    static var home: URL {
        guard let dir = getpwuid(getuid())?.pointee.pw_dir else { return URL(fileURLWithPath: NSHomeDirectory()) }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    static let disk = URL(fileURLWithPath: "/", isDirectory: true)

    /// Whether every folder below `url` is already allowed.
    static func isAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return bookmarks.keys.contains { covers($0, path) }
    }

    /// Settings' "Home Folder…" and "Whole Disk…", and the same buttons in the folder panel: the
    /// panel opens on that place, one click on Allow and Pictty never asks again inside it.
    static func allow(_ place: URL, on window: NSWindow? = nil, done: @escaping () -> Void = {}) {
        let panel = makePanel(at: place, message: place == disk
            ? L("Click Allow to let Pictty open pictures anywhere on this disk without asking again.")
            : L("Click Allow to let Pictty open pictures anywhere in your home folder without asking again."))
        present(panel, on: window) { response in
            if response == .OK, let url = panel.url { remember(url) }
            done()
        }
    }

    private static func makePanel(at folder: URL, message: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.prompt = L("Allow")
        panel.message = message
        return panel
    }

    private static func present(_ panel: NSOpenPanel, on window: NSWindow?,
                                then finish: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private static func covers(_ granted: String, _ path: String) -> Bool {
        path == granted || path.hasPrefix(granted.hasSuffix("/") ? granted : granted + "/")
    }
}

/// The panel's accessory: a hint and two buttons that move the panel to the home folder or the
/// whole disk, so one Allow covers every folder from then on.
@MainActor
private final class PanelShortcuts: NSObject {
    let view: NSView
    private weak var panel: NSOpenPanel?

    init(panel: NSOpenPanel) {
        self.panel = panel
        let hint = NSTextField(wrappingLabelWithString:
            L("Tip: allow your home folder or the whole disk, and Pictty never asks again."))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        let home = NSButton(title: L("Home Folder"), image: NSImage(systemSymbolName: "house", accessibilityDescription: nil)!,
                            target: nil, action: nil)
        let disk = NSButton(title: L("Whole Disk"), image: NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)!,
                            target: nil, action: nil)
        let buttons = NSStackView(views: [home, disk])
        buttons.spacing = 8
        let stack = NSStackView(views: [hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        hint.preferredMaxLayoutWidth = 420
        view = stack
        super.init()
        home.target = self; home.action = #selector(goHome)
        disk.target = self; disk.action = #selector(goDisk)
    }

    /// The place the user picked; the panel closes and FolderAccess opens a new one there.
    private(set) var jump: URL?

    @objc private func goHome() { go(FolderAccess.home) }
    @objc private func goDisk() { go(FolderAccess.disk) }

    private func go(_ place: URL) {
        jump = place
        panel?.cancel(nil)
    }
}
