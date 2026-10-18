import AppKit
import Combine

/// Live EDR headroom of the display the window is on. Headroom moves with brightness,
/// reference mode, other HDR content and Low Power Mode, so it is re-read on a slow timer
/// and on every screen-parameter change.
@MainActor
final class DisplayEnvironment: ObservableObject {
    @Published private(set) var headroom: Double = 1
    @Published private(set) var supportsEDR = false
    @Published private(set) var displayName = "Display"

    private weak var window: NSWindow?
    private var timer: Timer?

    init() {
        refresh(screen: NSScreen.main)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(screen: nil) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func attach(window: NSWindow) {
        self.window = window
        refresh(screen: window.screen)
    }

    @objc private func screenParametersChanged() { refresh(screen: nil) }

    private func refresh(screen: NSScreen?) {
        guard let target = screen ?? window?.screen ?? NSScreen.main else { return }
        let potential = Double(target.maximumPotentialExtendedDynamicRangeColorComponentValue)
        let current = Double(target.maximumExtendedDynamicRangeColorComponentValue)
        supportsEDR = potential > 1
        let next = max(1, min(current, potential))
        if abs(next - headroom) > 0.02 { headroom = next }
        if displayName != target.localizedName { displayName = target.localizedName }
    }

    var summary: String {
        guard supportsEDR else { return "SDR" }
        return L("EDR · %.1f× now", headroom)
    }
}
