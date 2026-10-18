import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Colors the board offers, shared with the agent's whiteboard_draw tool.
public enum BoardColor: String, Codable, CaseIterable, Sendable {
    case accent, red, green, blue, orange, purple, black

    /// sRGB components.
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .accent: return (0.33, 0.36, 0.95)
        case .red: return (0.92, 0.26, 0.24)
        case .green: return (0.20, 0.70, 0.36)
        case .blue: return (0.10, 0.52, 0.96)
        case .orange: return (0.98, 0.58, 0.10)
        case .purple: return (0.62, 0.32, 0.86)
        case .black: return (0.12, 0.12, 0.13)
        }
    }
}

public enum BoardShape: Codable, Equatable, Sendable {
    case stroke(points: [CGPoint])
    case rect(CGRect)
    case ellipse(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case text(origin: CGPoint, string: String, size: CGFloat)
    /// A PNG/JPEG stored next to the board file.
    case image(rect: CGRect, file: String)
}

/// One item on the board, in world coordinates.
public struct BoardItem: Codable, Equatable, Identifiable, Sendable {
    public enum Author: String, Codable, Sendable { case user, agent }

    public var id: UUID
    public var shape: BoardShape
    public var color: BoardColor
    public var lineWidth: CGFloat
    public var author: Author

    public init(id: UUID = UUID(), shape: BoardShape, color: BoardColor = .accent, lineWidth: CGFloat = 3, author: Author = .user) {
        self.id = id
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
        self.author = author
    }

    public var bounds: CGRect {
        switch shape {
        case .stroke(let points):
            return Self.bounding(points).insetBy(dx: -lineWidth, dy: -lineWidth)
        case .rect(let r), .ellipse(let r), .image(let r, _):
            return r.standardized
        case .arrow(let a, let b):
            return Self.bounding([a, b]).insetBy(dx: -12, dy: -12)
        case .text(let origin, let string, let size):
            let width = CGFloat(max(string.count, 1)) * size * 0.6
            return CGRect(x: origin.x, y: origin.y, width: width, height: size * 1.3)
        }
    }

    static func bounding(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Pan and zoom. view = (world - offset) * zoom.
public struct BoardCamera: Codable, Equatable, Sendable {
    public var offset: CGPoint
    public var zoom: CGFloat

    public static let minZoom: CGFloat = 0.1
    public static let maxZoom: CGFloat = 8

    public init(offset: CGPoint = .zero, zoom: CGFloat = 1) {
        self.offset = offset
        self.zoom = zoom
    }

    public func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) * zoom, y: (p.y - offset.y) * zoom)
    }

    public func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / zoom + offset.x, y: p.y / zoom + offset.y)
    }

    public func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom)
    }

    /// Pans by a view-space delta (a two-finger scroll).
    public mutating func pan(byView delta: CGSize) {
        offset.x -= delta.width / zoom
        offset.y -= delta.height / zoom
    }

    /// Zooms by `factor` keeping `anchor` (view space) fixed under the fingers.
    public mutating func zoom(by factor: CGFloat, anchor: CGPoint) {
        let worldAnchor = toWorld(anchor)
        zoom = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
        offset = CGPoint(x: worldAnchor.x - anchor.x / zoom, y: worldAnchor.y - anchor.y / zoom)
    }
}

/// The board document, saved per session.
public struct BoardDocument: Codable, Equatable, Sendable {
    public var items: [BoardItem]
    public var camera: BoardCamera
    public var updatedAt: Date

    public init(items: [BoardItem] = [], camera: BoardCamera = BoardCamera(), updatedAt: Date = Date()) {
        self.items = items
        self.camera = camera
        self.updatedAt = updatedAt
    }

    public var contentBounds: CGRect {
        items.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
    }

    /// Removes items under a world-space point (the eraser).
    @discardableResult
    public mutating func erase(at p: CGPoint, radius: CGFloat) -> Bool {
        let hit = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        let before = items.count
        items.removeAll { $0.bounds.intersects(hit) }
        return items.count != before
    }
}

/// Maps the agent's snapshot-pixel coordinates to world coordinates.
public struct BoardSnapshotFrame: Codable, Equatable, Sendable {
    /// World rect the snapshot covers.
    public var worldRect: CGRect
    public var imageSize: CGSize

    public init(worldRect: CGRect, imageSize: CGSize) {
        self.worldRect = worldRect
        self.imageSize = imageSize
    }

    /// The default frame before any snapshot: a 1600x1000 canvas centered on the current view.
    public static func `default`(camera: BoardCamera, viewSize: CGSize) -> BoardSnapshotFrame {
        let center = camera.toWorld(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        let size = CGSize(width: 1600 / camera.zoom, height: 1000 / camera.zoom)
        return BoardSnapshotFrame(worldRect: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                                  imageSize: CGSize(width: 1600, height: 1000))
    }

    public func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: worldRect.minX + p.x / imageSize.width * worldRect.width,
                y: worldRect.minY + p.y / imageSize.height * worldRect.height)
    }

    /// Converts the agent's draw request into board items.
    public func items(from specs: [WhiteboardItemSpec]) -> [BoardItem] {
        let scale = worldRect.width / max(imageSize.width, 1)
        return specs.compactMap { spec in
            let pts = spec.points.map(toWorld)
            let color = spec.color.flatMap(BoardColor.init(rawValue:)) ?? .accent
            let width = max(2, 3 * scale)
            switch spec.kind {
            case "stroke":
                guard pts.count >= 2 else { return nil }
                return BoardItem(shape: .stroke(points: pts), color: color, lineWidth: width, author: .agent)
            case "rect", "ellipse":
                guard pts.count >= 2 else { return nil }
                let r = BoardItem.bounding(pts)
                return BoardItem(shape: spec.kind == "rect" ? .rect(r) : .ellipse(r), color: color, lineWidth: width, author: .agent)
            case "arrow":
                guard let a = pts.first, let b = pts.last, pts.count >= 2 else { return nil }
                return BoardItem(shape: .arrow(from: a, to: b), color: color, lineWidth: width, author: .agent)
            case "text":
                guard let a = pts.first, let text = spec.text, !text.isEmpty else { return nil }
                return BoardItem(shape: .text(origin: a, string: text, size: 28 * scale), color: color, lineWidth: width, author: .agent)
            default:
                return nil
            }
        }
    }
}
