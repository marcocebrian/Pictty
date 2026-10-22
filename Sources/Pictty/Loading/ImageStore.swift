import AppKit
import PicttyCore

/// Decoded-image cache with request de-duplication. Previews and full decodes are cached
/// separately: when the zoom outgrows the preview the full decode is fetched in addition,
/// and zooming back out falls back to the preview already in memory.
/// Decoding runs off the main thread; completions arrive on the main thread.
@MainActor
final class ImageStore {
    private let previews = NSCache<NSURL, DecodedImage>()
    private let fulls = NSCache<NSURL, DecodedImage>()
    /// Uncapped decodes of pictures larger than a GPU texture. One or two at most: they are huge.
    private let details = NSCache<NSURL, DecodedImage>()
    private var waiting: [String: [(DecodedImage?) -> Void]] = [:]
    private let urgent = DispatchQueue(label: "pictty.decode", qos: .userInitiated, attributes: .concurrent)
    private let background = DispatchQueue(label: "pictty.prefetch", qos: .utility, attributes: .concurrent)
    /// Preview resolution: the largest any attached display can show, and no more.
    let previewMaxPixel: Int

    init() {
        fulls.totalCostLimit = Int(min(ProcessInfo.processInfo.physicalMemory / 4, 4 << 30))
        previews.totalCostLimit = 768 << 20
        details.countLimit = 2
        details.totalCostLimit = Int(min(ProcessInfo.processInfo.physicalMemory / 3, 8 << 30))
        previewMaxPixel = EarlyDecode.screenMaxPixel
    }

    func cached(_ url: URL, full: Bool) -> DecodedImage? {
        if let f = fulls.object(forKey: url as NSURL) { return f }
        return full ? nil : previews.object(forKey: url as NSURL)
    }

    func isLoading(_ url: URL, full: Bool) -> Bool { waiting[(full ? "F" : "P") + url.path] != nil }

    func isDeveloping(_ url: URL) -> Bool { waiting["D" + url.path] != nil }

    func cachedDetail(_ url: URL) -> DecodedImage? { details.object(forKey: url as NSURL) }

    /// Every pixel of a picture larger than a GPU texture.
    func loadDetail(_ url: URL, _ done: @escaping (DecodedImage?) -> Void) {
        if let hit = cachedDetail(url) { done(hit); return }
        let key = "X" + url.path
        if waiting[key] != nil { waiting[key]!.append(done); return }
        waiting[key] = [done]
        urgent.async {
            let img = ImageDecoder.detail(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let img { self.details.setObject(img, forKey: url as NSURL, cost: img.cost) }
                    for done in self.waiting.removeValue(forKey: key) ?? [] { done(img) }
                }
            }
        }
    }

    /// A picture larger than a GPU texture, loaded whole behind its screen-sized decode: every
    /// pixel decoded once, and the GPU-sized full made from those pixels instead of from the file
    /// a second time. Holds the full and detail requests meanwhile, so a zoom that asks for either
    /// waits for this one instead of starting its own. `done` is called with each.
    func loadWhole(_ url: URL, _ done: @escaping (DecodedImage?) -> Void) {
        let fullKey = "F" + url.path, detailKey = "X" + url.path
        let haveFull = fulls.object(forKey: url as NSURL)
        guard waiting[fullKey] == nil, waiting[detailKey] == nil, haveFull == nil || cachedDetail(url) == nil else { return }
        waiting[fullKey] = [done]
        waiting[detailKey] = [done]
        urgent.async {
            timingMark("whole start")
            let detail = ImageDecoder.detail(url)
            timingMark("whole: every pixel")
            var full = haveFull
            if full == nil {
                full = detail.flatMap(ImageDecoder.reduced) ?? ImageDecoder.full(url)
                full?.matchDisplay(to: EarlyDecode.displaySpace)
                timingMark("whole: GPU-sized full")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let detail { self.details.setObject(detail, forKey: url as NSURL, cost: detail.cost) }
                    for done in self.waiting.removeValue(forKey: detailKey) ?? [] { done(detail) }
                    self.finish(fullKey, full)
                }
            }
        }
    }

    /// The cached screen-sized image is a RAW's embedded preview, not yet the real develop.
    func needsDevelop(_ url: URL) -> Bool {
        guard ImageFormats.isRaw(url), fulls.object(forKey: url as NSURL) == nil else { return false }
        return previews.object(forKey: url as NSURL)?.isEmbedded ?? true
    }

    /// The real RAW develop at screen size. It replaces the embedded preview in the cache.
    func develop(_ url: URL, urgent isUrgent: Bool = true, _ done: @escaping (DecodedImage?) -> Void) {
        guard needsDevelop(url) else { done(cached(url, full: false)); return }
        let key = "D" + url.path
        if waiting[key] != nil { waiting[key]!.append(done); return }
        waiting[key] = [done]
        let maxPixel = previewMaxPixel
        (isUrgent ? urgent : background).async {
            let img = ImageDecoder.developed(url, maxPixel: maxPixel)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(key, img) }
            }
        }
    }

    func load(_ url: URL, full: Bool, urgent isUrgent: Bool = true, _ done: @escaping (DecodedImage?) -> Void) {
        if let hit = cached(url, full: full) { done(hit); return }
        let key = (full ? "F" : "P") + url.path
        if waiting[key] != nil { waiting[key]!.append(done); return }
        waiting[key] = [done]
        // The picture Pictty was opened with may be decoded already, or nearly.
        if !full, EarlyDecode.shared.take(url, { [weak self] early in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let early { self.finish(key, early.with(url: url)) } else { self.decode(url, full: false, key: key, urgent: isUrgent) }
            }
        }) { return }
        decode(url, full: full, key: key, urgent: isUrgent)
    }

    private func decode(_ url: URL, full: Bool, key: String, urgent isUrgent: Bool) {
        let maxPixel = previewMaxPixel
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        (isUrgent ? urgent : background).async {
            timingMark("decode start")
            let img = full ? ImageDecoder.full(url) : ImageDecoder.preview(url, maxPixel: maxPixel, backing: backing)
            // Matched to the screen here, not on the main thread while committing the frame, where
            // Core Animation would otherwise convert it: a third of a second for 150 megapixels.
            img?.matchDisplay(to: EarlyDecode.displaySpace)
            timingMark("decode done")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(key, img) }
            }
        }
    }

    private func finish(_ key: String, _ img: DecodedImage?) {
        if let img { (img.isFull ? fulls : previews).setObject(img, forKey: img.url as NSURL, cost: img.cost) }
        for done in waiting.removeValue(forKey: key) ?? [] { done(img) }
    }

    /// Memory pressure: keep only what is on screen. Everything else is decoded again on demand.
    func trim(keeping onScreen: Set<URL>) {
        let kept = onScreen.flatMap { url in
            [previews.object(forKey: url as NSURL), fulls.object(forKey: url as NSURL)].compactMap { $0 }
        }
        previews.removeAllObjects()
        fulls.removeAllObjects()
        details.removeAllObjects()
        for d in kept { (d.isFull ? fulls : previews).setObject(d, forKey: d.url as NSURL, cost: d.cost) }
    }

    func forget(_ url: URL) {
        previews.removeObject(forKey: url as NSURL)
        fulls.removeObject(forKey: url as NSURL)
        details.removeObject(forKey: url as NSURL)
    }
}

/// Filmstrip thumbnails, at most four decodes at a time. Sized for a retina cell at the
/// widest panorama the strip draws.
final class ThumbStore: @unchecked Sendable {
    static let shared = ThumbStore()
    private let cache = NSCache<NSURL, CGImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()

    init() {
        cache.countLimit = 4000
        // By memory, not count: a 2000-picture folder browsed end to end would otherwise keep
        // about a gigabyte of thumbnails.
        cache.totalCostLimit = 256 << 20
        // Nothing decodes for the filmstrip until the picture itself is on screen.
        queue.isSuspended = true
    }

    /// The picture is up: thumbnails may decode now.
    func release() { if queue.isSuspended { queue.isSuspended = false } }

    func cached(_ url: URL) -> CGImage? { cache.object(forKey: url as NSURL) }

    func thumb(_ url: URL) async -> CGImage? {
        if let c = cached(url) { return c }
        return await withCheckedContinuation { cont in
            queue.addOperation {
                let img = ImageDecoder.thumbnail(url, maxPixel: 400)
                if let img { self.cache.setObject(img, forKey: url as NSURL, cost: img.bytesPerRow * img.height) }
                cont.resume(returning: img)
            }
        }
    }

    func removeAll() { cache.removeAllObjects() }

    func forget(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
}
