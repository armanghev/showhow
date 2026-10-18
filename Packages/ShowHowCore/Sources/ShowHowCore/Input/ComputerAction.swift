import Foundation

public enum MouseButton: String, Codable, Sendable { case left, right, middle }
public enum ScrollDirection: String, Codable, Sendable { case up, down, left, right }

/// A parsed `computer_toolset_20260801` member call. Coordinates stay in
/// screenshot pixels; the executor maps them with the screenshot's mapping.
public enum ComputerAction: Equatable, Sendable {
    case screenshot
    case zoom(region: CGRect)
    case click(button: MouseButton, count: Int, at: CGPoint?, modifiers: [String])
    case drag(from: CGPoint, to: CGPoint, modifiers: [String])
    case mouseMove(to: CGPoint)
    case mouseDown
    case mouseUp
    case cursorPosition
    case scroll(direction: ScrollDirection, amount: Int, at: CGPoint?, modifiers: [String])
    case type(text: String)
    case key(combo: String, repeatCount: Int)
    case holdKey(combo: String, duration: Double)
    case wait(duration: Double)

    public enum ParseError: Error, Equatable, LocalizedError {
        case unknownMember(String)
        case missingField(String)

        public var errorDescription: String? {
            switch self {
            case .unknownMember(let name): return "Unsupported computer action: \(name)"
            case .missingField(let field): return "Missing or invalid field: \(field)"
            }
        }
    }

    public static func parse(name: String, input: JSONValue) throws -> ComputerAction {
        func point(_ key: String) -> CGPoint? {
            guard let arr = input[key]?.arrayValue, arr.count == 2,
                  let x = arr[0].doubleValue, let y = arr[1].doubleValue else { return nil }
            return CGPoint(x: x, y: y)
        }
        func required(_ key: String) throws -> CGPoint {
            guard let p = point(key) else { throw ParseError.missingField(key) }
            return p
        }
        func modifiers() -> [String] {
            guard let text = input["text"]?.stringValue, !text.isEmpty else { return [] }
            return text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        func text() throws -> String {
            guard let t = input["text"]?.stringValue else { throw ParseError.missingField("text") }
            return t
        }

        switch name {
        case "screenshot": return .screenshot
        case "zoom":
            guard let arr = input["region"]?.arrayValue, arr.count == 4,
                  let x0 = arr[0].doubleValue, let y0 = arr[1].doubleValue,
                  let x1 = arr[2].doubleValue, let y1 = arr[3].doubleValue else { throw ParseError.missingField("region") }
            return .zoom(region: CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)))
        case "left_click": return .click(button: .left, count: 1, at: point("coordinate"), modifiers: modifiers())
        case "right_click": return .click(button: .right, count: 1, at: point("coordinate"), modifiers: modifiers())
        case "middle_click": return .click(button: .middle, count: 1, at: point("coordinate"), modifiers: modifiers())
        case "double_click": return .click(button: .left, count: 2, at: point("coordinate"), modifiers: modifiers())
        case "triple_click": return .click(button: .left, count: 3, at: point("coordinate"), modifiers: modifiers())
        case "left_click_drag":
            return .drag(from: try required("start_coordinate"), to: try required("coordinate"), modifiers: modifiers())
        case "mouse_move": return .mouseMove(to: try required("coordinate"))
        case "left_mouse_down": return .mouseDown
        case "left_mouse_up": return .mouseUp
        case "cursor_position": return .cursorPosition
        case "scroll":
            guard let dir = input["scroll_direction"]?.stringValue.flatMap(ScrollDirection.init(rawValue:)) else {
                throw ParseError.missingField("scroll_direction")
            }
            let amount = input["scroll_amount"]?.intValue ?? 3
            return .scroll(direction: dir, amount: max(1, min(amount, 50)), at: point("coordinate"), modifiers: modifiers())
        case "type": return .type(text: try text())
        case "key": return .key(combo: try text(), repeatCount: max(1, min(input["repeat"]?.intValue ?? 1, 100)))
        case "hold_key": return .holdKey(combo: try text(), duration: min(input["duration"]?.doubleValue ?? 1, 300))
        case "wait": return .wait(duration: min(input["duration"]?.doubleValue ?? 1, 300))
        default: throw ParseError.unknownMember(name)
        }
    }

    /// Read-only actions run for real in Guide mode too.
    public var isObservation: Bool {
        switch self {
        case .screenshot, .zoom, .cursorPosition, .wait: return true
        default: return false
        }
    }

    /// The pixel the action targets, if any.
    public var targetPixel: CGPoint? {
        switch self {
        case .click(_, _, let at, _): return at
        case .drag(_, let to, _): return to
        case .mouseMove(let to): return to
        case .scroll(_, _, let at, _): return at
        default: return nil
        }
    }
}

/// Maps xdotool-style key names ("Return", "ctrl+s", "super+shift+3") to macOS
/// virtual key codes and modifier flags.
public enum KeyMapping {
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)
    }

    public struct Chord: Equatable, Sendable {
        public var keyCode: UInt16?
        public var modifiers: Modifiers

        public init(keyCode: UInt16?, modifiers: Modifiers) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    public static func modifier(named name: String) -> Modifiers? {
        switch name.lowercased() {
        case "shift": return .shift
        case "ctrl", "control": return .control
        case "alt", "option", "opt": return .option
        case "super", "cmd", "command", "meta", "win": return .command
        case "fn": return .function
        default: return nil
        }
    }

    /// Parses a combo. A combo made only of modifiers has a nil key code.
    public static func parse(_ combo: String) -> Chord? {
        let parts = combo.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var mods: Modifiers = []
        var key: UInt16?
        for part in parts {
            if let m = modifier(named: part) {
                mods.insert(m)
            } else if let code = keyCode(for: part) {
                key = code
            } else {
                return nil
            }
        }
        return Chord(keyCode: key, modifiers: mods)
    }

    public static func keyCode(for name: String) -> UInt16? {
        if let code = named[name.lowercased()] { return code }
        if name.count == 1, let code = characters[name.lowercased()] { return code }
        return nil
    }

    /// Virtual key codes from Carbon's Events.h (kVK_*), ANSI layout.
    static let characters: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
        "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32, " ": 0x31,
    ]

    static let named: [String: UInt16] = [
        "return": 0x24, "enter": 0x24, "kp_enter": 0x4C, "tab": 0x30, "space": 0x31,
        "backspace": 0x33, "delete": 0x33, "forwarddelete": 0x75, "escape": 0x35, "esc": 0x35,
        "home": 0x73, "end": 0x77, "page_up": 0x74, "pageup": 0x74, "prior": 0x74, "page_down": 0x79, "pagedown": 0x79, "next": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B, "f15": 0x71,
        "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
        "help": 0x72, "insert": 0x72, "capslock": 0x39, "caps_lock": 0x39,
        "minus": 0x1B, "equal": 0x18, "plus": 0x18, "comma": 0x2B, "period": 0x2F, "slash": 0x2C,
        "backslash": 0x2A, "semicolon": 0x29, "apostrophe": 0x27, "quote": 0x27, "grave": 0x32,
        "bracketleft": 0x21, "bracketright": 0x1E,
        "volumeup": 0x48, "volumedown": 0x49, "mute": 0x4A,
    ]

    /// Human-readable form for Guide mode callouts, e.g. "super+shift+s" -> "⇧⌘S".
    public static func symbols(for combo: String) -> String {
        let parts = combo.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        var mods: Modifiers = []
        var keys: [String] = []
        for part in parts {
            if let m = modifier(named: part) { mods.insert(m) } else { keys.append(part) }
        }
        var out = ""
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option) { out += "⌥" }
        if mods.contains(.shift) { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        if mods.contains(.function) { out += "fn " }
        let keySymbols: [String: String] = [
            "return": "↩", "enter": "↩", "tab": "⇥", "space": "Space", "backspace": "⌫", "delete": "⌫",
            "forwarddelete": "⌦", "escape": "esc", "esc": "esc", "left": "←", "right": "→", "up": "↑", "down": "↓",
            "page_up": "⇞", "page_down": "⇟", "home": "↖", "end": "↘",
        ]
        out += keys.map { keySymbols[$0.lowercased()] ?? $0.uppercased() }.joined(separator: " ")
        return out
    }
}
