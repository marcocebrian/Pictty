import AppKit

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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(launchPath: launchPath)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
