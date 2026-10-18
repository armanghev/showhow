import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Settings that shape every request in a session. They are fixed for the
/// lifetime of a session so the cached prefix (tools, then system) never changes.
public struct RequestConfig: Equatable, Sendable {
    public var model: ClaudeModel
    public var effort: Effort
    public var maxTokens: Int
    /// Clear stale screenshot results server-side (`clear_tool_uses_20250919`).
    public var contextEditing: Bool
    /// How many recent tool uses keep their results when clearing kicks in.
    public var keepToolUses: Int
    /// Server-side compaction for long sessions (`compact_20260112`).
    public var compaction: Bool

    public init(model: ClaudeModel = .opus, effort: Effort = .medium, maxTokens: Int = 32_000,
                contextEditing: Bool = true, keepToolUses: Int = 6, compaction: Bool = true)
    {
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.contextEditing = contextEditing
        self.keepToolUses = keepToolUses
        self.compaction = compaction
    }
}

/// A Messages API request: headers plus a JSON body.
public struct MessagesRequest: Sendable {
    public var headers: [String: String]
    public var body: JSONValue

    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"

    public enum Beta {
        public static let fallback = "server-side-fallback-2026-07-01"
        public static let thinkingUpdates = "thinking-display-updates-2026-08-18"
        public static let contextManagement = "context-management-2025-06-27"
        public static let compaction = "compact-2026-01-12"
    }

    /// Builds the request for one turn of the agent loop.
    ///
    /// Order matters for caching: `tools` render first, then `system`, then
    /// `messages`. The system prompt carries a cache breakpoint and the request
    /// sets top-level automatic caching so each turn reuses the previous prefix.
    public static func agentTurn(config: RequestConfig, system: String, tools: [JSONValue], messages: [JSONValue], apiKey: String) -> MessagesRequest {
        var betas: [String] = []
        var body: [String: JSONValue] = [
            "model": .string(config.model.rawValue),
            "max_tokens": .number(Double(config.maxTokens)),
            "stream": true,
            "thinking": ["type": "adaptive", "display": .string(config.model.thinkingDisplay)],
            "output_config": ["effort": .string(config.effort.rawValue)],
            "system": [["type": "text", "text": .string(system), "cache_control": ["type": "ephemeral"]]],
            "tools": .array(tools),
            "messages": .array(messages),
            "cache_control": ["type": "ephemeral"],
        ]
        if config.model.thinkingDisplay == "updates" {
            betas.append(Beta.thinkingUpdates)
        }
        if config.model.supportsDefaultFallbacks {
            betas.append(Beta.fallback)
            body["fallbacks"] = "default"
        }

        var edits: [JSONValue] = []
        if config.contextEditing {
            betas.append(Beta.contextManagement)
            edits.append([
                "type": "clear_tool_uses_20250919",
                "keep": ["type": "tool_uses", "value": .number(Double(config.keepToolUses))],
            ])
        }
        if config.compaction {
            betas.append(Beta.compaction)
            edits.append(["type": "compact_20260112"])
        }
        if !edits.isEmpty {
            body["context_management"] = ["edits": .array(edits)]
        }

        return MessagesRequest(headers: headers(apiKey: apiKey, betas: betas), body: .object(body))
    }

    /// A text-only request that returns JSON matching `schema`, used to polish
    /// documentation write-ups. No screenshots are sent, so it is cheap.
    public static func structured(model: ClaudeModel, system: String, prompt: String, schema: JSONValue, apiKey: String) -> MessagesRequest {
        var betas: [String] = []
        var body: [String: JSONValue] = [
            "model": .string(model.rawValue),
            "max_tokens": 16_000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            "system": .string(system),
            "messages": [["role": "user", "content": .string(prompt)]],
        ]
        if model.supportsDefaultFallbacks {
            betas.append(Beta.fallback)
            body["fallbacks"] = "default"
        }
        return MessagesRequest(headers: headers(apiKey: apiKey, betas: betas), body: .object(body))
    }

    static func headers(apiKey: String, betas: [String]) -> [String: String] {
        var headers = [
            "x-api-key": apiKey,
            "anthropic-version": apiVersion,
            "content-type": "application/json",
            "accept": "text/event-stream",
        ]
        if !betas.isEmpty { headers["anthropic-beta"] = betas.joined(separator: ",") }
        return headers
    }

    public func urlRequest(timeout: TimeInterval = 600) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try body.encoded()
        return request
    }
}
