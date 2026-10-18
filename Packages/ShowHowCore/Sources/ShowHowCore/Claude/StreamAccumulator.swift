import Foundation

/// Token usage reported by the API, summed across a session for the cost meter.
public struct Usage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int = 0, cacheReadInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    /// Merges a `usage` object from `message_start` or `message_delta`. Fields that
    /// are present replace earlier values, matching how the stream reports them.
    mutating func merge(_ json: JSONValue?) {
        guard let json else { return }
        if let v = json["input_tokens"]?.intValue { inputTokens = v }
        if let v = json["output_tokens"]?.intValue { outputTokens = v }
        if let v = json["cache_creation_input_tokens"]?.intValue { cacheCreationInputTokens = v }
        if let v = json["cache_read_input_tokens"]?.intValue { cacheReadInputTokens = v }
    }

    public static func + (lhs: Usage, rhs: Usage) -> Usage {
        Usage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }
}

/// A complete assistant message as rebuilt from the stream.
public struct AssistantMessage: Equatable, Sendable {
    public var id: String?
    public var model: String?
    /// Raw content blocks, passed back to the API unchanged.
    public var content: [JSONValue]
    public var stopReason: String?
    public var stopDetails: JSONValue?
    public var usage: Usage

    public init(id: String? = nil, model: String? = nil, content: [JSONValue] = [], stopReason: String? = nil, stopDetails: JSONValue? = nil, usage: Usage = Usage()) {
        self.id = id
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.stopDetails = stopDetails
        self.usage = usage
    }

    /// The message as it goes back into `messages`.
    public var asMessage: JSONValue {
        ["role": "assistant", "content": .array(content)]
    }

    public var text: String {
        content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
    }

    public var toolUses: [ToolUse] {
        content.compactMap(ToolUse.init(block:))
    }

    /// Progress notes the model writes between tool calls (non-empty thinking text
    /// under `display: "updates"` or `"summarized"`).
    public var progressNotes: [String] {
        content.compactMap { block in
            guard block["type"]?.stringValue == "thinking", let text = block["thinking"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
    }
}

/// A `tool_use` block, either a computer toolset member or one of our own tools.
public struct ToolUse: Equatable, Sendable {
    public var id: String
    public var name: String
    public var toolsetName: String?
    public var input: JSONValue

    public init(id: String, name: String, toolsetName: String? = nil, input: JSONValue = [:]) {
        self.id = id
        self.name = name
        self.toolsetName = toolsetName
        self.input = input
    }

    public init?(block: JSONValue) {
        guard block["type"]?.stringValue == "tool_use",
              let id = block["id"]?.stringValue,
              let name = block["name"]?.stringValue else { return nil }
        self.id = id
        self.name = name
        self.toolsetName = block["toolset_name"]?.stringValue
        self.input = block["input"] ?? [:]
    }

    public var isComputerAction: Bool { toolsetName == "computer" }
}

/// Callbacks fired while a response streams in.
public protocol StreamObserver: AnyObject {
    func streamDidReceiveText(_ delta: String)
    func streamDidReceiveProgressNote(_ delta: String)
    func streamDidStartToolUse(name: String, toolsetName: String?)
}

public extension StreamObserver {
    func streamDidReceiveText(_ delta: String) {}
    func streamDidReceiveProgressNote(_ delta: String) {}
    func streamDidStartToolUse(name: String, toolsetName: String?) {}
}

public enum StreamError: Error, Equatable, LocalizedError {
    case api(type: String, message: String)
    case malformedEvent(String)
    case incomplete

    public var errorDescription: String? {
        switch self {
        case .api(let type, let message): return "\(type): \(message)"
        case .malformedEvent(let detail): return "Malformed stream event: \(detail)"
        case .incomplete: return "The response ended before it was complete."
        }
    }
}

/// Rebuilds an assistant message from Messages API stream events.
///
/// Unknown delta types are merged generically (string fields are appended), so
/// thinking, signature and compaction deltas all land in their blocks without
/// special cases, and new block types pass through intact.
public final class StreamAccumulator {
    public private(set) var message = AssistantMessage()
    public private(set) var isComplete = false
    private var blocks: [Int: JSONValue] = [:]
    private var partialJSON: [Int: String] = [:]
    public weak var observer: StreamObserver?

    public init(observer: StreamObserver? = nil) {
        self.observer = observer
    }

    public func handle(_ event: SSEEvent) throws {
        guard let data = event.data.data(using: .utf8) else { return }
        let json: JSONValue
        do {
            json = try JSONValue.decode(data)
        } catch {
            throw StreamError.malformedEvent(String(event.data.prefix(200)))
        }
        try handle(json: json)
    }

    public func handle(json: JSONValue) throws {
        let type = json["type"]?.stringValue ?? ""
        switch type {
        case "message_start":
            let msg = json["message"]
            message.id = msg?["id"]?.stringValue
            message.model = msg?["model"]?.stringValue
            message.usage.merge(msg?["usage"])
        case "content_block_start":
            guard let index = json["index"]?.intValue, let block = json["content_block"] else { return }
            blocks[index] = block
            if block["type"]?.stringValue == "tool_use" {
                partialJSON[index] = ""
                observer?.streamDidStartToolUse(name: block["name"]?.stringValue ?? "", toolsetName: block["toolset_name"]?.stringValue)
            }
        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"] else { return }
            applyDelta(delta, at: index)
        case "content_block_stop":
            guard let index = json["index"]?.intValue else { return }
            finalizeBlock(at: index)
        case "message_delta":
            if let delta = json["delta"] {
                if let reason = delta["stop_reason"]?.stringValue { message.stopReason = reason }
                if let details = delta["stop_details"], !details.isNull { message.stopDetails = details }
            }
            message.usage.merge(json["usage"])
        case "message_stop":
            message.content = blocks.keys.sorted().compactMap { blocks[$0] }
            isComplete = true
        case "error":
            let err = json["error"]
            throw StreamError.api(type: err?["type"]?.stringValue ?? "error", message: err?["message"]?.stringValue ?? "Unknown error")
        default:
            break // ping and future event types
        }
    }

    /// Returns the final message, or throws if `message_stop` never arrived.
    public func finalMessage() throws -> AssistantMessage {
        guard isComplete else { throw StreamError.incomplete }
        return message
    }

    private func applyDelta(_ delta: JSONValue, at index: Int) {
        guard var block = blocks[index], let deltaObject = delta.objectValue else { return }
        let deltaType = delta["type"]?.stringValue

        if deltaType == "input_json_delta" {
            partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
            return
        }

        for (key, value) in deltaObject where key != "type" {
            if case .string(let addition) = value, case .string(let existing)? = block[key] {
                block[key] = .string(existing + addition)
            } else if case .array(let addition) = value, case .array(let existing)? = block[key] {
                block[key] = .array(existing + addition)
            } else if key == "citation" {
                let existing = block["citations"]?.arrayValue ?? []
                block["citations"] = .array(existing + [value])
            } else {
                block[key] = value
            }
        }
        blocks[index] = block

        if deltaType == "text_delta", let text = delta["text"]?.stringValue {
            observer?.streamDidReceiveText(text)
        } else if deltaType == "thinking_delta", let text = delta["thinking"]?.stringValue, !text.isEmpty {
            observer?.streamDidReceiveProgressNote(text)
        }
    }

    private func finalizeBlock(at index: Int) {
        guard var block = blocks[index] else { return }
        if let raw = partialJSON.removeValue(forKey: index) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if block["input"] == nil { block["input"] = [:] }
            } else if let parsed = try? JSONValue.decode(trimmed) {
                block["input"] = parsed
            } else {
                // Keep the raw text so the dispatcher can report invalid input
                // back to the model instead of crashing.
                block["input"] = ["__invalid_json__": .string(raw)]
            }
        }
        blocks[index] = block
    }
}
