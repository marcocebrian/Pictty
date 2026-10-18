import CoreGraphics

/// Persistent zoom behaviour chosen by the user.
public enum ZoomMode: String, CaseIterable, Sendable {
    case actual, bestFit, fitWindow, remember
    /// Zoom, position and window frozen as they were when chosen, for every picture.
    case locked

    public var title: String {
        switch self {
        case .actual: "Actual Size"
        case .bestFit: "Best Fit"
        case .fitWindow: "Fit to Window"
        case .remember: "Remember Zoom"
        case .locked: "Lock Zoom & Window"
        }
    }

    public var symbol: String {
        switch self {
        case .actual: "1.square"
        case .bestFit: "arrow.up.left.and.arrow.down.right"
        case .fitWindow: "arrow.up.left.and.down.right.magnifyingglass"
        case .remember: "pin"
        case .locked: "lock"
        }
    }
}

public extension ZoomMode {
    /// The user's zoom and position carry over to the next picture.
    var keepsZoom: Bool { self == .remember || self == .locked }
}

/// Pure geometry. Scales are device pixels per image pixel (1 = pixel-exact real size).
public enum ZoomMath {
    public static let steps: [CGFloat] = [
        0.02, 0.03, 0.05, 0.0625, 0.083, 0.1, 0.125, 0.167, 0.25, 0.333, 0.5, 0.667, 0.75,
        1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32,
    ]

    public static func fit(_ image: CGSize, in view: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else { return 1 }
        return min(view.width / image.width, view.height / image.height)
    }

    /// `refFactor` scales non-fit modes so a second image in sync view matches the first one's size.
    /// In `.remember` and `.locked` modes the override is the kept zoom; it survives navigation.
    public static func scale(mode: ZoomMode, override: CGFloat?, fit: CGFloat, refFactor: CGFloat = 1) -> CGFloat {
        if let override { return override * refFactor }
        switch mode {
        case .actual: return refFactor
        case .fitWindow: return fit
        case .bestFit, .remember, .locked: return min(1, fit)
        }
    }

    public static func step(from s: CGFloat, up: Bool) -> CGFloat {
        up ? (steps.first { $0 > s * 1.01 } ?? steps[steps.count - 1])
           : (steps.last { $0 < s * 0.99 } ?? steps[0])
    }

    /// Normalized image-space center (0...1, y from top), clamped so the image never leaves
    /// empty space on an axis where it is larger than the view; centered where it is smaller.
    public static func clampCenter(_ c: CGPoint, display: CGSize, view: CGSize) -> CGPoint {
        func axis(_ v: CGFloat, _ d: CGFloat, _ w: CGFloat) -> CGFloat {
            guard d > w, d > 0 else { return 0.5 }
            let half = w / d / 2
            return min(max(v, half), 1 - half)
        }
        return CGPoint(x: axis(c.x, display.width, view.width), y: axis(c.y, display.height, view.height))
    }

    public static func isPannable(display: CGSize, view: CGSize) -> Bool {
        display.width > view.width + 0.5 || display.height > view.height + 0.5
    }

    /// Window content size that shows the image at real size when it fits, else scaled down
    /// to the visible screen area, never below `minimum`.
    public static func bestFitContentSize(imagePoints: CGSize, visible: CGSize, minimum: CGSize) -> CGSize {
        guard imagePoints.width > 0, imagePoints.height > 0 else { return minimum }
        let s = min(1, fit(imagePoints, in: visible))
        return CGSize(width: max(minimum.width, (imagePoints.width * s).rounded(.down)),
                      height: max(minimum.height, (imagePoints.height * s).rounded(.down)))
    }

    /// Window content size that shows the image at `scale`: each side as long as the picture,
    /// capped by the visible screen area (the rest pans), never below `minimum`.
    public static func bestFitContentSize(imagePoints: CGSize, scale: CGFloat, visible: CGSize, minimum: CGSize) -> CGSize {
        guard imagePoints.width > 0, imagePoints.height > 0, scale > 0 else { return minimum }
        return CGSize(width: max(minimum.width, min(visible.width, (imagePoints.width * scale).rounded(.down))),
                      height: max(minimum.height, min(visible.height, (imagePoints.height * scale).rounded(.down))))
    }
}
