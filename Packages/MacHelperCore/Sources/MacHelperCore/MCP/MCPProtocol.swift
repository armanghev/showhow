import Foundation

/// What the MCP hand-off tools can ask the app to do.
public protocol HandoffDelegate: AnyObject {
    /// Queues a walkthrough. Returns the session id.
    func requestWalkthrough(task: String, context: String?, app: String?, mode: AgentMode?, client: String) async -> String
    /// Starts a queued session now, if Settings allow it. Returns a status line.
    func startNow(sessionID: String) async -> Result<String, HandoffError>
    func pause(sessionID: String) async -> Result<String, HandoffError>
    func resume(sessionID: String) async -> Result<String, HandoffError>
    func cancel(sessionID: String) async -> Result<String, HandoffError>
    func status(sessionID: String) async -> Result<JSONValue, HandoffError>
    /// Writes the write-up and returns its path.
    func documentSession(sessionID: String, record: Bool) async -> Result<String, HandoffError>
    func openWhiteboard() async -> Result<String, HandoffError>
    func whiteboardDraw(_ items: [WhiteboardItemSpec], clear: Bool) async -> Result<String, HandoffError>
}

public struct HandoffError: Error, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// MCP over JSON-RPC 2.0: `initialize`, `tools/list`, `tools/call`, `ping`.
/// Transport-agnostic; the app serves it over Streamable HTTP on localhost and
/// the `machelper-mcp` bridge forwards stdio to that.
public final class MCPServerCore: @unchecked Sendable {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = "mac-helper"

    public weak var delegate: HandoffDelegate?
    public let serverVersion: String
    private var clientName = "Another Claude"
    private let lock = NSLock()

    public init(serverVersion: String, delegate: HandoffDelegate? = nil) {
        self.serverVersion = serverVersion
        self.delegate = delegate
    }

    /// Handles one JSON-RPC message (or batch). Returns nil for notifications.
    public func handle(_ message: JSONValue) async -> JSONValue? {
        if case .array(let batch) = message {
            var responses: [JSONValue] = []
            for item in batch { if let r = await handle(item) { responses.append(r) } }
            return responses.isEmpty ? nil : .array(responses)
        }
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            // A response from the client; nothing to do.
            return nil
        }
        let isNotification = id == nil || id?.isNull == true
        let params = message["params"] ?? [:]

        let result: Result<JSONValue, RPCError>
        switch method {
        case "initialize":
            result = .success(initialize(params))
        case "ping":
            result = .success([:])
        case "tools/list":
            result = .success(["tools": .array(Self.tools)])
        case "tools/call":
            result = .success(await callTool(params))
        case "notifications/initialized", "notifications/cancelled":
            return nil
        default:
            result = .failure(RPCError(code: -32601, message: "Method not found: \(method)"))
        }
        if isNotification { return nil }
        switch result {
        case .success(let value):
            return ["jsonrpc": "2.0", "id": id ?? .null, "result": value]
        case .failure(let error):
            return ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]]
        }
    }

    public struct RPCError: Error { public var code: Int; public var message: String }

    public static func parseError() -> JSONValue {
        ["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]]
    }

    private func initialize(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? Self.supportedVersions[0]
        let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
        if let name = params["clientInfo"]?["name"]?.stringValue {
            lock.lock(); clientName = Self.friendlyClientName(name); lock.unlock()
        }
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(Self.serverName), "version": .string(serverVersion)],
            "instructions": """
            Mac Helper runs guided walkthroughs on this Mac: it sees the screen, draws highlights and arrows, and \
            explains each step. Use request_walkthrough to hand it a task (with any context such as assignment \
            text or what the user already tried). The walkthrough is queued and starts when the user presses \
            Start; it never starts on its own unless the user allowed that in Settings. Use get_status to report \
            progress back to the user.
            """,
        ]
    }

    static func friendlyClientName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("claude-code") || lower.contains("claude code") { return "Claude Code" }
        if lower.contains("claude") { return "Claude Desktop" }
        return raw
    }

    private func callTool(_ params: JSONValue) async -> JSONValue {
        guard let name = params["name"]?.stringValue else { return Self.toolError("Missing tool name.") }
        let args = params["arguments"] ?? [:]
        guard let delegate else { return Self.toolError("Mac Helper is not ready yet.") }
        let client = lock.withLock { clientName }

        func text(_ r: Result<String, HandoffError>) -> JSONValue {
            switch r {
            case .success(let s): return Self.toolText(s)
            case .failure(let e): return Self.toolError(e.message)
            }
        }
        func sessionID() -> String? { args["session_id"]?.stringValue }

        switch name {
        case "request_walkthrough":
            guard let task = args["task"]?.stringValue, !task.isEmpty else { return Self.toolError("task is required.") }
            let mode = args["mode"]?.stringValue.flatMap { $0 == "do_it" || $0 == "doit" ? AgentMode.doIt : ($0 == "guide" ? .guide : nil) }
            let id = await delegate.requestWalkthrough(task: task, context: args["context"]?.stringValue, app: args["app"]?.stringValue, mode: mode, client: client)
            return Self.toolText("Queued as session \(id). The Mac Helper panel now shows \"Ready when you are\" and the walkthrough starts when the user presses Start or taps the hotkey. Use get_status to follow it.")
        case "start_now":
            guard let id = sessionID() else { return Self.toolError("session_id is required.") }
            return text(await delegate.startNow(sessionID: id))
        case "pause":
            guard let id = sessionID() else { return Self.toolError("session_id is required.") }
            return text(await delegate.pause(sessionID: id))
        case "resume":
            guard let id = sessionID() else { return Self.toolError("session_id is required.") }
            return text(await delegate.resume(sessionID: id))
        case "cancel":
            guard let id = sessionID() else { return Self.toolError("session_id is required.") }
            return text(await delegate.cancel(sessionID: id))
        case "get_status":
            guard let id = sessionID() else { return Self.toolError("session_id is required.") }
            switch await delegate.status(sessionID: id) {
            case .success(let status):
                return ["content": [["type": "text", "text": .string(status.encodedString(pretty: true))]], "structuredContent": status]
            case .failure(let e):
                return Self.toolError(e.message)
            }
        case "document_session":
            guard let id = sessionID() else { return Self.toolError("session_id is required.") }
            return text(await delegate.documentSession(sessionID: id, record: args["record"]?.boolValue ?? false))
        case "open_whiteboard":
            return text(await delegate.openWhiteboard())
        case "whiteboard_draw":
            return text(await delegate.whiteboardDraw(WhiteboardItemSpec.parse(args), clear: args["clear"]?.boolValue ?? false))
        default:
            return Self.toolError("Unknown tool \(name).")
        }
    }

    static func toolText(_ text: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]]]
    }

    static func toolError(_ text: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": true]
    }

    static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }

    static let sessionOnly = schema(["session_id": ["type": "string"]], required: ["session_id"])

    public static let tools: [JSONValue] = [
        [
            "name": "request_walkthrough",
            "description": "Queue a guided walkthrough on the user's Mac. Mac Helper's own agent sees the screen and guides the user step by step with on-screen highlights. It starts when the user presses Start. Returns a session id.",
            "inputSchema": schema([
                "task": ["type": "string", "description": "What the user wants to do, e.g. 'Make a pivot table of sales by region in Numbers'."],
                "context": ["type": "string", "description": "Anything useful: assignment text, what they tried, constraints."],
                "app": ["type": "string", "description": "The app the walkthrough is about, if known."],
                "mode": ["type": "string", "enum": ["guide", "do_it"], "description": "guide (default): the user clicks. do_it: Mac Helper clicks, with confirmations."],
            ], required: ["task"]),
        ],
        ["name": "start_now", "description": "Start a queued walkthrough without waiting for the user to press Start. Only works if the user allowed it in Mac Helper's Settings.", "inputSchema": sessionOnly],
        ["name": "pause", "description": "Pause a walkthrough.", "inputSchema": sessionOnly],
        ["name": "resume", "description": "Resume a paused walkthrough.", "inputSchema": sessionOnly],
        ["name": "cancel", "description": "Cancel a queued or running walkthrough.", "inputSchema": sessionOnly],
        ["name": "get_status", "description": "Get a walkthrough's state, current step, and latest instruction.", "inputSchema": sessionOnly],
        [
            "name": "document_session",
            "description": "Write a Markdown write-up (annotated screenshots per step) of a walkthrough and return its folder path.",
            "inputSchema": schema(["session_id": ["type": "string"], "record": ["type": "boolean", "description": "Also record the screen for the rest of the session."]], required: ["session_id"]),
        ],
        ["name": "open_whiteboard", "description": "Open Mac Helper's full-screen whiteboard on the user's Mac.", "inputSchema": schema([:], required: [])],
        [
            "name": "whiteboard_draw",
            "description": "Draw on the open whiteboard to explain something. Coordinates are in a 1600x1000 canvas.",
            "inputSchema": schema([
                "items": [
                    "type": "array",
                    "items": schema([
                        "kind": ["type": "string", "enum": ["stroke", "rect", "ellipse", "arrow", "text"]],
                        "points": ["type": "array", "items": schema(["x": ["type": "number"], "y": ["type": "number"]], required: ["x", "y"])],
                        "text": ["type": "string"],
                        "color": ["type": "string", "enum": ["accent", "red", "green", "blue", "orange", "purple", "black"]],
                    ], required: ["kind", "points"]),
                ],
                "clear": ["type": "boolean"],
            ], required: ["items"]),
        ],
    ]
}
