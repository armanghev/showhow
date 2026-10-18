import Foundation

/// One physical display.
///
/// `frame` is in global Quartz coordinates: points, origin at the top-left of the
/// main display, y growing downward (what `CGDisplayBounds`, CGEvent and the
/// Accessibility API use). AppKit's `NSScreen.frame` is bottom-left based; use
/// `CoordinateMapper.appKitFrame(of:mainDisplayHeight:)` to convert.
public struct DisplayInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: UInt32
    public var name: String
    public var frame: CGRect
    public var scale: CGFloat
    public var isMain: Bool

    public init(id: UInt32, name: String, frame: CGRect, scale: CGFloat, isMain: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.scale = scale
        self.isMain = isMain
    }

    public var pixelSize: CGSize { CGSize(width: frame.width * scale, height: frame.height * scale) }
}

/// How a screenshot relates to the display it was taken of.
///
/// Claude's coordinates are in the screenshot's pixel space. The screenshot is
/// usually downscaled from the display's native pixels, so `pointsPerPixel`
/// converts back to display points.
public struct ScreenshotMapping: Codable, Equatable, Sendable {
    public var displayID: UInt32
    /// The display's frame in global Quartz points at capture time.
    public var displayFrame: CGRect
    /// Size of the image sent to Claude, in pixels.
    public var imageSize: CGSize
    /// Optional crop (display-local points) when the capture was a region or window.
    public var sourceRect: CGRect?

    public init(displayID: UInt32, displayFrame: CGRect, imageSize: CGSize, sourceRect: CGRect? = nil) {
        self.displayID = displayID
        self.displayFrame = displayFrame
        self.imageSize = imageSize
        self.sourceRect = sourceRect
    }

    /// The display-local area the image covers.
    public var coveredRect: CGRect {
        sourceRect ?? CGRect(origin: .zero, size: displayFrame.size)
    }

    public var pointsPerPixelX: CGFloat { coveredRect.width / max(imageSize.width, 1) }
    public var pointsPerPixelY: CGFloat { coveredRect.height / max(imageSize.height, 1) }
}

/// Every conversion between screenshot pixels, display points, global Quartz
/// points and AppKit points goes through here.
public enum CoordinateMapper {
    /// Screenshot pixel -> display-local point (top-left origin).
    public static func displayPoint(fromPixel p: CGPoint, mapping: ScreenshotMapping) -> CGPoint {
        let covered = mapping.coveredRect
        return CGPoint(x: covered.minX + p.x * mapping.pointsPerPixelX,
                       y: covered.minY + p.y * mapping.pointsPerPixelY)
    }

    /// Screenshot pixel -> global Quartz point (for CGEvent).
    public static func globalPoint(fromPixel p: CGPoint, mapping: ScreenshotMapping) -> CGPoint {
        let local = displayPoint(fromPixel: p, mapping: mapping)
        return CGPoint(x: mapping.displayFrame.minX + local.x, y: mapping.displayFrame.minY + local.y)
    }

    /// Screenshot pixel rect -> display-local rect.
    public static func displayRect(fromPixel r: CGRect, mapping: ScreenshotMapping) -> CGRect {
        let origin = displayPoint(fromPixel: r.origin, mapping: mapping)
        return CGRect(x: origin.x, y: origin.y,
                      width: r.width * mapping.pointsPerPixelX, height: r.height * mapping.pointsPerPixelY)
    }

    /// Global Quartz point -> screenshot pixel (for AX frames and the cursor).
    public static func pixel(fromGlobal p: CGPoint, mapping: ScreenshotMapping) -> CGPoint {
        let covered = mapping.coveredRect
        let localX = p.x - mapping.displayFrame.minX - covered.minX
        let localY = p.y - mapping.displayFrame.minY - covered.minY
        return CGPoint(x: localX / mapping.pointsPerPixelX, y: localY / mapping.pointsPerPixelY)
    }

    /// Global Quartz rect -> screenshot pixel rect.
    public static func pixelRect(fromGlobal r: CGRect, mapping: ScreenshotMapping) -> CGRect {
        let origin = pixel(fromGlobal: r.origin, mapping: mapping)
        return CGRect(x: origin.x, y: origin.y,
                      width: r.width / mapping.pointsPerPixelX, height: r.height / mapping.pointsPerPixelY)
    }

    /// Global Quartz rect -> display-local rect on a given display.
    public static func displayRect(fromGlobal r: CGRect, display: CGRect) -> CGRect {
        r.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    /// Display-local point -> global Quartz point.
    public static func globalPoint(fromDisplayPoint p: CGPoint, display: CGRect) -> CGPoint {
        CGPoint(x: display.minX + p.x, y: display.minY + p.y)
    }

    /// Quartz (top-left, y down) <-> AppKit (bottom-left of main display, y up).
    /// The transform is its own inverse for points.
    public static func appKitPoint(fromGlobal p: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: mainDisplayHeight - p.y)
    }

    public static func globalPoint(fromAppKit p: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: mainDisplayHeight - p.y)
    }

    public static func appKitFrame(of quartzRect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: quartzRect.minX, y: mainDisplayHeight - quartzRect.maxY, width: quartzRect.width, height: quartzRect.height)
    }

    public static func quartzFrame(ofAppKit rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The display containing a global Quartz point, or the nearest one.
    public static func display(containing p: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let hit = displays.first(where: { $0.frame.contains(p) }) { return hit }
        return displays.min(by: { distance(p, $0.frame) < distance(p, $1.frame) })
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Picks the size to capture screenshots at so they fit the model's image
/// limits: at most `maxLongEdge` pixels on the long side and at most
/// `maxVisualTokens` visual tokens (ceil(w/28) * ceil(h/28)).
public enum ScreenshotSizing {
    /// The current models accept 2576 px / 4784 visual tokens. The app defaults
    /// to a smaller long edge to keep each step cheap; zoom covers fine detail.
    public static let defaultLongEdge: CGFloat = 1568
    public static let modelLongEdgeLimit: CGFloat = 2576
    public static let modelVisualTokenLimit = 4784

    public static func visualTokens(_ size: CGSize) -> Int {
        Int((size.width / 28).rounded(.up)) * Int((size.height / 28).rounded(.up))
    }

    public static func targetSize(for source: CGSize, maxLongEdge: CGFloat = defaultLongEdge, maxVisualTokens: Int = modelVisualTokenLimit) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        let edge = min(maxLongEdge, modelLongEdgeLimit)
        var scale = min(1, edge / max(source.width, source.height))
        var size = CGSize(width: (source.width * scale).rounded(.down), height: (source.height * scale).rounded(.down))
        while visualTokens(size) > maxVisualTokens, scale > 0.05 {
            scale *= 0.97
            size = CGSize(width: (source.width * scale).rounded(.down), height: (source.height * scale).rounded(.down))
        }
        return CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }
}
