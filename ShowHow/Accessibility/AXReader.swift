import AppKit
import ApplicationServices
import ShowHowCore

/// Reads visible controls (role, title, frame) from the Accessibility API so
/// Claude can point at real elements instead of guessing coordinates.
enum AXReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to System Settings.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Visible elements of the frontmost app (its menu bar and windows) plus the
    /// Dock and menu extras, limited to `displays`.
    static func visibleElements(displays: [DisplayInfo], limit: Int = 400) -> [UIElementSummary] {
        guard isTrusted else { return [] }
        var results: [UIElementSummary] = []
        var counter = 0

        func add(_ element: AXUIElement, depthLimit: Int) {
            var queue: [(AXUIElement, Int)] = [(element, 0)]
            var visited = 0
            while !queue.isEmpty, results.count < limit, visited < 4000 {
                let (el, depth) = queue.removeFirst()
                visited += 1
                let role = string(el, kAXRoleAttribute) ?? ""
                if let frame = frame(of: el), frame.width >= 2, frame.height >= 2,
                   let display = CoordinateMapper.display(containing: CGPoint(x: frame.midX, y: frame.midY), in: displays),
                   display.frame.intersects(frame), worthListing(role: role, element: el)
                {
                    counter += 1
                    let title = title(of: el, role: role)
                    let secure = role == "AXSecureTextField" || string(el, kAXSubroleAttribute) == "AXSecureTextField"
                    let value = secure ? nil : stringValue(el)
                    let enabled = bool(el, kAXEnabledAttribute) ?? true
                    results.append(UIElementSummary(id: "e\(counter)", role: role, title: title, value: value, frame: frame,
                                                    displayID: display.id, isSecure: secure, isEnabled: enabled))
                }
                guard depth < depthLimit else { continue }
                // Skip the contents of closed menus; they report frames off screen.
                if role == "AXMenu", bool(el, "AXVisible") == false { continue }
                for child in children(el) { queue.append((child, depth + 1)) }
            }
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            if let menuBar = attribute(axApp, kAXMenuBarAttribute) {
                add(menuBar as! AXUIElement, depthLimit: 1)
            }
            for window in windows(of: axApp) {
                add(window, depthLimit: 14)
            }
        }
        // The Dock is a common target ("open Numbers from the Dock").
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let axDock = AXUIElementCreateApplication(dock.processIdentifier)
            AXUIElementSetMessagingTimeout(axDock, 0.25)
            add(axDock, depthLimit: 3)
        }
        return results
    }

    /// Whether keyboard focus is in a password field (checked before typing in Do-it mode).
    static func focusedElementIsSecure() -> Bool {
        guard isTrusted, let el = focusedElement() else { return false }
        let role = string(el, kAXRoleAttribute)
        let subrole = string(el, kAXSubroleAttribute)
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard let value = attribute(system, kAXFocusedUIElementAttribute) else { return nil }
        return (value as! AXUIElement)
    }

    /// Frame of the frontmost app's focused window in global Quartz points.
    static func focusedWindowFrame() -> CGRect? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = attribute(axApp, kAXFocusedWindowAttribute) else { return nil }
        return frame(of: window as! AXUIElement)
    }

    /// The element at a global point, for describing what the user clicked.
    static func element(at point: CGPoint) -> (role: String, title: String)? {
        guard isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success, let element else { return nil }
        let role = string(element, kAXRoleAttribute) ?? "element"
        var title = title(of: element, role: role)
        if title.isEmpty, let parent = attribute(element, kAXParentAttribute) {
            title = self.title(of: parent as! AXUIElement, role: string(parent as! AXUIElement, kAXRoleAttribute) ?? "")
        }
        return (role, title)
    }

    // MARK: Helpers

    private static let listedRoles: Set<String> = Set(ElementListFormatter.interactiveRoles).union([
        "AXDockItem", "AXMenuExtra", "AXToolbar", "AXOutlineRow", "AXColorWell", "AXStepper", "AXDateField", "AXLevelIndicator",
    ])

    private static func worthListing(role: String, element: AXUIElement) -> Bool {
        guard listedRoles.contains(role) else { return false }
        if role == "AXStaticText" || role == "AXImage" || role == "AXCell" || role == "AXRow" {
            return !title(of: element, role: role).isEmpty
        }
        return true
    }

    private static func title(of el: AXUIElement, role: String) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = string(el, attr), !s.isEmpty { return s }
        }
        if role == "AXStaticText" || role == "AXHeading", let v = stringValue(el), !v.isEmpty { return v }
        if let s = string(el, kAXHelpAttribute), !s.isEmpty { return s }
        if let s = string(el, kAXPlaceholderValueAttribute), !s.isEmpty { return s }
        if let titleElement = attribute(el, kAXTitleUIElementAttribute) {
            let t = titleElement as! AXUIElement
            if let s = string(t, kAXValueAttribute) ?? string(t, kAXTitleAttribute), !s.isEmpty { return s }
        }
        return ""
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        attribute(el, name) as? String
    }

    private static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        (attribute(el, name) as? NSNumber)?.boolValue
    }

    private static func stringValue(_ el: AXUIElement) -> String? {
        guard let v = attribute(el, kAXValueAttribute) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        // Visible children first when the element offers them (tables, outlines).
        for attr in ["AXVisibleChildren", kAXChildrenAttribute] {
            if let arr = attribute(el, attr) as? [AXUIElement], !arr.isEmpty { return arr }
        }
        return []
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        guard let posValue = attribute(el, kAXPositionAttribute), let sizeValue = attribute(el, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
