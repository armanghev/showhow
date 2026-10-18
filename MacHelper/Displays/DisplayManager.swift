import AppKit
import CoreGraphics
import MacHelperCore

/// Keeps the list of displays with their ids, re-reads it when the
/// configuration changes, and owns one overlay window per display.
@MainActor
final class DisplayManager {
    static let shared = DisplayManager()

    private(set) var displays: [DisplayInfo] = []
    private(set) var overlays: [UInt32: OverlayWindowController] = [:]
    let overlayModel = OverlayModel()
    var onChange: (() -> Void)?

    private init() {
        reload()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// The main display's height, needed to convert between Quartz and AppKit coordinates.
    var mainDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    func reload() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return DisplayInfo(id: id, name: screen.localizedName, frame: CGDisplayBounds(id), scale: screen.backingScaleFactor, isMain: CGDisplayIsMain(id) != 0)
        }
        let ids = Set(displays.map(\.id))
        for (id, overlay) in overlays where !ids.contains(id) {
            overlay.close()
            overlays[id] = nil
        }
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            if let existing = overlays[id] {
                existing.update(screen: screen)
            } else {
                overlays[id] = OverlayWindowController(displayID: id, screen: screen, model: overlayModel)
            }
        }
        onChange?()
    }

    func screen(for id: UInt32) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    func display(for id: UInt32) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    /// The display under the mouse.
    var mouseDisplayID: UInt32? {
        let mouse = CoordinateMapper.globalPoint(fromAppKit: NSEvent.mouseLocation, mainDisplayHeight: mainDisplayHeight)
        return CoordinateMapper.display(containing: mouse, in: displays)?.id
    }

    var mouseScreen: NSScreen {
        mouseDisplayID.flatMap(screen(for:)) ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    /// The display holding the frontmost app's focused window, if Accessibility allows reading it.
    var focusedWindowDisplayID: UInt32? {
        guard let frame = AXReader.focusedWindowFrame() else { return nil }
        return CoordinateMapper.display(containing: CGPoint(x: frame.midX, y: frame.midY), in: displays)?.id
    }

    /// Window numbers of every overlay, so captures can exclude them.
    var overlayWindowNumbers: [Int] {
        overlays.values.compactMap { $0.window?.windowNumber }
    }

    func showOverlays() {
        overlays.values.forEach { $0.showWindow(nil) }
    }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
