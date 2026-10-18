import AppKit
import ShowHowCore
import SwiftUI

/// UI state for the floating panel that is not session state.
@MainActor
final class PanelState: ObservableObject {
    @Published var expanded = false
    @Published var focusToken = 0
    @Published var draft = ""
}

/// The floating chat panel: non-activating, so typing in it never pulls focus
/// from the app being learned. Collapses to a pill during a step.
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    let state = PanelState()
    private var panel: FloatingPanel?
    private var expandedByHover = false
    private var collapseTask: Task<Void, Never>?
    private var displayID: UInt32?
    /// Set while the user has the panel open from idle on purpose.
    private(set) var isPinnedOpen = false

    static let pillSize = CGSize(width: 440, height: 60)
    static let expandedSize = CGSize(width: 440, height: 520)
    private let margin: CGFloat = 16

    var isVisible: Bool { panel?.isVisible ?? false }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: Self.pillSize),
                                  styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityLabel("ShowHow panel")
        let root = FloatingPanelView(model: AppModel.shared, state: state, controller: self)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    // MARK: Showing

    /// Shows the panel on the walkthrough's display.
    func show(expanded: Bool) {
        hidePending()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let target = AppModel.shared.phase.isActive ? (activeDisplayID ?? DisplayManager.shared.mouseDisplayID) : DisplayManager.shared.mouseDisplayID
        if !panel.isVisible || target != displayID {
            displayID = target
            place(panel, expanded: expanded, on: target)
        } else if expanded != state.expanded {
            resize(panel, expanded: expanded)
        }
        state.expanded = expanded
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.reduceMotion ? 0 : DesignTokens.quick
            panel.animator().alphaValue = 1
        }
    }

    /// The summon shortcut: open with the cursor in the text field.
    func summon() {
        isPinnedOpen = !AppModel.shared.phase.isActive
        show(expanded: true)
        panel?.makeKey()
        state.focusToken += 1
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        isPinnedOpen = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.reduceMotion ? 0 : DesignTokens.standard
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func hidePending() {
        collapseTask?.cancel()
    }

    func setExpanded(_ expanded: Bool, byHover: Bool = false) {
        guard let panel, state.expanded != expanded else { return }
        expandedByHover = expanded && byHover
        resize(panel, expanded: expanded)
        state.expanded = expanded
        if expanded && !byHover { panel.makeKey() }
    }

    func hoverChanged(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            if !state.expanded { setExpanded(true, byHover: true) }
        } else if expandedByHover {
            collapseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, !Task.isCancelled, self.state.draft.isEmpty, AppModel.shared.pendingConfirmation == nil else { return }
                self.setExpanded(false)
            }
        }
    }

    /// Text typed into the panel.
    func submit() {
        let text = state.draft
        state.draft = ""
        SessionController.shared.send(text)
    }

    // MARK: Placement

    private var activeDisplayID: UInt32? {
        DisplayManager.shared.overlayModel.annotations.last?.displayID ?? DisplayManager.shared.focusedWindowDisplayID
    }

    private func screen(for id: UInt32?) -> NSScreen {
        id.flatMap { DisplayManager.shared.screen(for: $0) } ?? DisplayManager.shared.mouseScreen
    }

    private func place(_ panel: NSPanel, expanded: Bool, on id: UInt32?) {
        let screen = screen(for: id)
        let size = expanded ? Self.expandedSize : Self.pillSize
        let visible = screen.visibleFrame
        var origin: CGPoint
        if let id, let saved = savedTopLeft(for: id), visible.insetBy(dx: -1, dy: -1).contains(saved) {
            origin = CGPoint(x: saved.x, y: saved.y - size.height)
        } else {
            origin = CGPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        }
        origin = clamp(CGRect(origin: origin, size: size), to: visible).origin
        move(panel, to: CGRect(origin: origin, size: size), animate: false)
    }

    private var movingProgrammatically = false

    private func move(_ panel: NSPanel, to frame: CGRect, animate: Bool) {
        movingProgrammatically = true
        panel.setFrame(frame, display: true, animate: animate && !DesignTokens.reduceMotion)
        movingProgrammatically = false
    }

    private func resize(_ panel: NSPanel, expanded: Bool) {
        let size = expanded ? Self.expandedSize : Self.pillSize
        let visible = (panel.screen ?? DisplayManager.shared.mouseScreen).visibleFrame
        let old = panel.frame
        // Keep the edge nearest the screen edge fixed.
        let anchoredTop = old.midY > visible.midY
        var frame = CGRect(x: old.minX, y: anchoredTop ? old.maxY - size.height : old.minY, width: size.width, height: size.height)
        frame = clamp(frame, to: visible)
        move(panel, to: frame, animate: true)
    }

    private func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(max(f.minX, visible.minX + 4), visible.maxX - f.width - 4)
        f.origin.y = min(max(f.minY, visible.minY + 4), visible.maxY - f.height - 4)
        return f
    }

    /// Moves to the walkthrough's display, and to the nearest free corner if
    /// the panel would cover the element being highlighted.
    func avoid(_ footprint: CGRect, on id: UInt32) {
        guard let panel, panel.isVisible, let screen = DisplayManager.shared.screen(for: id) else { return }
        if displayID != id {
            displayID = id
            place(panel, expanded: state.expanded, on: id)
        }
        // Display-local top-left points to AppKit global points.
        let target = CGRect(x: screen.frame.minX + footprint.minX, y: screen.frame.maxY - footprint.maxY,
                            width: footprint.width, height: footprint.height)
        guard panel.frame.intersects(target) else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let corners = [
            CGPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin),
            CGPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin),
            CGPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin),
            CGPoint(x: visible.minX + margin, y: visible.minY + margin),
        ].map { CGRect(origin: $0, size: size) }
        let current = panel.frame.origin
        let free = corners.filter { !$0.intersects(target) }
            .min { hypot($0.minX - current.x, $0.minY - current.y) < hypot($1.minX - current.x, $1.minY - current.y) }
        guard let destination = free else { return }
        move(panel, to: destination, animate: true)
    }

    // MARK: Remembered positions (per display, top-left corner)

    private func savedTopLeft(for id: UInt32) -> CGPoint? {
        guard let values = UserDefaults.standard.array(forKey: "panelTopLeft.\(id)") as? [Double], values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    func windowDidMove(_ notification: Notification) {
        guard !movingProgrammatically, let panel, let id = panel.screen?.displayID else { return }
        UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.maxY)], forKey: "panelTopLeft.\(id)")
    }
}

/// A borderless panel that can take keyboard focus without activating the app.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Escape collapses the panel; it never stops the walkthrough.
        MainActor.assumeIsolated { SessionController.shared.panel.setExpanded(false) }
    }
}
