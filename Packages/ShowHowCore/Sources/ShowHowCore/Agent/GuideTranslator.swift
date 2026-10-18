import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Turns computer actions into on-screen instructions for Guide mode, where the
/// user performs every step themselves.
public enum GuideTranslator {
    /// - Parameters:
    ///   - action: the parsed member call.
    ///   - mapping: the screenshot the coordinates refer to.
    ///   - elements: visible elements, used to snap a click to the control under it.
    ///   - lastTarget: where the previous instruction pointed, for `type` and `key`.
    public static func annotations(for action: ComputerAction, mapping: ScreenshotMapping, elements: [UIElementSummary], lastTarget: CGRect?) -> [Annotation] {
        let display = mapping.displayID
        func local(_ p: CGPoint) -> CGPoint { CoordinateMapper.displayPoint(fromPixel: p, mapping: mapping) }
        func element(at p: CGPoint) -> UIElementSummary? {
            let global = CoordinateMapper.globalPoint(fromPixel: p, mapping: mapping)
            return elements
                .filter { $0.displayID == display && $0.frame.contains(global) }
                .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        }
        func modifierPrefix(_ mods: [String]) -> String {
            mods.isEmpty ? "" : KeyMapping.symbols(for: mods.joined(separator: "+")) + "-"
        }

        switch action {
        case .click(let button, let count, let at, let mods):
            let verb: String
            switch (button, count) {
            case (.right, _): verb = "Right-click"
            case (_, 2): verb = "Double-click"
            case (_, 3): verb = "Triple-click"
            case (.middle, _): verb = "Middle-click"
            default: verb = "Click"
            }
            let label = "\(modifierPrefix(mods))\(verb) here"
            guard let at else {
                return [Annotation(kind: .callout, display: display, label: "\(label) (at the pointer)", rect: lastTarget)]
            }
            if let el = element(at: at) {
                let rect = CoordinateMapper.displayRect(fromGlobal: el.frame, display: mapping.displayFrame)
                let title = el.title.isEmpty ? "" : ": \(el.title)"
                return [Annotation(kind: .highlight, display: display, label: "\(label)\(title)", rect: rect, point: local(at), elementID: el.id)]
            }
            let p = local(at)
            return [Annotation(kind: .circle, display: display, label: label, rect: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36), point: p)]

        case .drag(let from, let to, let mods):
            return [Annotation(kind: .arrow, display: display, label: "\(modifierPrefix(mods))Drag from here to here", point: local(to), fromPoint: local(from))]

        case .mouseMove(let to):
            let p = local(to)
            return [Annotation(kind: .circle, display: display, label: "Hover here", rect: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28), point: p)]

        case .scroll(let direction, let amount, let at, _):
            let p = at.map(local) ?? lastTarget.map { CGPoint(x: $0.midX, y: $0.midY) }
            let delta: CGFloat = 60
            let tail: CGPoint? = p.map { p in
                switch direction {
                case .down: return CGPoint(x: p.x, y: p.y - delta)
                case .up: return CGPoint(x: p.x, y: p.y + delta)
                case .left: return CGPoint(x: p.x + delta, y: p.y)
                case .right: return CGPoint(x: p.x - delta, y: p.y)
                }
            }
            let label = "Scroll \(direction.rawValue)" + (amount > 5 ? " a lot" : "")
            return [Annotation(kind: .arrow, display: display, label: label, point: p, fromPoint: tail)]

        case .type(let text):
            return [Annotation(kind: .typeBubble, display: display, label: "Type this", rect: lastTarget, textToType: text)]

        case .key(let combo, let repeatCount):
            let times = repeatCount > 1 ? " \(repeatCount) times" : ""
            return [Annotation(kind: .callout, display: display, label: "Press \(KeyMapping.symbols(for: combo))\(times)", rect: lastTarget)]

        case .holdKey(let combo, let duration):
            return [Annotation(kind: .callout, display: display, label: "Hold \(KeyMapping.symbols(for: combo)) for \(Int(duration.rounded())) s", rect: lastTarget)]

        case .mouseDown:
            return [Annotation(kind: .callout, display: display, label: "Press and hold the mouse button", rect: lastTarget)]
        case .mouseUp:
            return [Annotation(kind: .callout, display: display, label: "Release the mouse button", rect: lastTarget)]

        case .screenshot, .zoom, .cursorPosition, .wait:
            return []
        }
    }

    /// The one-line instruction for the panel when Claude used a computer action
    /// without calling narrate.
    public static func instruction(for action: ComputerAction) -> String? {
        switch action {
        case .type(let text): return "Type \"\(text.prefix(60))\""
        case .key(let combo, _): return "Press \(KeyMapping.symbols(for: combo))"
        default:
            return annotations(for: action, mapping: ScreenshotMapping(displayID: 0, displayFrame: .zero, imageSize: CGSize(width: 1, height: 1)),
                               elements: [], lastTarget: nil).first?.label
        }
    }
}

private extension Annotation {
    init(kind: AnnotationKind, display: UInt32, label: String, rect: CGRect? = nil, point: CGPoint? = nil, fromPoint: CGPoint? = nil, textToType: String? = nil, elementID: String? = nil) {
        self.init(kind: kind, displayID: display, label: label, rect: rect, point: point, fromPoint: fromPoint, textToType: textToType, elementID: elementID)
    }
}

/// Decides when Do-it mode must stop and ask, independently of whether the
/// model remembered to call request_confirmation.
public enum ConfirmationPolicy {
    public static let riskyWords = [
        "send", "submit", "post", "publish", "pay", "purchase", "buy", "order", "checkout", "check out", "delete",
        "remove", "erase", "transfer", "confirm", "sign", "unsubscribe", "empty trash", "reset", "uninstall",
    ]

    public enum Verdict: Equatable {
        case allow
        case confirm(reason: String)
        case refuse(reason: String)
    }

    /// - Parameters:
    ///   - target: the element under the click, if known.
    ///   - focusedIsSecure: whether keyboard focus is in a password field.
    public static func evaluate(_ action: ComputerAction, target: UIElementSummary?, focusedIsSecure: Bool) -> Verdict {
        switch action {
        case .type, .key, .holdKey:
            if focusedIsSecure {
                return .refuse(reason: "The focused field is a password field. Ask the user to type this part themselves.")
            }
            if case .key(let combo, _) = action, combo.lowercased().contains("return") || combo.lowercased().contains("enter"),
               let target, isRisky(target.title)
            {
                return .confirm(reason: "Press Return on \"\(target.title)\"")
            }
            return .allow
        case .click, .drag:
            if let target, target.isSecure, case .click = action { return .allow }
            if let target, isRisky(target.title) {
                return .confirm(reason: "Click \"\(target.title)\"")
            }
            return .allow
        default:
            return .allow
        }
    }

    public static func isRisky(_ title: String) -> Bool {
        let lower = title.lowercased()
        guard !lower.isEmpty else { return false }
        return riskyWords.contains { word in
            lower == word || lower.hasPrefix(word + " ") || lower.hasSuffix(" " + word) || lower.contains(" " + word + " ")
        }
    }
}
