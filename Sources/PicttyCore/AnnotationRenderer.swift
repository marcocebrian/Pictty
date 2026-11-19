import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Draws annotations: on screen over the picture, and into the pixels on Save. One drawing for both.
public enum AnnotationRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// `picture` with `items` drawn into it, the same size and colour space.
    public static func render(_ items: [Annotation], over picture: CGImage, crop: CGRect) -> CGImage? {
        let w = picture.width, h = picture.height
        let space = picture.colorSpace.flatMap { $0.model == .rgb && !CGColorSpaceUsesExtendedRange($0) ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let deep = picture.bitsPerComponent > 8
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(items, in: ctx, space: AnnotationSpace(crop: crop, size: CGSize(width: w, height: h)), base: picture)
        return ctx.makeImage()
    }

    /// Draws `items` into `ctx`, whose user space is the finished picture's pixels, top-left origin
    /// (y down). `base` is the picture under them at any resolution, for blur, censor and magnifier.
    public static func draw(_ items: [Annotation], in ctx: CGContext, space: AnnotationSpace, base: CGImage?) {
        let numbers = Annotation.stepNumbers(items)
        // Regions that change the picture go under the marks drawn on it: blur and censor, then the
        // spotlights (all at once, so one never darkens another's light), then the marks.
        let regions = items.filter { [.blur, .censor].contains($0.kind) }
        for item in regions {
            ctx.saveGState()
            draw(item, number: 0, in: ctx, space: space, base: base)
            ctx.restoreGState()
        }
        let spots = items.filter { $0.kind == .spotlight }
        if !spots.isEmpty {
            ctx.saveGState()
            drawSpotlights(spots, in: ctx, space: space)
            ctx.restoreGState()
        }
        // A magnifier shows the picture as hidden: never the pixels under a blur or censor.
        var loupeBase = base
        if let base, !regions.isEmpty, items.contains(where: { $0.kind == .magnifier }) {
            loupeBase = redacted(base, regions, crop: space.crop) ?? base
        }
        for item in items where ![.blur, .censor, .spotlight].contains(item.kind) {
            ctx.saveGState()
            draw(item, number: numbers[item.id] ?? 0, in: ctx, space: space, base: item.kind == .magnifier ? loupeBase : base)
            ctx.restoreGState()
        }
    }

    /// Everything dimmed but the spotlights' boxes, in one layer.
    private static func drawSpotlights(_ spots: [Annotation], in ctx: CGContext, space: AnnotationSpace) {
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(CGRect(origin: .zero, size: space.size).insetBy(dx: -space.size.width, dy: -space.size.height))
        ctx.setBlendMode(.clear)
        for item in spots {
            let r = item.box(in: space), k = min(r.width, r.height) * 0.12
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil))
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedRedaction: (base: CGImage, regions: [Annotation], crop: CGRect, image: CGImage)?

    /// `base` with the blur and censor regions applied, at its own resolution (the last one is kept:
    /// the screen redraws the same marks over the same picture many times).
    private static func redacted(_ base: CGImage, _ regions: [Annotation], crop: CGRect) -> CGImage? {
        cacheLock.lock()
        if let c = cachedRedaction, c.base === base, c.regions == regions, c.crop == crop { cacheLock.unlock(); return c.image }
        cacheLock.unlock()
        let w = base.width, h = base.height
        let space = base.colorSpace.flatMap { $0.model == .rgb && !CGColorSpaceUsesExtendedRange($0) ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let own = AnnotationSpace(crop: crop, size: CGSize(width: w, height: h))
        for item in regions {
            ctx.saveGState()
            draw(item, number: 0, in: ctx, space: own, base: base)
            ctx.restoreGState()
        }
        guard let image = ctx.makeImage() else { return nil }
        cacheLock.lock()
        cachedRedaction = (base, regions, crop, image)
        cacheLock.unlock()
        return image
    }

    private static func draw(_ item: Annotation, number: Int, in ctx: CGContext, space: AnnotationSpace, base: CGImage?) {
        let s = item.style, w = s.strokeWidth(space.minSide), colour = s.colour.cgColor
        func shadow() {
            guard s.shadow else { return }
            // Shadow offsets are in device space, whose y is up: negative is down on the picture.
            ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.5), blur: w * 2.2, color: CGColor(gray: 0, alpha: 0.45))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch item.kind {
        case .arrow:
            let pts = item.curve(in: space)
            guard let tip = pts.last, pts.count > 2 else { return }
            let back = pts[max(0, pts.count - 5)]
            let ang = atan2(tip.y - back.y, tip.x - back.x)
            let head = max(w * 4.2, 6), half = head * 0.55
            // The shaft stops inside the head, so its round cap never shows past the point.
            let shaftEnd = CGPoint(x: tip.x - cos(ang) * head * 0.6, y: tip.y - sin(ang) * head * 0.6)
            let path = CGMutablePath()
            path.move(to: space.pixel(item.a))
            path.addQuadCurve(to: shaftEnd, control: item.control(in: space))
            let headPath = CGMutablePath()
            headPath.move(to: tip)
            headPath.addLine(to: CGPoint(x: tip.x - cos(ang) * head + sin(ang) * half, y: tip.y - sin(ang) * head - cos(ang) * half))
            headPath.addLine(to: CGPoint(x: tip.x - cos(ang) * head - sin(ang) * half, y: tip.y - sin(ang) * head + cos(ang) * half))
            headPath.closeSubpath()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)  // one shadow for shaft and head together
            shadow()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setStrokeColor(colour); ctx.setLineWidth(w); ctx.addPath(path); ctx.strokePath()
            ctx.setFillColor(colour); ctx.addPath(headPath); ctx.fillPath()
            ctx.endTransparencyLayer()
            ctx.endTransparencyLayer()
        case .rectangle, .roundedRectangle, .ellipse:
            let r = item.box(in: space)
            let path: CGPath
            switch item.kind {
            case .ellipse: path = CGPath(ellipseIn: r, transform: nil)
            case .roundedRectangle:
                let k = min(r.width, r.height) * 0.18
                path = CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil)
            default: path = CGPath(rect: r, transform: nil)
            }
            shadow()
            if s.filled { ctx.setFillColor(colour); ctx.addPath(path); ctx.fillPath() }
            else { ctx.setStrokeColor(colour); ctx.setLineWidth(w); ctx.addPath(path); ctx.strokePath() }
        case .text:
            let frame = item.textFrame(in: space), size = s.textSize(space.minSide)
            shadow()
            ctx.setFillColor(colour)
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: size * 0.4, cornerHeight: size * 0.4, transform: nil))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let ink = s.colour.isLight ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1)
            let font = AnnotationStyle.font(size)
            for (i, line) in (item.text.isEmpty ? [" "] : item.text.components(separatedBy: "\n")).enumerated() {
                drawText(line, font: font, colour: ink, at: CGPoint(x: frame.minX + size * 0.4, y: frame.minY + size * 0.18 + CGFloat(i) * size * 1.25),
                         in: ctx)
            }
        case .step:
            let c = space.pixel(item.a), r = item.stepRadius(in: space)
            shadow()
            ctx.setFillColor(colour)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(max(1, r * 0.1))
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r).insetBy(dx: r * 0.05, dy: r * 0.05))
            let font = AnnotationStyle.font(r * 1.15)
            let label = "\(number)"
            let width = textWidth(label, font: font)
            let ink = s.colour.isLight ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1)
            drawText(label, font: font, colour: ink, at: CGPoint(x: c.x - width / 2, y: c.y - r * 0.72), in: ctx)
        case .highlighter:
            guard item.points.count > 1 else { return }
            let path = CGMutablePath()
            path.addLines(between: item.points.map(space.pixel))
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(CGColor(srgbRed: s.colour.r, green: s.colour.g, blue: s.colour.b, alpha: 0.4))
            ctx.setLineWidth(w * 3.2)
            ctx.addPath(path); ctx.strokePath()
        case .blur, .censor:
            let r = item.box(in: space).integral
            guard r.width >= 1, r.height >= 1 else { return }
            if item.kind == .censor && item.solid {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(r)
                return
            }
            // Only the part on the picture: a box running past its edge is not stretched to fill it.
            guard let base, let (patch, covered) = processed(base, region: r, space: space, pixelate: item.kind == .censor) else { return }
            drawImage(patch, in: covered, ctx: ctx)
        case .spotlight:
            drawSpotlights([item], in: ctx, space: space)
        case .magnifier:
            let m = item.magnifier(in: space)
            // The line from spot to loupe, edge to edge.
            let dx = m.loupe.x - m.spot.x, dy = m.loupe.y - m.spot.y, d = max(hypot(dx, dy), 1e-6)
            if d > m.r + m.R {
                ctx.setStrokeColor(colour); ctx.setLineWidth(w * 0.7)
                ctx.move(to: CGPoint(x: m.spot.x + dx / d * m.r, y: m.spot.y + dy / d * m.r))
                ctx.addLine(to: CGPoint(x: m.loupe.x - dx / d * m.R, y: m.loupe.y - dy / d * m.R))
                ctx.strokePath()
            }
            ctx.setStrokeColor(colour); ctx.setLineWidth(w * 0.7)
            ctx.strokeEllipse(in: CGRect(x: m.spot.x - m.r, y: m.spot.y - m.r, width: 2 * m.r, height: 2 * m.r))
            let loupe = CGRect(x: m.loupe.x - m.R, y: m.loupe.y - m.R, width: 2 * m.R, height: 2 * m.R)
            ctx.saveGState()
            shadow()
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillEllipse(in: loupe)
            ctx.restoreGState()
            if let base {
                let source = CGRect(x: m.spot.x - m.r, y: m.spot.y - m.r, width: 2 * m.r, height: 2 * m.r)
                if let (patch, got) = crop(base, region: source, space: space) {
                    // A spot past the picture's edge shows the part that is there, in its place.
                    let k = loupe.width / source.width
                    let into = CGRect(x: loupe.minX + (got.minX - source.minX) * k, y: loupe.minY + (got.minY - source.minY) * k,
                                      width: got.width * k, height: got.height * k)
                    ctx.saveGState()
                    ctx.addEllipse(in: loupe); ctx.clip()
                    ctx.interpolationQuality = .high
                    drawImage(patch, in: into, ctx: ctx)
                    ctx.restoreGState()
                }
            }
            ctx.setStrokeColor(colour); ctx.setLineWidth(w)
            ctx.strokeEllipse(in: loupe)
        }
    }

    // MARK: Pixels under a mark

    /// `region` (finished-picture pixels) of `base`, at base's own resolution, and the part of the
    /// region it covers (all of it, unless the region runs past the picture's edge).
    private static func crop(_ base: CGImage, region: CGRect, space: AnnotationSpace) -> (CGImage, CGRect)? {
        let kx = CGFloat(base.width) / space.size.width, ky = CGFloat(base.height) / space.size.height
        let r = CGRect(x: region.minX * kx, y: region.minY * ky, width: region.width * kx, height: region.height * ky)
            .integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard r.width >= 1, r.height >= 1, let image = base.cropping(to: r) else { return nil }
        return (image, CGRect(x: r.minX / kx, y: r.minY / ky, width: r.width / kx, height: r.height / ky))
    }

    /// The region blurred, or pixelated in blocks a quarter of its shorter side (a line of text
    /// becomes a row of blocks about four high, never one block lighter than the letters), and the
    /// part of the region it covers.
    private static func processed(_ base: CGImage, region: CGRect, space: AnnotationSpace, pixelate: Bool) -> (CGImage, CGRect)? {
        guard let (patch, covered) = crop(base, region: region, space: space) else { return nil }
        let image = CIImage(cgImage: patch)
        let extent = image.extent
        let out: CIImage
        if pixelate {
            let scale = max(4, min(extent.width, extent.height) / 4)
            out = image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(x: extent.minX, y: extent.minY),
            ]).cropped(to: extent)
        } else {
            out = image.clampedToExtent().applyingGaussianBlur(sigma: max(3, min(extent.width, extent.height) * 0.09)).cropped(to: extent)
        }
        // Deep pictures keep their depth: an 8-bit patch would band in a 16-bit file.
        guard let image = context.createCGImage(out, from: extent, format: patch.bitsPerComponent > 8 ? .RGBAh : .RGBA8,
                                                colorSpace: patch.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return (image, covered)
    }

    /// An image upright in a y-down context.
    private static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func textWidth(_ text: String, font: CTFont) -> CGFloat {
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
    }

    /// One line with its top-left at `point`, in a y-down context.
    private static func drawText(_ text: String, font: CTFont, colour: CGColor, at point: CGPoint, in ctx: CGContext) {
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: point.x, y: point.y + CTFontGetAscent(font))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
