import AppKit
import ShowHowCore

/// Guide mode's "wait for the user": watches for the click or typing a step
/// expects, the Next shortcut, a question, or Skip, whichever comes first.
///
/// Global mouse monitors need no permission. Global key monitors need
/// Accessibility; without it, typing steps finish with Next.
@MainActor
final class UserActionMonitor {
    private var continuation: CheckedContinuation<UserEvent, Never>?
    private var monitors: [Any] = []
    private var trigger: AdvanceTrigger = .any
    private var typedCharacters = 0
    private var typingTimer: Timer?

    var isWaiting: Bool { continuation != nil }

    func wait(expected: String, advanceOn: AdvanceTrigger) async -> UserEvent {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<UserEvent, Never>) in
                // A second wait replaces the first; the first finishes as Next.
                resolve(.next)
                continuation = c
                trigger = advanceOn
                typedCharacters = 0
                install()
                if Task.isCancelled { resolve(.next) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(.next) }
        }
    }

    /// Ends the wait. Called by the monitors and by the panel, the hotkeys and voice.
    func resolve(_ event: UserEvent) {
        guard let c = continuation else { return }
        continuation = nil
        removeMonitors()
        c.resume(returning: event)
    }

    private func install() {
        removeMonitors()
        if trigger == .click || trigger == .any {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
                let type = event.type
                MainActor.assumeIsolated { self?.handleClick(type: type) }
            }) {
                monitors.append(m)
            }
        }
        if trigger == .typing || trigger == .any {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
                let keyCode = event.keyCode
                let flags = event.modifierFlags
                MainActor.assumeIsolated { self?.handleKey(keyCode: keyCode, flags: flags) }
            }) {
                monitors.append(m)
            }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        typingTimer?.invalidate()
        typingTimer = nil
    }

    private func handleClick(type: NSEvent.EventType) {
        let point = CoordinateMapper.globalPoint(fromAppKit: NSEvent.mouseLocation, mainDisplayHeight: DisplayManager.shared.mainDisplayHeight)
        let verb: String
        switch type {
        case .rightMouseDown: verb = "right-clicked"
        default: verb = "clicked"
        }
        // Read the element after the click lands, off the main thread.
        Task { @MainActor in
            let element = await Task.detached { AXReader.element(at: point) }.value
            var description = verb
            if let element, !element.title.isEmpty {
                description += " \"\(element.title)\" (\(element.role.replacingOccurrences(of: "AX", with: "")))"
            } else if let element {
                description += " a \(element.role.replacingOccurrences(of: "AX", with: "").lowercased())"
            } else {
                description += " at (\(Int(point.x)), \(Int(point.y)))"
            }
            resolve(.acted(description))
        }
    }

    private func handleKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let returnKeys: Set<UInt16> = [0x24, 0x4C]
        if returnKeys.contains(keyCode) {
            resolve(.acted(typedCharacters > 0 ? "typed some text and pressed Return" : "pressed Return"))
            return
        }
        if flags.contains(.command) {
            resolve(.acted("pressed a ⌘ shortcut"))
            return
        }
        typedCharacters += 1
        // Typing is done after a short pause.
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resolve(.acted("typed \(self.typedCharacters) character\(self.typedCharacters == 1 ? "" : "s")"))
            }
        }
    }
}
