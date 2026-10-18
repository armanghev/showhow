import Foundation

/// What the overlay can draw.
public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case highlight
    case circle
    case arrow
    case callout
    case typeBubble = "type_bubble"
}

/// An annotation resolved to display-local points (top-left origin), ready for
/// the overlay window on `displayID` to draw.
public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    public var displayID: UInt32
    public var label: String
    /// Box for highlight/circle/callout/type bubble targets.
    public var rect: CGRect?
    /// Point the annotation points at (arrow head, circle center, callout anchor).
    public var point: CGPoint?
    /// Arrow tail.
    public var fromPoint: CGPoint?
    public var textToType: String?
    /// The element id the model referred to, kept for the session log.
    public var elementID: String?

    public init(id: UUID = UUID(), kind: AnnotationKind, displayID: UInt32, label: String, rect: CGRect? = nil,
                point: CGPoint? = nil, fromPoint: CGPoint? = nil, textToType: String? = nil, elementID: String? = nil)
    {
        self.id = id
        self.kind = kind
        self.displayID = displayID
        self.label = label
        self.rect = rect
        self.point = point
        self.fromPoint = fromPoint
        self.textToType = textToType
        self.elementID = elementID
    }

    /// The area the annotation occupies, used to keep the floating panel out of the way.
    public var footprint: CGRect {
        var r = rect ?? .null
        if let p = point { r = r.union(CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60)) }
        if let p = fromPoint { r = r.union(CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)) }
        return r.isNull ? .zero : r.insetBy(dx: -24, dy: -36)
    }
}

/// A visible UI element from the Accessibility tree.
public struct UIElementSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var role: String
    public var title: String
    public var value: String?
    /// Frame in global Quartz points.
    public var frame: CGRect
    public var displayID: UInt32
    public var isSecure: Bool
    public var isEnabled: Bool

    public init(id: String, role: String, title: String, value: String? = nil, frame: CGRect, displayID: UInt32, isSecure: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.frame = frame
        self.displayID = displayID
        self.isSecure = isSecure
        self.isEnabled = isEnabled
    }
}

public enum ElementListFormatter {
    /// Roles that are worth pointing at, in rough priority order.
    public static let interactiveRoles: [String] = [
        "AXButton", "AXMenuBarItem", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXSecureTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXLink", "AXTab",
        "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXSegmentedControl", "AXCell", "AXRow", "AXImage",
        "AXStaticText", "AXHeading",
    ]

    /// A compact list for the prompt: `e12 AXButton "Insert" [x,y,w,h]` in
    /// screenshot pixels. Elements off the captured area are dropped.
    public static func format(_ elements: [UIElementSummary], mapping: ScreenshotMapping, limit: Int = 120) -> String {
        let bounds = CGRect(origin: .zero, size: mapping.imageSize)
        var lines: [String] = []
        let ranked = elements.enumerated().sorted { a, b in
            let ra = interactiveRoles.firstIndex(of: a.element.role) ?? interactiveRoles.count
            let rb = interactiveRoles.firstIndex(of: b.element.role) ?? interactiveRoles.count
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)

        for element in ranked where element.displayID == mapping.displayID {
            let r = CoordinateMapper.pixelRect(fromGlobal: element.frame, mapping: mapping)
            guard r.width >= 2, r.height >= 2, bounds.intersects(r) else { continue }
            let clipped = r.intersection(bounds)
            var line = "\(element.id) \(element.role) \"\(sanitize(element.title))\""
            if let value = element.value, !value.isEmpty, !element.isSecure {
                line += " value=\"\(sanitize(String(value.prefix(40))))\""
            }
            if element.isSecure { line += " (password field)" }
            if !element.isEnabled { line += " (disabled)" }
            line += " [\(Int(clipped.minX)),\(Int(clipped.minY)),\(Int(clipped.width)),\(Int(clipped.height))]"
            lines.append(line)
            if lines.count >= limit { break }
        }
        if lines.isEmpty { return "(no accessibility elements available; use coordinates from the screenshot)" }
        return lines.joined(separator: "\n")
    }

    static func sanitize(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ").prefix(80))
    }
}
