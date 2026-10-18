import XCTest
@testable import ShowHowCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Plays back scripted assistant messages and records every request.
final class ScriptedSender: MessageSending {
    var script: [AssistantMessage]
    var requests: [MessagesRequest] = []
    var onSend: ((Int) async -> Void)?

    init(_ script: [AssistantMessage]) { self.script = script }

    func send(_ request: MessagesRequest, observer: StreamObserver?) async throws -> AssistantMessage {
        requests.append(request)
        await onSend?(requests.count)
        try Task.checkCancellation()
        guard !script.isEmpty else { return AssistantMessage(content: [["type": "text", "text": "done"]], stopReason: "end_turn") }
        return script.removeFirst()
    }
}

class FakeHost: AgentHost {
    let display = DisplayInfo(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 500), scale: 2, isMain: true)
    var shown: [[Annotation]] = []
    var instructions: [String] = []
    var performed: [ComputerAction] = []
    var userEvents: [UserEvent] = [.acted("clicked the Insert button")]
    var confirmations: [Bool] = []
    var asked: [String] = []
    var captures = 0
    var secure = false
    var waitHook: (() async -> Void)?

    func displays() async -> [DisplayInfo] { [display] }
    func preferredDisplayID() async -> UInt32? { 1 }
    func capture(displayID: UInt32) async throws -> Screenshot {
        captures += 1
        return Screenshot(data: Data([0xFF, 0xD8]), mapping: ScreenshotMapping(displayID: 1, displayFrame: display.frame, imageSize: CGSize(width: 1000, height: 500)))
    }
    func captureRegion(displayID: UInt32, region: CGRect) async throws -> Screenshot {
        Screenshot(data: Data([1]), mapping: ScreenshotMapping(displayID: 1, displayFrame: display.frame, imageSize: CGSize(width: 400, height: 200), sourceRect: region))
    }
    func visibleElements(displayID: UInt32) async -> [UIElementSummary] {
        [UIElementSummary(id: "e1", role: "AXButton", title: "Insert", frame: CGRect(x: 100, y: 10, width: 60, height: 24), displayID: 1),
         UIElementSummary(id: "e2", role: "AXButton", title: "Send", frame: CGRect(x: 300, y: 10, width: 60, height: 24), displayID: 1)]
    }
    func cursorLocation() async -> CGPoint { CGPoint(x: 50, y: 60) }
    func show(_ annotations: [Annotation], replace: Bool) async { shown.append(annotations) }
    func clearAnnotations() async {}
    func setInstruction(_ instruction: String, detail: String) async { instructions.append(instruction) }
    func setProgress(step: Int, total: Int) async {}
    func waitForUser(expected: String, advanceOn: AdvanceTrigger) async -> UserEvent {
        await waitHook?()
        return userEvents.isEmpty ? .next : userEvents.removeFirst()
    }
    func confirm(_ summary: String) async -> Bool {
        asked.append(summary)
        return confirmations.isEmpty ? false : confirmations.removeFirst()
    }
    func perform(_ action: ComputerAction, mapping: ScreenshotMapping) async throws { performed.append(action) }
    func focusedElementIsSecure() async -> Bool { secure }
    func whiteboardIsOpen() async -> Bool { false }
    func whiteboardSnapshot() async throws -> Screenshot { throw HandoffError("closed") }
    func whiteboardDraw(_ items: [WhiteboardItemSpec], clear: Bool) async throws {}
    func enableDocumentation(record: Bool) async -> String { "Documentation is on." }
}

func toolUse(_ id: String, _ name: String, _ input: JSONValue, toolset: Bool = false) -> JSONValue {
    var block: JSONValue = ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
    if toolset { block["toolset_name"] = "computer" }
    return block
}

func reply(_ blocks: [JSONValue], stop: String = "tool_use") -> AssistantMessage {
    AssistantMessage(id: "m", content: blocks, stopReason: stop, usage: Usage(inputTokens: 1000, outputTokens: 100))
}

final class AgentLoopTests: XCTestCase {
    var store: SessionLogStore!

    override func setUp() {
        store = SessionLogStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.root)
    }

    func makeLoop(_ sender: ScriptedSender, host: FakeHost, mode: AgentMode = .guide) -> AgentLoop {
        let recorder = SessionRecorder(log: SessionLog(task: "t", sourceLabel: "You", mode: mode, model: "claude-opus-5-5"), store: store)
        return AgentLoop(sender: sender, apiKey: "k", config: RequestConfig(), mode: mode, host: host, recorder: recorder)
    }

    /// Checks invariants the API enforces: every tool_use answered in the next
    /// user message, toolset results echo toolset_name, roles alternate.
    func assertValidTranscript(_ messages: [JSONValue], file: StaticString = #filePath, line: UInt = #line) {
        var lastRole = ""
        for (i, m) in messages.enumerated() {
            let role = m["role"]?.stringValue ?? ""
            if role == "system" { continue }
            XCTAssertNotEqual(role, lastRole, "roles must alternate at \(i)", file: file, line: line)
            lastRole = role
            guard role == "assistant" else { continue }
            let uses = (m["content"]?.arrayValue ?? []).compactMap(ToolUse.init(block:))
            guard !uses.isEmpty else { continue }
            let next = messages[(i + 1)...].first { $0["role"]?.stringValue == "user" }
            let results = next?["content"]?.arrayValue?.filter { $0["type"]?.stringValue == "tool_result" } ?? []
            XCTAssertEqual(results.compactMap { $0["tool_use_id"]?.stringValue }, uses.map(\.id), file: file, line: line)
            for (use, result) in zip(uses, results) {
                XCTAssertEqual(result["toolset_name"]?.stringValue, use.toolsetName, "toolset_name must be echoed", file: file, line: line)
            }
        }
    }

    func testGuideStepAnnotateWaitFinish() async {
        let sender = ScriptedSender([
            reply([
                ["type": "thinking", "thinking": "", "signature": "s1"],
                toolUse("a", "annotate", ["annotations": [["kind": "highlight", "label": "Insert", "element_id": "e1"]], "replace": true]),
                toolUse("b", "narrate", ["instruction": "Click Insert", "detail": ""]),
                toolUse("c", "wait_for_user", ["step_number": 1, "total_steps": 2, "expected_action": "click Insert", "advance_on": "click"]),
            ]),
            reply([["type": "text", "text": "All done."]], stop: "end_turn"),
        ])
        let host = FakeHost()
        let loop = makeLoop(sender, host: host)
        let outcome = await loop.start(task: "Insert a table", context: "Assignment text")
        XCTAssertEqual(outcome, .finished(summary: "All done."))

        XCTAssertEqual(host.shown.first?.first?.rect, CGRect(x: 100, y: 10, width: 60, height: 24))
        XCTAssertEqual(host.instructions, ["Click Insert"])
        assertValidTranscript(loop.messages)

        // The thinking block went back unchanged.
        XCTAssertEqual(loop.messages[1]["content"]?[0]?["signature"], "s1")
        // The wait result carries the user's action and a fresh screenshot.
        let waitResult = loop.messages[2]["content"]?[2]
        XCTAssertTrue(waitResult?["content"]?[0]?["text"]?.stringValue?.contains("clicked the Insert button") == true)
        XCTAssertEqual(waitResult?["content"]?[1]?["type"], "image")
        // First user turn has task, context and a screenshot.
        let first = loop.messages[0]["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(first.contains("Task: Insert a table"))
        XCTAssertTrue(first.contains("Assignment text"))
        XCTAssertTrue(first.contains("Mode: Guide"))

        let log = loop.recorder.log
        XCTAssertEqual(log.steps.count, 1)
        XCTAssertEqual(log.steps[0].instruction, "Click Insert")
        XCTAssertEqual(log.steps[0].userAction, "clicked the Insert button")
        XCTAssertEqual(log.steps[0].elementNames, ["Insert"])
        XCTAssertNotNil(log.steps[0].verificationScreenshotFile)
        XCTAssertGreaterThan(log.cost.dollars, 0)

        // Every request uses an identical tools list, so the cache prefix holds.
        let tools = sender.requests.map { $0.body["tools"] }
        XCTAssertEqual(Set(tools.map { $0?.encodedString() ?? "" }).count, 1)
    }

    func testGuideModeTranslatesClicksAndWaits() async {
        let sender = ScriptedSender([
            reply([toolUse("x", "left_click", ["coordinate": [320, 20]], toolset: true)]),
            reply([["type": "text", "text": "ok"]], stop: "end_turn"),
        ])
        let host = FakeHost()
        let loop = makeLoop(sender, host: host)
        _ = await loop.start(task: "t", context: nil)
        XCTAssertTrue(host.performed.isEmpty, "Guide mode must never perform input")
        XCTAssertEqual(host.shown.first?.first?.label, "Click here: Send")
        assertValidTranscript(loop.messages)
        let result = loop.messages[2]["content"]?[0]
        XCTAssertEqual(result?["toolset_name"], "computer")
        XCTAssertEqual(result?["content"]?[2]?["type"], "image", "the user's action and a new screenshot are attached")
    }

    func testDoItModeConfirmsRiskyClickAndHaltsBatch() async {
        let sender = ScriptedSender([
            reply([toolUse("s", "screenshot", [:], toolset: true)]),
            reply([
                toolUse("c1", "left_click", ["coordinate": [320, 20]], toolset: true),
                toolUse("c2", "type", ["text": "hello"], toolset: true),
            ]),
            reply([["type": "text", "text": "stopped"]], stop: "end_turn"),
        ])
        let host = FakeHost()
        host.confirmations = [false]
        let loop = makeLoop(sender, host: host, mode: .doIt)
        _ = await loop.start(task: "send it", context: nil)
        XCTAssertEqual(host.asked, ["Click \"Send\""])
        XCTAssertTrue(host.performed.isEmpty)
        assertValidTranscript(loop.messages)
        let results = loop.messages[4]["content"]?.arrayValue ?? []
        XCTAssertEqual(results[0]["is_error"], true)
        XCTAssertEqual(results[1]["content"]?[0]?["text"], "Not executed: an earlier computer action in this turn failed.")
    }

    func testDoItModePerformsAndAttachesScreenshot() async {
        let sender = ScriptedSender([
            reply([toolUse("s", "screenshot", [:], toolset: true)]),
            reply([toolUse("c1", "left_click", ["coordinate": [130, 20]], toolset: true)]),
            reply([["type": "text", "text": "ok"]], stop: "end_turn"),
        ])
        let host = FakeHost()
        let loop = makeLoop(sender, host: host, mode: .doIt)
        _ = await loop.start(task: "t", context: nil)
        XCTAssertEqual(host.performed, [.click(button: .left, count: 1, at: CGPoint(x: 130, y: 20), modifiers: [])])
        let result = loop.messages[4]["content"]?[0]
        XCTAssertEqual(result?["content"]?[0]?["text"], "OK")
        XCTAssertEqual(result?["content"]?[1]?["type"], "image")
    }

    func testSecureFieldTypingIsRefused() async {
        let sender = ScriptedSender([
            reply([toolUse("s", "screenshot", [:], toolset: true)]),
            reply([toolUse("t", "type", ["text": "hunter2"], toolset: true)]),
            reply([["type": "text", "text": "ok"]], stop: "end_turn"),
        ])
        let host = FakeHost()
        host.secure = true
        let loop = makeLoop(sender, host: host, mode: .doIt)
        _ = await loop.start(task: "t", context: nil)
        XCTAssertTrue(host.performed.isEmpty)
        XCTAssertEqual(loop.messages[4]["content"]?[0]?["is_error"], true)
    }

    func testPauseDuringWaitThenResume() async {
        let sender = ScriptedSender([
            reply([toolUse("w", "wait_for_user", ["step_number": 1, "total_steps": 1, "expected_action": "x", "advance_on": "any"])]),
            reply([["type": "text", "text": "resumed fine"]], stop: "end_turn"),
        ])
        let host = FakeHost()
        let loop = makeLoop(sender, host: host)
        let task = Task { await loop.start(task: "t", context: nil) }
        host.waitHook = { task.cancel() }
        let first = await task.value
        XCTAssertEqual(first, .cancelled)
        XCTAssertEqual(loop.messages.count, 2, "the assistant turn stays; its result is owed")

        host.waitHook = nil
        let second = await loop.resume()
        XCTAssertEqual(second, .finished(summary: "resumed fine"))
        assertValidTranscript(loop.messages)
        let text = loop.messages[2]["content"]?[0]?["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("paused and has now resumed"))
    }

    func testQueuedMessagesAndModeChangeAreAppended() async {
        let sender = ScriptedSender([
            reply([toolUse("s", "screenshot", [:], toolset: true)]),
            reply([["type": "text", "text": "ok"]], stop: "end_turn"),
        ])
        let host = FakeHost()
        let loop = makeLoop(sender, host: host)
        sender.onSend = { n in
            if n == 1 {
                loop.enqueueUserMessage("What does this button do?")
                loop.setMode(.doIt)
            }
        }
        _ = await loop.start(task: "t", context: nil)
        let userTurn = loop.messages[2]["content"]?.arrayValue ?? []
        XCTAssertEqual(userTurn.last?["text"], "What does this button do?")
        XCTAssertEqual(loop.messages[3]["role"], "system")
        assertValidTranscript(loop.messages)
    }

    func testRefusalStops() async {
        let sender = ScriptedSender([AssistantMessage(content: [], stopReason: "refusal", stopDetails: ["type": "refusal", "category": "cyber", "explanation": "nope"])])
        let loop = makeLoop(sender, host: FakeHost())
        let outcome = await loop.start(task: "t", context: nil)
        XCTAssertEqual(outcome, .refused(category: "cyber", message: "nope"))
    }

    func testFeatureFallbackRetriesWithoutCompaction() async {
        final class RejectingSender: MessageSending {
            var calls: [MessagesRequest] = []
            func send(_ request: MessagesRequest, observer: StreamObserver?) async throws -> AssistantMessage {
                calls.append(request)
                if calls.count == 1 { throw ClaudeError.http(status: 400, type: "invalid_request_error", message: "unknown edit type compact_20260112") }
                return AssistantMessage(content: [["type": "text", "text": "hi"]], stopReason: "end_turn")
            }
        }
        let sender = RejectingSender()
        let recorder = SessionRecorder(log: SessionLog(task: "t", sourceLabel: "You", mode: .guide, model: "m"), store: store)
        let loop = AgentLoop(sender: sender, apiKey: "k", config: RequestConfig(), mode: .guide, host: FakeHost(), recorder: recorder)
        let outcome = await loop.start(task: "t", context: nil)
        XCTAssertEqual(outcome, .finished(summary: "hi"))
        XCTAssertEqual(sender.calls.count, 2)
        XCTAssertFalse(loop.config.compaction)
        XCTAssertEqual(sender.calls[1].body["context_management"]?["edits"]?.arrayValue?.count, 1)
    }

    func testZoomMapsRegionToDisplayPoints() async {
        final class RegionHost: FakeHost {
            var region: CGRect?
            override func captureRegion(displayID: UInt32, region: CGRect) async throws -> Screenshot {
                self.region = region
                return try await super.captureRegion(displayID: displayID, region: region)
            }
        }
        let sender = ScriptedSender([
            reply([toolUse("z", "zoom", ["region": [100, 100, 300, 200]], toolset: true)]),
            reply([["type": "text", "text": "ok"]], stop: "end_turn"),
        ])
        let host = RegionHost()
        let loop = makeLoop(sender, host: host)
        _ = await loop.start(task: "t", context: nil)
        XCTAssertEqual(host.region, CGRect(x: 100, y: 100, width: 200, height: 100))
    }
}
