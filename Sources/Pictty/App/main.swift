import AppKit

/// When the process started, for `PICTTY_TIMING=1`: how long until the first picture is on screen.
let launchStart = CFAbsoluteTimeGetCurrent()
let timingEnabled = ProcessInfo.processInfo.environment["PICTTY_TIMING"] == "1"

/// `PICTTY_TIMING=1`: a line on stderr for each step of a launch, in ms since the process began.
func timingMark(_ what: String) {
    guard timingEnabled else { return }
    FileHandle.standardError.write(Data(String(format: "TIMING %6.1f ms  %@\n", (CFAbsoluteTimeGetCurrent() - launchStart) * 1000, what).utf8))
}

// `Pictty ~/Pictures` opens a folder or file from the command line. Options such as
// `-AppleLanguages (en)` take the word after them, which is not a path.
let launchPath: String? = {
    var args = CommandLine.arguments.dropFirst()[...]
    guard !args.contains("--dmg-background") else { return nil }
    while let arg = args.popFirst() {
        if arg.hasPrefix("-") { _ = args.popFirst(); continue }
        return (arg as NSString).expandingTildeInPath
    }
    return nil
}()

// `Pictty --dmg-background <dir>` draws the installer window's background and quits.
if let i = CommandLine.arguments.firstIndex(of: "--dmg-background"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        do { try DMGBackground.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) } catch { exit(1) }
    }
    exit(0)
}

/// `PICTTY_TIMING=1`: every main run-loop pass longer than 4 ms, to see what holds the picture up.
func watchRunLoop() {
    guard timingEnabled else { return }
    var began = CFAbsoluteTimeGetCurrent()
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, activity in
        let now = CFAbsoluteTimeGetCurrent()
        if activity == .afterWaiting || activity == .entry { began = now }
        if activity == .beforeWaiting || activity == .exit {
            if now - began > 0.004 { timingMark(String(format: "  main thread busy %.1f ms", (now - began) * 1000)) }
            began = now
        }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
}

// The picture asked for on the command line starts decoding now, while AppKit starts up.
if let launchPath { EarlyDecode.shared.start(URL(fileURLWithPath: launchPath)) }

MainActor.assumeIsolated {
    timingMark("main")
    watchRunLoop()
    let app = NSApplication.shared
    timingMark("NSApplication")
    let delegate = AppDelegate(launchPath: launchPath)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
