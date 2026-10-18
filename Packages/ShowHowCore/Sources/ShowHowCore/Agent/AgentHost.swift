import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// An image sent to Claude, with the mapping back to the display it shows.
public struct Screenshot: Sendable {
    public var data: Data
    public var mediaType: String
    public var mapping: ScreenshotMapping

    public init(data: Data, mediaType: String = "image/jpeg", mapping: ScreenshotMapping) {
        self.data = data
        self.mediaType = mediaType
        self.mapping = mapping
    }

    public var imageBlock: JSONValue {
        ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(data.base64EncodedString())]]
    }
}

/// What ends a Guide mode wait.
public enum AdvanceTrigger: String, Codable, Sendable {
    case click
    case typing
    case nextShortcut = "next_shortcut"
    case any
}

/// What the user did while Claude was waiting on a step.
public enum UserEvent: Equatable, Sendable {
    /// A click, typing, or other action, described in words (with element names).
    case acted(String)
    /// The Next shortcut or button.
    case next
    /// A typed or spoken question; the step is still pending.
    case question(String)
    /// The user asked to skip the step.
    case skip
}

/// A whiteboard drawing request from Claude, in snapshot pixel coordinates.
public struct WhiteboardItemSpec: Equatable, Sendable {
    public var kind: String
    public var points: [CGPoint]
    public var text: String?
    public var color: String?

    public init(kind: String, points: [CGPoint], text: String? = nil, color: String? = nil) {
        self.kind = kind
        self.points = points
        self.text = text
        self.color = color
    }

    public static func parse(_ input: JSONValue) -> [WhiteboardItemSpec] {
        (input["items"]?.arrayValue ?? []).compactMap { item in
            guard let kind = item["kind"]?.stringValue else { return nil }
            let points = (item["points"]?.arrayValue ?? []).compactMap { p -> CGPoint? in
                guard let x = p["x"]?.doubleValue, let y = p["y"]?.doubleValue else { return nil }
                return CGPoint(x: x, y: y)
            }
            return WhiteboardItemSpec(kind: kind, points: points, text: item["text"]?.stringValue, color: item["color"]?.stringValue)
        }
    }
}

/// Everything the agent loop needs from the Mac. The app implements it with
/// ScreenCaptureKit, the overlay windows, CGEvent and the Accessibility API;
/// tests implement it with fakes. Every requirement is async so a main-actor
/// implementation can hop to the main thread.
public protocol AgentHost: AnyObject {
    func displays() async -> [DisplayInfo]
    /// The display that has the mouse or the focused window, used at session start.
    func preferredDisplayID() async -> UInt32?
    func capture(displayID: UInt32) async throws -> Screenshot
    /// Captures `region` (display-local points) of a display at full resolution, downscaled to fit limits.
    func captureRegion(displayID: UInt32, region: CGRect) async throws -> Screenshot
    func visibleElements(displayID: UInt32) async -> [UIElementSummary]
    /// The mouse location in global Quartz points.
    func cursorLocation() async -> CGPoint

    func show(_ annotations: [Annotation], replace: Bool) async
    func clearAnnotations() async
    func setInstruction(_ instruction: String, detail: String) async
    func setProgress(step: Int, total: Int) async
    /// Suspends until the user does the step, asks something, or presses Next.
    /// Must return promptly with a value when the task is cancelled.
    func waitForUser(expected: String, advanceOn: AdvanceTrigger) async -> UserEvent
    func confirm(_ summary: String) async -> Bool

    /// Do-it mode: performs an action. Coordinates are screenshot pixels in `mapping`.
    func perform(_ action: ComputerAction, mapping: ScreenshotMapping) async throws
    func focusedElementIsSecure() async -> Bool

    func whiteboardIsOpen() async -> Bool
    func whiteboardSnapshot() async throws -> Screenshot
    func whiteboardDraw(_ items: [WhiteboardItemSpec], clear: Bool) async throws

    /// Turns on documentation for this session; returns a sentence for Claude.
    func enableDocumentation(record: Bool) async -> String
}

/// Progress the loop reports to the UI. Delivered on an arbitrary thread.
public enum AgentEvent: Sendable {
    case turnStarted
    case textDelta(String)
    case progressNote(String)
    case assistantText(String)
    case toolActivity(String)
    case usage(Usage, ClaudeModel)
    case modeChanged(AgentMode)
    case stepStarted(Int, total: Int)
    case userMessageDelivered(String)
    case warning(String)
}

public enum AgentOutcome: Equatable, Sendable {
    case finished(summary: String)
    case refused(category: String?, message: String)
    case cancelled
    case failed(String)
}
