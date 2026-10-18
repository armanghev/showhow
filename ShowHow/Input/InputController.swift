import AppKit
import CoreGraphics
import ShowHowCore

enum InputError: LocalizedError {
    case notTrusted
    case stopped
    case unknownKey(String)
    case eventFailed

    var errorDescription: String? {
        switch self {
        case .notTrusted: return "Do-it mode needs Accessibility permission (System Settings > Privacy & Security > Accessibility)."
        case .stopped: return "Input was stopped by the kill switch or a pause."
        case .unknownKey(let k): return "Unknown key: \(k)"
        case .eventFailed: return "Could not create the input event."
        }
    }
}

/// Synthesizes mouse and keyboard input with CGEvent (Do-it mode only).
@MainActor
final class InputController {
    static let shared = InputController()

    /// Set by the kill switch and by pause; checked before every event.
    private(set) var halted = false
    /// Where we last put the mouse, for human-takeover detection.
    private(set) var lastPostedLocation: CGPoint?
    private(set) var lastPostDate = Date.distantPast
    private let source = CGEventSource(stateID: .hidSystemState)

    func halt() { halted = true }

    /// Clears the kill switch and forgets the last posted location, so a
    /// resumed session does not read the user's earlier mouse moves as a takeover.
    func reset() {
        halted = false
        lastPostedLocation = nil
    }

    func perform(_ action: ComputerAction, mapping: ScreenshotMapping) async throws {
        guard AXIsProcessTrusted() else { throw InputError.notTrusted }
        try check()
        func global(_ p: CGPoint) -> CGPoint { CoordinateMapper.globalPoint(fromPixel: p, mapping: mapping) }

        switch action {
        case .click(let button, let count, let at, let mods):
            let p = at.map(global) ?? currentLocation()
            try await withModifiers(mods) {
                try await self.click(at: p, button: button, count: count)
            }
        case .drag(let from, let to, let mods):
            try await withModifiers(mods) {
                try await self.drag(from: global(from), to: global(to))
            }
        case .mouseMove(let to):
            try move(to: global(to))
        case .mouseDown:
            try post(mouse: .leftMouseDown, at: currentLocation(), button: .left)
        case .mouseUp:
            try post(mouse: .leftMouseUp, at: currentLocation(), button: .left)
        case .scroll(let direction, let amount, let at, let mods):
            if let at { try move(to: global(at)) }
            try await withModifiers(mods) {
                try await self.scroll(direction: direction, amount: amount)
            }
        case .type(let text):
            try await type(text)
        case .key(let combo, let repeatCount):
            for _ in 0..<repeatCount {
                try press(combo)
                try await Task.sleep(nanoseconds: 30_000_000)
            }
        case .holdKey(let combo, let duration):
            guard let chord = KeyMapping.parse(combo) else { throw InputError.unknownKey(combo) }
            try key(chord, down: true)
            try await Task.sleep(nanoseconds: UInt64(min(duration, 30) * 1_000_000_000))
            try key(chord, down: false)
        case .screenshot, .zoom, .cursorPosition, .wait:
            break
        }
    }

    // MARK: Mouse

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func move(to p: CGPoint) throws {
        try post(mouse: .mouseMoved, at: p, button: .left)
    }

    private func click(at p: CGPoint, button: MouseButton, count: Int) async throws {
        let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton)
        switch button {
        case .left: (down, up, cgButton) = (.leftMouseDown, .leftMouseUp, .left)
        case .right: (down, up, cgButton) = (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (down, up, cgButton) = (.otherMouseDown, .otherMouseUp, .center)
        }
        try move(to: p)
        try await Task.sleep(nanoseconds: 40_000_000)
        for i in 1...max(1, count) {
            try check()
            try post(mouse: down, at: p, button: cgButton, clickState: i)
            try post(mouse: up, at: p, button: cgButton, clickState: i)
            if i < count { try await Task.sleep(nanoseconds: 60_000_000) }
        }
    }

    private func drag(from a: CGPoint, to b: CGPoint) async throws {
        try move(to: a)
        try post(mouse: .leftMouseDown, at: a, button: .left)
        let steps = 20
        for i in 1...steps {
            try check()
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            try post(mouse: .leftMouseDragged, at: p, button: .left)
            try await Task.sleep(nanoseconds: 12_000_000)
        }
        try post(mouse: .leftMouseUp, at: b, button: .left)
    }

    private func scroll(direction: ScrollDirection, amount: Int) async throws {
        for _ in 0..<amount {
            try check()
            let (dy, dx): (Int32, Int32)
            switch direction {
            case .up: (dy, dx) = (5, 0)
            case .down: (dy, dx) = (-5, 0)
            case .left: (dy, dx) = (0, 5)
            case .right: (dy, dx) = (0, -5)
            }
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
                throw InputError.eventFailed
            }
            event.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func post(mouse type: CGEventType, at p: CGPoint, button: CGMouseButton, clickState: Int = 1) throws {
        try check()
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else {
            throw InputError.eventFailed
        }
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        event.flags = heldFlags
        event.post(tap: .cghidEventTap)
        lastPostedLocation = p
        lastPostDate = Date()
    }

    // MARK: Keyboard

    private var heldFlags: CGEventFlags = []

    private func withModifiers(_ mods: [String], _ body: () async throws -> Void) async throws {
        let chord = KeyMapping.parse(mods.joined(separator: "+")) ?? KeyMapping.Chord(keyCode: nil, modifiers: [])
        heldFlags = Self.flags(chord.modifiers)
        defer { heldFlags = [] }
        try await body()
    }

    private func press(_ combo: String) throws {
        guard let chord = KeyMapping.parse(combo), chord.keyCode != nil else { throw InputError.unknownKey(combo) }
        try key(chord, down: true)
        try key(chord, down: false)
    }

    private func key(_ chord: KeyMapping.Chord, down: Bool) throws {
        try check()
        guard let code = chord.keyCode else { return }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { throw InputError.eventFailed }
        event.flags = Self.flags(chord.modifiers)
        event.post(tap: .cghidEventTap)
    }

    /// Types literal text with Unicode events, so it works on any keyboard layout.
    private func type(_ text: String) async throws {
        for chunk in text.chunked(into: 16) {
            try check()
            let utf16 = Array(chunk.utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { throw InputError.eventFailed }
                utf16.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private static func flags(_ m: KeyMapping.Modifiers) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }

    private func check() throws {
        if halted { throw InputError.stopped }
        if Task.isCancelled { throw CancellationError() }
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in self {
            current.append(ch)
            if current.count >= size {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// Pauses Do-it mode when the user grabs the mouse: if the pointer moves well
/// away from where we last put it, the human is taking over.
@MainActor
final class TakeoverMonitor {
    private var timer: Timer?
    var onTakeover: (() -> Void)?
    var threshold: CGFloat = 40

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let input = InputController.shared
        guard let last = input.lastPostedLocation, Date().timeIntervalSince(input.lastPostDate) > 0.3 else { return }
        let now = CGEvent(source: nil)?.location ?? last
        if hypot(now.x - last.x, now.y - last.y) > threshold {
            onTakeover?()
        }
    }
}
