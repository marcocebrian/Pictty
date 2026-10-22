// Updates for the download from noxdrop.com and GitHub, by Sparkle: the same Sparkle, feed layout
// and signing key as CaffeinateCat. The Mac App Store build has no Sparkle at all (the App Store
// updates it), so there `isAvailable` is false and the menu item and the Settings page are hidden.
//
// Pictty is not linked with Sparkle: launching never waits for it. The framework sits in the app's
// Frameworks folder and is loaded only when the updater starts, a while after launch once nothing
// else is going on, or at once if the user asks (Check for Updates…, or the Updates page). It is
// driven through the Objective-C runtime, by the names of its classes and properties.

import AppKit
import Combine

final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    #if PICTTY_SPARKLE
    let isAvailable = Bundle.main.privateFrameworksURL
        .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Sparkle.framework").path) } ?? false
    #else
    let isAvailable = false
    #endif

    /// Sparkle's own settings, mirrored so Settings can bind to them.
    @Published var automaticallyChecks = false {
        didSet { set(automaticallyChecks, "automaticallyChecksForUpdates") }
    }
    @Published var automaticallyDownloads = false {
        didSet { set(automaticallyDownloads, "automaticallyDownloadsUpdates") }
    }
    @Published private(set) var lastCheck: Date?
    @Published private(set) var canCheck = false

    /// SPUStandardUpdaterController, once loaded, and its SPUUpdater.
    private var controller: NSObject?
    private var updater: NSObject?
    private static let observed = ["automaticallyChecksForUpdates", "automaticallyDownloadsUpdates",
                                   "lastUpdateCheckDate", "canCheckForUpdates"]

    /// After launch: once the app has been up a while and the main thread is idle in its ordinary
    /// mode (not tracking a menu, a drag or a slider), so the updater never takes time from a picture.
    func startWhenCalm(after delay: TimeInterval = 10) {
        guard isAvailable else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            RunLoop.main.perform(inModes: [.default]) { self?.start() }
        }
    }

    /// Loads Sparkle and starts the updater (scheduled checks follow Sparkle's own settings).
    func start() {
        guard isAvailable, controller == nil,
              let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("Sparkle.framework"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = NSClassFromString("SPUStandardUpdaterController") as? NSObject.Type else { return }
        // -initWithStartingUpdater:updaterDelegate:userDriverDelegate:
        let alloc = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        let selector = NSSelectorFromString("initWithStartingUpdater:updaterDelegate:userDriverDelegate:")
        guard let alloc, alloc.responds(to: selector) else { return }
        typealias Init = @convention(c) (NSObject, Selector, Bool, AnyObject?, AnyObject?) -> NSObject?
        let initialise = unsafeBitCast(alloc.method(for: selector), to: Init.self)
        guard let made = initialise(alloc, selector, true, nil, self),
              let updater = made.value(forKey: "updater") as? NSObject else { return }
        controller = made
        self.updater = updater
        refresh()
        for key in Self.observed { updater.addObserver(self, forKeyPath: key, options: [], context: nil) }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        start()
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.perform(NSSelectorFromString("checkForUpdates:"), with: sender)
    }

    // MARK: Sparkle's user driver delegate (looked up by name)

    @objc var supportsGentleScheduledUpdateReminders: Bool { true }

    // MARK: Mirroring

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { self.refresh() }
    }

    private func refresh() {
        guard let updater else { return }
        let checks = updater.value(forKey: "automaticallyChecksForUpdates") as? Bool ?? false
        let downloads = updater.value(forKey: "automaticallyDownloadsUpdates") as? Bool ?? false
        if automaticallyChecks != checks { automaticallyChecks = checks }
        if automaticallyDownloads != downloads { automaticallyDownloads = downloads }
        lastCheck = updater.value(forKey: "lastUpdateCheckDate") as? Date
        canCheck = updater.value(forKey: "canCheckForUpdates") as? Bool ?? false
    }

    private func set(_ value: Bool, _ key: String) {
        guard let updater, updater.value(forKey: key) as? Bool != value else { return }
        updater.setValue(value, forKey: key)
    }
}
