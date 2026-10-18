import Foundation

/// One server-sent event.
public struct SSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental parser for a `text/event-stream` body.
///
/// Feed it lines (without the trailing newline). An event is dispatched on a blank
/// line, as the spec says. Some line readers (Foundation's `AsyncLineSequence`)
/// drop blank lines, so a new `event:` field arriving while data is pending also
/// dispatches the pending event; the Messages API always sends `event:` first.
public struct SSEParser {
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func feed(line rawLine: String) -> [SSEEvent] {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            return dispatch().map { [$0] } ?? []
        }
        if line.hasPrefix(":") {
            return [] // comment / keep-alive
        }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        var out: [SSEEvent] = []
        switch field {
        case "event":
            if !dataLines.isEmpty, let pending = dispatch() { out.append(pending) }
            eventName = String(value)
        case "data":
            dataLines.append(String(value))
        default:
            break // id, retry: not used by the Messages API
        }
        return out
    }

    /// Feeds a raw chunk that may contain several lines (used by tests and by
    /// transports that deliver bytes rather than lines).
    public mutating func feed(chunk: String) -> [SSEEvent] {
        var out: [SSEEvent] = []
        // "\r\n" is a single Character in Swift, so normalize before splitting.
        let normalized = chunk.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            out += feed(line: String(line))
        }
        return out
    }

    /// Dispatches whatever is pending at end of stream.
    public mutating func finish() -> [SSEEvent] {
        dispatch().map { [$0] } ?? []
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventName = nil
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}
