import AppKit
import SwiftUI

@MainActor
final class MenuPanelState: ObservableObject {
    @Published var visible = false
    @Published var selection: Int?
    @Published var recentExpanded = false
}

/// The custom menu under the status item: a borderless panel with a vibrant
/// background, 12 pt corners and a soft shadow that fades and scales in, and
/// closes on a click outside or Escape.
@MainActor
final class MenuPanelController {
    let state = MenuPanelState()
    private var panel: MenuPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    static let width: CGFloat = 320

    var isOpen: Bool { panel?.isVisible ?? false }

    /// Returns false if the panel could not be shown, so the caller falls back
    /// to the native menu.
    @discardableResult
    func toggle(below anchor: CGRect) -> Bool {
        if isOpen { close(); return true }
        return open(below: anchor)
    }

    func open(below anchor: CGRect) -> Bool {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let hosting = panel.contentView as? NSHostingView<MenuPanelView> else { return false }
        state.selection = nil
        let size = hosting.fittingSize
        let height = max(size.height, 200)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }) ?? NSScreen.main else { return false }
        var x = anchor.minX
        x = min(max(x, screen.visibleFrame.minX + 6), screen.visibleFrame.maxX - Self.width - 6)
        let frame = CGRect(x: x, y: anchor.minY - height - 6, width: Self.width, height: height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        withAnimation(DesignTokens.animation(DesignTokens.quick)) { state.visible = true }
        installMonitors()
        return panel.isVisible
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        withAnimation(DesignTokens.animation(DesignTokens.quick)) { state.visible = false }
        let delay = DesignTokens.reduceMotion ? 0 : DesignTokens.quick
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !self.state.visible { panel.orderOut(nil) }
        }
    }

    /// Resizes to fit after the recent list expands or collapses.
    func refit() {
        guard let panel, let hosting = panel.contentView else { return }
        let height = max(hosting.fittingSize.height, 200)
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: !DesignTokens.reduceMotion)
    }

    private func makePanel() -> MenuPanel {
        let panel = MenuPanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.onEscape = { [weak self] in self?.close() }
        let view = MenuPanelView(model: AppModel.shared, state: state, controller: self)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        return panel
    }

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps (no permission needed for mouse events).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // Clicks in our own windows outside the panel.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let panel = self.panel, event.window !== panel { self.close() }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

final class MenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
