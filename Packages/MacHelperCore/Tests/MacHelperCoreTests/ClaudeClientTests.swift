import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MacHelperCore

final class SSEParserTests: XCTestCase {
    func testDispatchesOnBlankLine() {
        var parser = SSEParser()
        let events = parser.feed(chunk: "event: ping\ndata: {\"type\":\"ping\"}\n\nevent: message_stop\ndata: {}\n\n")
        XCTAssertEqual(events, [SSEEvent(event: "ping", data: "{\"type\":\"ping\"}"), SSEEvent(event: "message_stop", data: "{}")])
    }

    func testDispatchesWhenBlankLinesAreMissing() {
        var parser = SSEParser()
        var events = parser.feed(line: "event: a")
        events += parser.feed(line: "data: 1")
        events += parser.feed(line: "event: b")
        events += parser.feed(line: "data: 2")
        events += parser.finish()
        XCTAssertEqual(events.map(\.data), ["1", "2"])
        XCTAssertEqual(events.map(\.event), ["a", "b"])
    }

    func testIgnoresCommentsAndCarriageReturns() {
        var parser = SSEParser()
        let events = parser.feed(chunk: ": keep-alive\r\nevent: x\r\ndata: y\r\n\r\n")
        XCTAssertEqual(events, [SSEEvent(event: "x", data: "y")])
    }
}

final class StreamAccumulatorTests: XCTestCase {
    static let toolsetStream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":2100,"cache_read_input_tokens":1800,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Looking for the Insert menu."}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Open the "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Insert menu."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: content_block_start
    data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"left_click","toolset_name":"computer","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"coordinate\\": [51"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"2, 742]}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":2}

    event: content_block_start
    data: {"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_2","name":"screenshot","toolset_name":"computer","input":{}}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":3}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":88}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    final class Recorder: StreamObserver {
        var text = ""
        var notes = ""
        var tools: [String] = []
        func streamDidReceiveText(_ delta: String) { text += delta }
        func streamDidReceiveProgressNote(_ delta: String) { notes += delta }
        func streamDidStartToolUse(name: String, toolsetName: String?) { tools.append(name) }
    }

    func testRebuildsToolsetMessage() throws {
        let recorder = Recorder()
        let acc = StreamAccumulator(observer: recorder)
        var parser = SSEParser()
        for e in parser.feed(chunk: Self.toolsetStream) + parser.finish() { try acc.handle(e) }
        let message = try acc.finalMessage()

        XCTAssertEqual(message.stopReason, "tool_use")
        XCTAssertEqual(message.usage.inputTokens, 2100)
        XCTAssertEqual(message.usage.cacheReadInputTokens, 1800)
        XCTAssertEqual(message.usage.outputTokens, 88)
        XCTAssertEqual(message.text, "Open the Insert menu.")
        XCTAssertEqual(message.content[0]["signature"], "sig123")
        XCTAssertEqual(message.content[0]["thinking"], "Looking for the Insert menu.")
        XCTAssertEqual(message.progressNotes, ["Looking for the Insert menu."])

        let uses = message.toolUses
        XCTAssertEqual(uses.map(\.name), ["left_click", "screenshot"])
        XCTAssertEqual(uses[0].toolsetName, "computer")
        XCTAssertEqual(uses[0].input["coordinate"], [512, 742])
        XCTAssertEqual(uses[1].input, [:])

        XCTAssertEqual(recorder.text, "Open the Insert menu.")
        XCTAssertEqual(recorder.tools, ["left_click", "screenshot"])
        XCTAssertEqual(recorder.notes, "Looking for the Insert menu.")
    }

    func testErrorEventThrows() {
        let acc = StreamAccumulator()
        XCTAssertThrowsError(try acc.handle(SSEEvent(event: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))) { error in
            XCTAssertEqual(error as? StreamError, .api(type: "overloaded_error", message: "Overloaded"))
        }
    }

    func testIncompleteStreamThrows() throws {
        let acc = StreamAccumulator()
        try acc.handle(json: ["type": "message_start", "message": ["id": "m"]])
        XCTAssertThrowsError(try acc.finalMessage())
    }

    func testInvalidToolJSONIsKeptForReporting() throws {
        let acc = StreamAccumulator()
        try acc.handle(json: ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "t", "name": "annotate", "input": [:]]])
        try acc.handle(json: ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": "{\"annotations\": ["]])
        try acc.handle(json: ["type": "content_block_stop", "index": 0])
        try acc.handle(json: ["type": "message_stop"])
        XCTAssertNotNil(try acc.finalMessage().toolUses.first?.input["__invalid_json__"])
    }

    func testUnknownBlockTypesPassThrough() throws {
        let acc = StreamAccumulator()
        try acc.handle(json: ["type": "content_block_start", "index": 0, "content_block": ["type": "compaction", "content": ""]])
        try acc.handle(json: ["type": "content_block_delta", "index": 0, "delta": ["type": "compaction_delta", "content": "Summary so far"]])
        try acc.handle(json: ["type": "content_block_stop", "index": 0])
        try acc.handle(json: ["type": "message_stop"])
        XCTAssertEqual(try acc.finalMessage().content.first, ["type": "compaction", "content": "Summary so far"])
    }
}

final class MessagesRequestTests: XCTestCase {
    func testOpusRequestShape() throws {
        let request = MessagesRequest.agentTurn(config: RequestConfig(), system: "sys", tools: AgentTools.definitions, messages: [["role": "user", "content": "hi"]], apiKey: "k")
        XCTAssertEqual(request.headers["x-api-key"], "k")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        let betas = Set((request.headers["anthropic-beta"] ?? "").split(separator: ",").map(String.init))
        XCTAssertEqual(betas, [MessagesRequest.Beta.fallback, MessagesRequest.Beta.thinkingUpdates, MessagesRequest.Beta.contextManagement, MessagesRequest.Beta.compaction])

        let body = request.body
        XCTAssertEqual(body["model"], "claude-opus-5-5")
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["thinking"], ["type": "adaptive", "display": "updates"])
        XCTAssertEqual(body["output_config"], ["effort": "medium"])
        XCTAssertEqual(body["fallbacks"], "default")
        XCTAssertNil(body["tool_choice"], "forced tool choice is rejected on these models")
        XCTAssertNil(body["thinking"]?["budget_tokens"])
        XCTAssertEqual(body["context_management"]?["edits"]?[0]?["type"], "clear_tool_uses_20250919")
        XCTAssertEqual(body["context_management"]?["edits"]?[1]?["type"], "compact_20260112")

        let tools = body["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.first, ["type": "computer_toolset_20260801"])
        XCTAssertNil(tools.first?["name"], "the toolset entry takes no name")
        for tool in tools.dropFirst() {
            XCTAssertEqual(tool["strict"], true)
            XCTAssertNotEqual(tool["name"], "computer")
            XCTAssertEqual(tool["input_schema"]?["additionalProperties"], false)
        }
        XCTAssertNotNil(try request.urlRequest().httpBody)
    }

    func testHaikuSkipsFallbackAndUpdates() {
        let request = MessagesRequest.agentTurn(config: RequestConfig(model: .haiku, contextEditing: false, compaction: false), system: "s", tools: [], messages: [], apiKey: "k")
        XCTAssertNil(request.headers["anthropic-beta"])
        XCTAssertNil(request.body["fallbacks"])
        XCTAssertEqual(request.body["thinking"]?["display"], "summarized")
        XCTAssertNil(request.body["context_management"])
    }

    func testStrictSchemasStayUnderOptionalLimit() {
        // Strict tool use allows at most 24 optional parameters across all strict schemas.
        func optionalCount(_ schema: JSONValue) -> Int {
            guard let props = schema["properties"]?.objectValue else {
                if let items = schema["items"] { return optionalCount(items) }
                return 0
            }
            let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            return props.reduce(0) { total, entry in total + (required.contains(entry.key) ? 0 : 1) + optionalCount(entry.value) }
        }
        let total = AgentTools.definitions.compactMap { $0["input_schema"] }.map(optionalCount).reduce(0, +)
        XCTAssertLessThanOrEqual(total, 24)
    }
}

final class FakeTransport: LineTransport, @unchecked Sendable {
    var responses: [(Int, String)]
    var requests: [URLRequest] = []

    init(_ responses: [(Int, String)]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> LineResponse {
        requests.append(request)
        let (status, body) = responses.removeFirst()
        let lines = body.components(separatedBy: "\n")
        return LineResponse(status: status, headers: [:], lines: AsyncThrowingStream { c in
            for l in lines { c.yield(l) }
            c.finish()
        })
    }
}

final class ClaudeClientTests: XCTestCase {
    func testRetriesOverloadedThenSucceeds() async throws {
        let transport = FakeTransport([
            (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            (200, StreamAccumulatorTests.toolsetStream),
        ])
        let client = ClaudeClient(transport: transport, sleeper: { _ in })
        let request = MessagesRequest.agentTurn(config: RequestConfig(), system: "s", tools: [], messages: [], apiKey: "k")
        let message = try await client.send(request)
        XCTAssertEqual(message.toolUses.count, 2)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testBadRequestSurfacesMessage() async {
        let transport = FakeTransport([(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"compact_20260112 is not supported"}}"#)])
        let client = ClaudeClient(transport: transport, sleeper: { _ in })
        do {
            _ = try await client.send(MessagesRequest.agentTurn(config: RequestConfig(), system: "s", tools: [], messages: [], apiKey: "k"))
            XCTFail("expected error")
        } catch let error as ClaudeError {
            XCTAssertEqual(error.rejectedFeature, .compaction)
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRejectsOversizedRequest() async {
        let client = ClaudeClient(transport: FakeTransport([]))
        client.maxRequestBytes = 10
        do {
            _ = try await client.send(MessagesRequest.agentTurn(config: RequestConfig(), system: "s", tools: [], messages: [], apiKey: "k"))
            XCTFail("expected error")
        } catch let error as ClaudeError {
            if case .requestTooLarge = error {} else { XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testCostMeter() {
        var meter = CostMeter()
        meter.add(Usage(inputTokens: 1_000_000, outputTokens: 100_000), model: .opus)
        XCTAssertEqual(meter.dollars, 6.0, accuracy: 0.0001)
        XCTAssertEqual(meter.formatted, "$6.00")
    }
}
