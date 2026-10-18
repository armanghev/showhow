import AppKit
import ShowHowCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WhiteboardToolbarState: ObservableObject {
    @Published var tool: BoardTool = .pen { didSet { canvas?.tool = tool } }
    @Published var color: BoardColor = .black { didSet { canvas?.color = color } }
    weak var canvas: BoardCanvasView?
}

/// The whiteboard window: full screen on the display with the mouse, opened
/// from the menu bar or its shortcut, closed with Escape. While it is open the
/// walkthrough pauses and Claude's "screen" is the board.
@MainActor
final class WhiteboardController: NSObject, NSWindowDelegate {
    static let shared = WhiteboardController()

    private var window: WhiteboardWindow?
    private var canvas: BoardCanvasView?
    private let toolbar = WhiteboardToolbarState()
    /// The frame of the last snapshot sent to Claude, for mapping its coordinates.
    private var snapshotFrame: BoardSnapshotFrame?
    private var boardID = "scratch"
    private var saveTask: Task<Void, Never>?

    var isOpen: Bool { window?.isVisible ?? false }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else { window?.makeKeyAndOrderFront(nil); return }
        boardID = SessionController.shared.currentID ?? "scratch"
        let screen = DisplayManager.shared.mouseScreen
        let window = WhiteboardWindow(contentRect: screen.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false, screen: screen)
        window.title = "Whiteboard"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onEscape = { [weak self] in self?.close() }

        let canvas = BoardCanvasView(frame: CGRect(origin: .zero, size: screen.frame.size))
        canvas.autoresizingMask = [.width, .height]
        canvas.imageFolder = imagesFolder
        canvas.document = loadDocument()
        canvas.tool = toolbar.tool
        canvas.color = toolbar.color
        canvas.onChange = { [weak self] doc in self?.scheduleSave(doc) }
        canvas.onRequestText = { [weak self] point in self?.askForText(at: point) }
        toolbar.canvas = canvas

        let container = NSView(frame: canvas.frame)
        container.addSubview(canvas)
        let bar = NSHostingView(rootView: WhiteboardToolbar(state: toolbar, controller: self))
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])
        window.contentView = container
        self.window = window
        self.canvas = canvas
        snapshotFrame = nil

        NSApp.activate()
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        window.toggleFullScreen(nil)
        SessionController.shared.whiteboardOpened()
    }

    func close() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            // Close after the exit animation.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                window.close()
            }
        } else {
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let doc = canvas?.document { save(doc) }
        window = nil
        canvas = nil
        toolbar.canvas = nil
        SessionController.shared.whiteboardClosed()
    }

    // MARK: Agent access

    /// Renders what is on screen for Claude, and remembers the mapping.
    func snapshot() throws -> Screenshot {
        guard let canvas else { throw HandoffError("The whiteboard is closed.") }
        var world = canvas.visibleWorldRect
        if world.width < 1 || world.height < 1 {
            world = BoardSnapshotFrame.default(camera: canvas.document.camera, viewSize: canvas.bounds.size).worldRect
        }
        let size = ScreenshotSizing.targetSize(for: CGSize(width: world.width * canvas.document.camera.zoom * 2,
                                                         height: world.height * canvas.document.camera.zoom * 2),
                                               maxLongEdge: 1600)
        guard let rep = BoardRenderer.bitmap(items: canvas.document.items, worldRect: world, pixelSize: size, imageFolder: imagesFolder),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw HandoffError("Could not render the whiteboard.")
        }
        snapshotFrame = BoardSnapshotFrame(worldRect: world, imageSize: size)
        return Screenshot(data: data, mediaType: "image/jpeg",
                          mapping: ScreenshotMapping(displayID: 0, displayFrame: CGRect(origin: .zero, size: size), imageSize: size))
    }

    func draw(_ specs: [WhiteboardItemSpec], clear: Bool) throws {
        guard let canvas else { throw HandoffError("The whiteboard is closed.") }
        let frame = snapshotFrame ?? BoardSnapshotFrame.default(camera: canvas.document.camera, viewSize: canvas.bounds.size)
        let items = frame.items(from: specs)
        canvas.commit { doc in
            if clear { doc.items.removeAll { $0.author == .agent } }
            doc.items += items
        }
    }

    // MARK: Toolbar actions

    func undo() { canvas?.undo() }
    func redo() { canvas?.redo() }

    func clearBoard() {
        canvas?.commit { $0.items.removeAll() }
    }

    func export(pdf: Bool) {
        guard let canvas, let window else { return }
        let items = canvas.document.items
        var bounds = canvas.document.contentBounds
        if bounds.isNull || bounds.isEmpty { bounds = canvas.visibleWorldRect }
        bounds = bounds.insetBy(dx: -40, dy: -40)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : .png]
        panel.nameFieldStringValue = "Whiteboard.\(pdf ? "pdf" : "png")"
        panel.directoryURL = AppSettings.shared.documentsURL
        let folder = imagesFolder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                let data: Data?
                if pdf {
                    data = BoardRenderer.pdf(items: items, worldRect: bounds, imageFolder: folder)
                } else {
                    let scale = min(2, 4000 / max(bounds.width, bounds.height))
                    data = BoardRenderer.bitmap(items: items, worldRect: bounds, pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                                                imageFolder: folder)?.representation(using: .png, properties: [:])
                }
                try? data?.write(to: url)
            }
        }
    }

    private func askForText(at point: CGPoint) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Add text"
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Type here"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.canvas?.addText(field.stringValue, at: point) }
            }
        }
    }

    // MARK: Persistence (one board per session)

    private var boardFolder: URL { AppSettings.boardsDirectory.appendingPathComponent(boardID, isDirectory: true) }
    private var imagesFolder: URL { boardFolder.appendingPathComponent("images", isDirectory: true) }

    private func loadDocument() -> BoardDocument {
        let url = boardFolder.appendingPathComponent("board.json")
        guard let data = try? Data(contentsOf: url), let doc = try? JSONDecoder().decode(BoardDocument.self, from: data) else {
            return BoardDocument()
        }
        return doc
    }

    private func scheduleSave(_ doc: BoardDocument) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.save(doc)
        }
    }

    private func save(_ doc: BoardDocument) {
        do {
            try FileManager.default.createDirectory(at: boardFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(doc).write(to: boardFolder.appendingPathComponent("board.json"), options: .atomic)
        } catch {
            AppModel.shared.append(.system, "Could not save the whiteboard: \(error.localizedDescription)")
        }
    }
}

final class WhiteboardWindow: NSWindow {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x35 { onEscape?() } else { super.keyDown(with: event) }
    }
}

private struct WhiteboardToolbar: View {
    @ObservedObject var state: WhiteboardToolbarState
    let controller: WhiteboardController

    var body: some View {
        HStack(spacing: DesignTokens.space2) {
            ForEach(BoardTool.allCases) { tool in
                Button { state.tool = tool } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.radiusSmall).fill(state.tool == tool ? DesignTokens.accent.opacity(0.2) : .clear))
                }
                .buttonStyle(.borderless)
                .help(tool.title)
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(state.tool == tool ? .isSelected : [])
            }
            Divider().frame(height: 22)
            ForEach(BoardColor.allCases, id: \.self) { color in
                Button { state.color = color } label: {
                    Circle()
                        .fill(Color(nsColor: BoardRenderer.nsColor(color)))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.primary, lineWidth: state.color == color ? 2 : 0).padding(-3))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(color.rawValue.capitalized)
            }
            Divider().frame(height: 22)
            Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless).help("Undo (⌘Z)")
            Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.borderless).help("Redo (⇧⌘Z)")
            Button { controller.clearBoard() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Clear the board")
            Menu {
                Button("Export PNG…") { controller.export(pdf: false) }
                Button("Export PDF…") { controller.export(pdf: true) }
            } label: { Image(systemName: "square.and.arrow.up") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            Button("Done") { controller.close() }
                .buttonStyle(PrimaryPillStyle())
                .help("Close the whiteboard (Esc) and resume the walkthrough")
        }
        .padding(.horizontal, DesignTokens.space3)
        .padding(.vertical, DesignTokens.space2)
        .background(VisualEffectBackground(material: .hudWindow, cornerRadius: DesignTokens.radiusLarge))
    }
}
