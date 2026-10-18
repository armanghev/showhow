import AppKit
import KeyboardShortcuts
import ShowHowCore

extension KeyboardShortcuts.Name {
    /// Tap to summon the panel, hold to talk.
    static let summon = Self("summon", default: .init(.space, modifiers: [.option]))
    static let pauseResume = Self("pauseResume", default: .init(.p, modifiers: [.option, .shift]))
    /// ⌃⌥→ rather than the plan's ⌥→, which moves by word in every text field.
    static let nextStep = Self("nextStep", default: .init(.rightArrow, modifiers: [.control, .option]))
    static let whiteboard = Self("whiteboard", default: .init(.w, modifiers: [.option, .shift]))
    static let killSwitch = Self("killSwitch", default: .init(.escape, modifiers: [.command, .shift]))

    static let showHowShortcuts: [Self] = [.summon, .pauseResume, .nextStep, .whiteboard, .killSwitch]

    var title: String {
        switch self {
        case .summon: return "Summon / hold to talk"
        case .pauseResume: return "Pause / resume"
        case .nextStep: return "Next step"
        case .whiteboard: return "Open whiteboard"
        case .killSwitch: return "Kill switch"
        default: return rawValue
        }
    }
}

/// Global shortcuts through KeyboardShortcuts (Carbon RegisterEventHotKey, no
/// permission needed).
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var summonDownAt: Date?
    private var holdTimer: Timer?
    private var holding = false
    /// How long the summon key must be held before it counts as push-to-talk.
    private let holdThreshold: TimeInterval = 0.35

    func install() {
        let session = SessionController.shared

        KeyboardShortcuts.onKeyDown(for: .summon) { [weak self] in self?.summonDown() }
        KeyboardShortcuts.onKeyUp(for: .summon) { [weak self] in self?.summonUp() }
        KeyboardShortcuts.onKeyUp(for: .pauseResume) { session.togglePause() }
        KeyboardShortcuts.onKeyUp(for: .nextStep) { session.next() }
        KeyboardShortcuts.onKeyUp(for: .whiteboard) { WhiteboardController.shared.toggle() }
        KeyboardShortcuts.onKeyDown(for: .killSwitch) { session.kill() }
    }

    private func summonDown() {
        summonDownAt = Date()
        holding = false
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.summonDownAt != nil, AppSettings.shared.voiceEnabled || AppModel.shared.voiceOn else { return }
                self.holding = true
                SessionController.shared.panel.show(expanded: true)
                VoiceController.shared.startListening(handsFree: false)
            }
        }
    }

    private func summonUp() {
        holdTimer?.invalidate()
        summonDownAt = nil
        if holding {
            holding = false
            VoiceController.shared.stopListening(deliver: true)
            return
        }
        // A tap: start a queued hand-off, or bring the panel forward to type.
        let session = SessionController.shared
        if AppModel.shared.phase == .queued, AppModel.shared.queued != nil {
            session.startQueued()
        } else {
            session.panel.summon()
        }
    }

    /// A clash with a shortcut macOS already uses, for the recorder's note.
    static func conflict(for name: KeyboardShortcuts.Name) -> String? {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name), let key = shortcut.key else { return nil }
        var mods: KeyMapping.Modifiers = []
        if shortcut.modifiers.contains(.command) { mods.insert(.command) }
        if shortcut.modifiers.contains(.option) { mods.insert(.option) }
        if shortcut.modifiers.contains(.control) { mods.insert(.control) }
        if shortcut.modifiers.contains(.shift) { mods.insert(.shift) }
        if let system = SystemShortcuts.conflict(keyCode: key.rawValue, modifiers: mods) { return system }
        for other in KeyboardShortcuts.Name.showHowShortcuts where other != name {
            if KeyboardShortcuts.getShortcut(for: other) == shortcut { return "Also used for \(other.title)" }
        }
        return nil
    }
}
