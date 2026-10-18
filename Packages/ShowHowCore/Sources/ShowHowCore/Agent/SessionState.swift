import Foundation

/// Guide mode: Claude points, the user clicks. Do-it mode: Claude clicks.
public enum AgentMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case guide
    case doIt = "do_it"

    public var id: String { rawValue }
    public var title: String { self == .guide ? "Guide" : "Do it" }
}

/// Where a walkthrough request came from, shown in the panel.
public enum SessionSource: Codable, Equatable, Sendable {
    case panel
    case voice
    case urlScheme
    case mcp(client: String)

    public var label: String {
        switch self {
        case .panel: return "You"
        case .voice: return "Voice"
        case .urlScheme: return "Shortcut link"
        case .mcp(let client): return client
        }
    }
}

/// `idle -> queued -> running <-> paused -> done`, plus `failed`.
public enum SessionPhase: Equatable, Sendable {
    case idle
    case queued
    case running
    case paused(reason: PauseReason)
    case done
    case failed(message: String)

    public var isActive: Bool {
        switch self {
        case .queued, .running, .paused: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .queued: return "Ready"
        case .running: return "Running"
        case .paused: return "Paused"
        case .done: return "Done"
        case .failed: return "Stopped"
        }
    }
}

public enum PauseReason: String, Equatable, Sendable {
    case user
    case takeover
    case whiteboard
    case question
}

public enum SessionEvent: Equatable, Sendable {
    case queue
    case start
    case pause(PauseReason)
    case resume
    case finish
    case fail(String)
    case cancel
    case reset
}

/// Validates session transitions so every entry point (hotkey, menu, panel, MCP,
/// URL scheme) goes through the same rules.
public struct SessionStateMachine: Equatable, Sendable {
    public private(set) var phase: SessionPhase = .idle

    public init(phase: SessionPhase = .idle) {
        self.phase = phase
    }

    @discardableResult
    public mutating func handle(_ event: SessionEvent) -> Bool {
        guard let next = Self.next(from: phase, on: event) else { return false }
        phase = next
        return true
    }

    public static func next(from phase: SessionPhase, on event: SessionEvent) -> SessionPhase? {
        switch (phase, event) {
        case (.idle, .queue), (.done, .queue), (.failed, .queue):
            return .queued
        case (.idle, .start), (.done, .start), (.failed, .start), (.queued, .start):
            return .running
        case (.running, .pause(let reason)):
            return .paused(reason: reason)
        case (.paused(let current), .pause(let reason)):
            // A user pause wins over an automatic one so resume needs the user.
            return .paused(reason: reason == .user ? .user : current)
        case (.paused, .resume):
            return .running
        case (.running, .finish), (.paused, .finish):
            return .done
        case (.queued, .fail), (.running, .fail), (.paused, .fail):
            if case .fail(let message) = event { return .failed(message: message) }
            return nil
        case (.queued, .cancel), (.running, .cancel), (.paused, .cancel):
            return .done
        case (_, .reset):
            return .idle
        default:
            return nil
        }
    }
}
