import Foundation

/// The `showhow://` URL scheme, a zero-dependency hand-off that also makes
/// Shortcuts and Raycast work.
///
///     showhow://walkthrough?task=Make%20a%20pivot%20table&context=...&app=Numbers&mode=guide
///     showhow://pause   showhow://resume   showhow://stop
///     showhow://document-last   showhow://whiteboard   showhow://summon
public enum URLCommand: Equatable, Sendable {
    case walkthrough(task: String, context: String?, app: String?, mode: AgentMode?, autoStart: Bool)
    case pause
    case resume
    case stop
    case documentLast
    case whiteboard
    case summon

    public static let scheme = "showhow"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // showhow://walkthrough?... puts the command in host; showhow:walkthrough in path.
        // URLComponents, because on Darwin URL.path is empty for the second form.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = components?.host.flatMap { $0.isEmpty ? nil : $0 }
        let command = (host ?? (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch command {
        case "walkthrough", "guide", "start":
            guard let task = value("task") else { return nil }
            let mode: AgentMode?
            switch value("mode")?.lowercased() {
            case "guide": mode = .guide
            case "do_it", "doit", "do-it": mode = .doIt
            default: mode = nil
            }
            self = .walkthrough(task: task, context: value("context"), app: value("app"), mode: mode,
                                autoStart: ["1", "true", "yes"].contains(value("start")?.lowercased() ?? ""))
        case "pause": self = .pause
        case "resume": self = .resume
        case "stop", "cancel": self = .stop
        case "document-last", "document": self = .documentLast
        case "whiteboard": self = .whiteboard
        case "summon", "open": self = .summon
        default: return nil
        }
    }
}

/// Shortcuts macOS already uses, so Settings can warn about a clash.
public enum SystemShortcuts {
    public struct Known: Equatable, Sendable {
        public var keyCode: Int
        public var modifiers: KeyMapping.Modifiers
        public var name: String
    }

    // Key codes are Carbon kVK_* values.
    public static let known: [Known] = [
        Known(keyCode: 0x31, modifiers: [.command], name: "Spotlight"),
        Known(keyCode: 0x31, modifiers: [.command, .option], name: "Finder search"),
        Known(keyCode: 0x31, modifiers: [.control], name: "Switch input source"),
        Known(keyCode: 0x31, modifiers: [.control, .command], name: "Emoji & Symbols"),
        Known(keyCode: 0x30, modifiers: [.command], name: "App switcher"),
        Known(keyCode: 0x14, modifiers: [.command, .shift], name: "Screenshot"),
        Known(keyCode: 0x15, modifiers: [.command, .shift], name: "Screenshot selection"),
        Known(keyCode: 0x17, modifiers: [.command, .shift], name: "Screenshot toolbar"),
        Known(keyCode: 0x35, modifiers: [.command, .option], name: "Force Quit"),
        Known(keyCode: 0x7E, modifiers: [.control], name: "Mission Control"),
        Known(keyCode: 0x7D, modifiers: [.control], name: "App windows"),
        Known(keyCode: 0x7B, modifiers: [.control], name: "Move left a space"),
        Known(keyCode: 0x7C, modifiers: [.control], name: "Move right a space"),
        Known(keyCode: 0x0C, modifiers: [.command], name: "Quit app"),
        Known(keyCode: 0x0D, modifiers: [.command], name: "Close window"),
        Known(keyCode: 0x04, modifiers: [.command], name: "Hide app"),
        Known(keyCode: 0x2E, modifiers: [.command], name: "Minimize"),
        Known(keyCode: 0x0C, modifiers: [.control, .command], name: "Lock screen"),
        Known(keyCode: 0x7B, modifiers: [.option], name: "Move one word left in text"),
        Known(keyCode: 0x7C, modifiers: [.option], name: "Move one word right in text"),
    ]

    public static func conflict(keyCode: Int, modifiers: KeyMapping.Modifiers) -> String? {
        known.first { $0.keyCode == keyCode && $0.modifiers == modifiers }?.name
    }
}
