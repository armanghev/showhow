import AppKit
import ShowHowCore

/// Draws board items with AppKit into the current graphics context, which must
/// be flipped (y grows downward, like the board's world coordinates).
enum BoardRenderer {
    static let paper = NSColor(srgbRed: 0.995, green: 0.993, blue: 0.985, alpha: 1)

    static func nsColor(_ color: BoardColor) -> NSColor {
        if color == .accent { return DesignTokens.accentNS }
        let c = color.rgb
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// Draws the paper, a dot grid and every item as seen through `camera`.
    static func draw(_ items: [BoardItem], camera: BoardCamera, viewSize: CGSize, imageFolder: URL?, grid: Bool = true) {
        paper.setFill()
        CGRect(origin: .zero, size: viewSize).fill()
        if grid { drawGrid(camera: camera, viewSize: viewSize) }
        let visible = CGRect(origin: camera.offset, size: CGSize(width: viewSize.width / camera.zoom, height: viewSize.height / camera.zoom))
        for item in items where item.bounds.insetBy(dx: -20, dy: -20).intersects(visible) {
            draw(item, camera: camera, imageFolder: imageFolder)
        }
    }

    static func drawGrid(camera: BoardCamera, viewSize: CGSize) {
        var spacing: CGFloat = 40
        while spacing * camera.zoom < 16 { spacing *= 2 }
        let step = spacing * camera.zoom
        let startX = -((camera.offset.x * camera.zoom).truncatingRemainder(dividingBy: step))
        let startY = -((camera.offset.y * camera.zoom).truncatingRemainder(dividingBy: step))
        NSColor(white: 0.82, alpha: 1).setFill()
        var x = startX
        while x < viewSize.width {
            var y = startY
            while y < viewSize.height {
                CGRect(x: x - 1, y: y - 1, width: 2, height: 2).fill()
                y += step
            }
            x += step
        }
    }

    static func draw(_ item: BoardItem, camera: BoardCamera, imageFolder: URL?) {
        let color = nsColor(item.color)
        color.setStroke()
        let width = max(1, item.lineWidth * camera.zoom)
        switch item.shape {
        case .stroke(let points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: camera.toView(first))
            if points.count == 1 {
                path.line(to: camera.toView(first))
            }
            // Smooth with midpoint quadratic curves.
            var previous = camera.toView(first)
            for point in points.dropFirst() {
                let p = camera.toView(point)
                let mid = CGPoint(x: (previous.x + p.x) / 2, y: (previous.y + p.y) / 2)
                path.curve(to: mid, controlPoint1: previous, controlPoint2: previous)
                previous = p
            }
            path.line(to: previous)
            path.stroke()
        case .rect(let r):
            let path = NSBezierPath(roundedRect: camera.toView(r), xRadius: 6 * camera.zoom, yRadius: 6 * camera.zoom)
            path.lineWidth = width
            path.stroke()
        case .ellipse(let r):
            let path = NSBezierPath(ovalIn: camera.toView(r))
            path.lineWidth = width
            path.stroke()
        case .arrow(let a, let b):
            let from = camera.toView(a), to = camera.toView(b)
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: from)
            path.line(to: to)
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = max(12, width * 4)
            path.move(to: to)
            path.line(to: CGPoint(x: to.x - head * cos(angle - .pi / 7), y: to.y - head * sin(angle - .pi / 7)))
            path.move(to: to)
            path.line(to: CGPoint(x: to.x - head * cos(angle + .pi / 7), y: to.y - head * sin(angle + .pi / 7)))
            path.stroke()
        case .text(let origin, let string, let size):
            let font = NSFont.systemFont(ofSize: max(4, size * camera.zoom), weight: .medium)
            (string as NSString).draw(at: camera.toView(origin), withAttributes: [.font: font, .foregroundColor: color])
        case .image(let rect, let file):
            guard let folder = imageFolder, let image = NSImage(contentsOf: folder.appendingPathComponent(file)) else { return }
            image.draw(in: camera.toView(rect), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// Renders a world rect into a bitmap of `pixelSize`, for snapshots and PNG export.
    static func bitmap(items: [BoardItem], worldRect: CGRect, pixelSize: CGSize, imageFolder: URL?) -> NSBitmapImageRep? {
        let w = Int(pixelSize.width.rounded()), h = Int(pixelSize.height.rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = base.cgContext
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let camera = BoardCamera(offset: worldRect.origin, zoom: pixelSize.width / max(worldRect.width, 1))
        draw(items, camera: camera, viewSize: pixelSize, imageFolder: imageFolder, grid: false)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A one-page PDF of a world rect.
    static func pdf(items: [BoardItem], worldRect: CGRect, imageFolder: URL?) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: worldRect.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let cg = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        cg.beginPDFPage(nil)
        cg.translateBy(x: 0, y: box.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw(items, camera: BoardCamera(offset: worldRect.origin, zoom: 1), viewSize: box.size, imageFolder: imageFolder, grid: false)
        NSGraphicsContext.restoreGraphicsState()
        cg.endPDFPage()
        cg.closePDF()
        return data as Data
    }
}
