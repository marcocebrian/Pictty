import CoreGraphics
import Foundation
import PicttyCore

/// The picture Pictty was launched to show, decoded from the first instant: from `main()` for a
/// path on the command line, from the moment Finder hands it over otherwise. AppKit takes most of
/// a tenth of a second to start and the window as long again to build; the decode runs alongside
/// both, so the picture is ready before the window's first frame and is in it.
final class EarlyDecode: @unchecked Sendable {
    static let shared = EarlyDecode()

    private let lock = NSLock()
    private var url: URL?
    private var done = false
    private var result: DecodedImage?
    private var waiting: [(DecodedImage?) -> Void] = []

    /// The longest side the screens can show, in pixels: the size previews are decoded at. Read
    /// from Core Graphics, which answers before AppKit is up.
    static let screenMaxPixel: Int = {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetActiveDisplayList(count, &ids, &count)
        let sides = ids.prefix(Int(count)).compactMap { id -> Int? in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            return max(mode.pixelWidth, mode.pixelHeight)
        }
        return sides.max() ?? 3840
    }()

    /// The main display's colour space, which previews are matched to for the screen.
    static var displaySpace: CGColorSpace? { CGDisplayCopyColorSpace(CGMainDisplayID()) }

    /// Starts decoding `url` if it is a picture file. Only the first call counts.
    func start(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard ImageFormats.isSupported(url), !ImageFormats.isVector(url) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        lock.lock()
        guard self.url == nil else { lock.unlock(); return }
        self.url = url
        lock.unlock()
        timingMark("early decode start")
        DispatchQueue.global(qos: .userInteractive).async {
            let image = ImageDecoder.preview(url, maxPixel: Self.screenMaxPixel)
            timingMark("early decode done")
            image?.matchDisplay(to: Self.displaySpace)
            timingMark("early decode matched to the display")
            self.lock.lock()
            self.result = image
            self.done = true
            let waiting = self.waiting
            self.waiting.removeAll()
            self.lock.unlock()
            if !waiting.isEmpty {
                DispatchQueue.main.async { for w in waiting { w(image) } }
            }
        }
    }

    /// Hands over the early decode of `url`, now if it is ready (on the caller's thread) or on the
    /// main thread when it is. False if this is not the picture being decoded early; it is given
    /// out once.
    func take(_ url: URL, _ handler: @escaping (DecodedImage?) -> Void) -> Bool {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        lock.lock()
        guard self.url == url else { lock.unlock(); return false }
        self.url = URL(fileURLWithPath: "/dev/null/taken")
        if done {
            let result = result
            self.result = nil
            lock.unlock()
            handler(result)
        } else {
            waiting.append(handler)
            lock.unlock()
        }
        return true
    }
}
