import AppKit
import MacHelperCore

enum BoardTool: String, CaseIterable, Identifiable {
    case pen, rect, ellipse, arrow, text, eraser, hand
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .eraser: return "eraser"
        case .hand: return "hand.raised"
        }
    }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .eraser: return "Eraser"
        case .hand: return "Pan"
        }
    }
}

/// The infinite canvas. World coordinates are y-down; the view is flipped to
/// match. Two-finger scroll pans, pinch zooms, drag draws.
final class BoardCanvasView: NSView {
    var document = BoardDocument() { didSet { needsDisplay = true } }
    var tool: BoardTool = .pen
    var color: BoardColor = .black
    var lineWidth: CGFloat = 3
    var imageFolder: URL?
    var onChange: ((BoardDocument) -> Void)?
    var onRequestText: ((CGPoint) -> Void)?

    private var draft: BoardItem?
    private var dragStart: CGPoint?
    private var lastPanPoint: CGPoint?
    private var spaceHeld = false
    private var undoStack: [BoardDocument] = []
    private var redoStack: [BoardDocument] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Whiteboard")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        var items = document.items
        if let draft { items.append(draft) }
        BoardRenderer.draw(items, camera: document.camera, viewSize: bounds.size, imageFolder: imageFolder)
    }

    // MARK: Editing

    func commit(_ change: (inout BoardDocument) -> Void) {
        undoStack.append(document)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        var doc = document
        change(&doc)
        doc.updatedAt = Date()
        document = doc
        onChange?(doc)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        onChange?(document)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        onChange?(document)
    }

    /// World rect currently on screen.
    var visibleWorldRect: CGRect {
        let cam = document.camera
        return CGRect(origin: cam.offset, size: CGSize(width: bounds.width / cam.zoom, height: bounds.height / cam.zoom))
    }

    func addText(_ string: String, at world: CGPoint) {
        guard !string.isEmpty else { return }
        commit { $0.items.append(BoardItem(shape: .text(origin: world, string: string, size: 24 / $0.camera.zoom), color: color, lineWidth: lineWidth)) }
    }

    // MARK: Mouse

    private func world(_ event: NSEvent) -> CGPoint {
        document.camera.toWorld(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = world(event)
        if tool == .hand || spaceHeld {
            lastPanPoint = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.set()
            return
        }
        dragStart = p
        let width = lineWidth / document.camera.zoom
        switch tool {
        case .pen: draft = BoardItem(shape: .stroke(points: [p]), color: color, lineWidth: width)
        case .rect: draft = BoardItem(shape: .rect(CGRect(origin: p, size: .zero)), color: color, lineWidth: width)
        case .ellipse: draft = BoardItem(shape: .ellipse(CGRect(origin: p, size: .zero)), color: color, lineWidth: width)
        case .arrow: draft = BoardItem(shape: .arrow(from: p, to: p), color: color, lineWidth: width)
        case .eraser: commit { _ = $0.erase(at: p, radius: 10 / $0.camera.zoom) }
        case .text: onRequestText?(p)
        case .hand: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let last = lastPanPoint {
            let now = convert(event.locationInWindow, from: nil)
            var doc = document
            doc.camera.pan(byView: CGSize(width: now.x - last.x, height: now.y - last.y))
            document = doc
            lastPanPoint = now
            return
        }
        let p = world(event)
        guard let start = dragStart else { return }
        switch tool {
        case .pen:
            if case .stroke(var points) = draft?.shape {
                points.append(p)
                draft?.shape = .stroke(points: points)
            }
        case .rect: draft?.shape = .rect(Self.rect(start, p, square: event.modifierFlags.contains(.shift)))
        case .ellipse: draft?.shape = .ellipse(Self.rect(start, p, square: event.modifierFlags.contains(.shift)))
        case .arrow: draft?.shape = .arrow(from: start, to: p)
        case .eraser:
            var doc = document
            if doc.erase(at: p, radius: 10 / doc.camera.zoom) { document = doc; onChange?(doc) }
        default: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if lastPanPoint != nil {
            lastPanPoint = nil
            onChange?(document)
            (tool == .hand ? NSCursor.openHand : NSCursor.arrow).set()
            return
        }
        if let item = draft, item.bounds.width + item.bounds.height > 1 || tool == .pen {
            commit { $0.items.append(item) }
        }
        draft = nil
        dragStart = nil
        needsDisplay = true
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
        var w = b.x - a.x, h = b.y - a.y
        if square {
            let side = max(abs(w), abs(h))
            w = w < 0 ? -side : side
            h = h < 0 ? -side : side
        }
        return CGRect(x: a.x, y: a.y, width: w, height: h).standardized
    }

    // MARK: Trackpad

    override func scrollWheel(with event: NSEvent) {
        var doc = document
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            let factor = 1 + (event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 300 : 30))
            doc.camera.zoom(by: factor, anchor: convert(event.locationInWindow, from: nil))
        } else {
            doc.camera.pan(byView: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
        document = doc
        if event.phase == .ended || event.momentumPhase == .ended { onChange?(doc) }
    }

    override func magnify(with event: NSEvent) {
        var doc = document
        doc.camera.zoom(by: 1 + event.magnification, anchor: convert(event.locationInWindow, from: nil))
        document = doc
        if event.phase == .ended { onChange?(doc) }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x31 { spaceHeld = true; NSCursor.openHand.set(); return }
        if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "z" { event.modifierFlags.contains(.shift) ? redo() : undo(); return }
        }
        if event.keyCode == 0x33 || event.keyCode == 0x75 { return } // no selection to delete
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 0x31 { spaceHeld = false; NSCursor.arrow.set(); return }
        super.keyUp(with: event)
    }

    // MARK: Dropping images

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let folder = imageFolder,
              let image = NSImage(pasteboard: sender.draggingPasteboard),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "image-\(UUID().uuidString.prefix(8)).png"
        guard (try? png.write(to: folder.appendingPathComponent(name))) != nil else { return false }
        let drop = document.camera.toWorld(convert(sender.draggingLocation, from: nil))
        let scale = min(1, 600 / max(image.size.width, image.size.height)) / document.camera.zoom
        let rect = CGRect(x: drop.x, y: drop.y, width: image.size.width * scale, height: image.size.height * scale)
        commit { $0.items.append(BoardItem(shape: .image(rect: rect, file: name))) }
        return true
    }
}
