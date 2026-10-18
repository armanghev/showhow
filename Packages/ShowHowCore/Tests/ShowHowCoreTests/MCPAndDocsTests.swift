import XCTest
@testable import ShowHowCore

final class FakeHandoff: HandoffDelegate {
    var queued: [(String, String?, String)] = []
    func requestWalkthrough(task: String, context: String?, app: String?, mode: AgentMode?, client: String) async -> String {
        queued.append((task, context, client))
        return "S1"
    }
    func startNow(sessionID: String) async -> Result<String, HandoffError> { .failure(HandoffError("Not allowed in Settings.")) }
    func pause(sessionID: String) async -> Result<String, HandoffError> { .success("Paused.") }
    func resume(sessionID: String) async -> Result<String, HandoffError> { .success("Resumed.") }
    func cancel(sessionID: String) async -> Result<String, HandoffError> { .success("Cancelled.") }
    func status(sessionID: String) async -> Result<JSONValue, HandoffError> { .success(["state": "queued", "step": 0]) }
    func documentSession(sessionID: String, record: Bool) async -> Result<String, HandoffError> { .success("/tmp/doc") }
    func openWhiteboard() async -> Result<String, HandoffError> { .success("Opened.") }
    func whiteboardDraw(_ items: [WhiteboardItemSpec], clear: Bool) async -> Result<String, HandoffError> { .success("Drew \(items.count).") }
}

final class MCPTests: XCTestCase {
    func testInitializeNegotiatesVersionAndRemembersClient() async {
        let delegate = FakeHandoff()
        let core = MCPServerCore(serverVersion: "1.0", delegate: delegate)
        let response = await core.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                          "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code", "version": "2"]]])
        XCTAssertEqual(response?["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(response?["result"]?["serverInfo"]?["name"], "showhow")
        let unknown = await core.handle(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual(unknown?["result"]?["protocolVersion"]?.stringValue, MCPServerCore.supportedVersions[0])

        _ = await core.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "request_walkthrough", "arguments": ["task": "Export PDF"]]])
        XCTAssertEqual(delegate.queued.first?.0, "Export PDF")
        XCTAssertEqual(delegate.queued.first?.2, "Claude Code")
    }

    func testNotificationsGetNoResponse() async {
        let core = MCPServerCore(serverVersion: "1.0")
        let r = await core.handle(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(r)
    }

    func testToolsListAndErrors() async {
        let delegate = FakeHandoff()
        let core = MCPServerCore(serverVersion: "1.0", delegate: delegate)
        let list = await core.handle(["jsonrpc": "2.0", "id": "a", "method": "tools/list"])
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertEqual(Set(names), ["request_walkthrough", "start_now", "pause", "resume", "cancel", "get_status", "document_session", "open_whiteboard", "whiteboard_draw"])

        let refused = await core.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "start_now", "arguments": ["session_id": "S1"]]])
        XCTAssertEqual(refused?["result"]?["isError"], true)

        let status = await core.handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "get_status", "arguments": ["session_id": "S1"]]])
        XCTAssertEqual(status?["result"]?["structuredContent"]?["state"], "queued")

        let missing = await core.handle(["jsonrpc": "2.0", "id": 6, "method": "bogus"])
        XCTAssertEqual(missing?["error"]?["code"], -32601)
    }

    func testHTTPParsingAndRouting() async {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer tok\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let request, let consumed) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("parse") }
        XCTAssertEqual(consumed, raw.utf8.count)
        XCTAssertEqual(request.header("Authorization"), "Bearer tok")
        XCTAssertEqual(HTTPRequest.parse(Data(raw.utf8).dropLast(3)), .incomplete)

        let router = MCPHTTPRouter(core: MCPServerCore(serverVersion: "1"), token: "tok")
        let ok = await router.route(request)
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(try JSONValue.decode(ok.body)["result"], [:])

        var unauthorized = request
        unauthorized.headers["authorization"] = "Bearer nope"
        let denied = await router.route(unauthorized)
        XCTAssertEqual(denied.status, 401)

        var browser = request
        browser.headers["origin"] = "https://evil.example"
        let forbidden = await router.route(browser)
        XCTAssertEqual(forbidden.status, 403)

        var notification = request
        notification.body = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let accepted = await router.route(notification)
        XCTAssertEqual(accepted.status, 202)

        let serialized = String(decoding: HTTPResponse.json(["a": 1]).serialized(), as: UTF8.self)
        XCTAssertTrue(serialized.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(serialized.contains("Content-Length: 7\r\n"))
    }

    func testClaudeDesktopConfigMergeKeepsOtherServers() throws {
        let existing = Data(#"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#.utf8)
        let merged = try ClaudeDesktopConfig.merged(existing: existing, bridgePath: "/Applications/ShowHow.app/Contents/Helpers/showhow-mcp")
        XCTAssertEqual(merged["theme"], "dark")
        XCTAssertEqual(merged["mcpServers"]?["other"]?["command"], "x")
        XCTAssertEqual(merged["mcpServers"]?["showhow"]?["command"], "/Applications/ShowHow.app/Contents/Helpers/showhow-mcp")
        XCTAssertEqual(try ClaudeDesktopConfig.merged(existing: nil, bridgePath: "/b")["mcpServers"]?["showhow"]?["args"], [])
    }

    func testEndpointCommand() {
        let info = MCPEndpointInfo(port: 51234, token: "abc")
        XCTAssertEqual(info.claudeCodeCommand, "claude mcp add --transport http showhow http://127.0.0.1:51234/mcp --header \"Authorization: Bearer abc\"")
    }
}

final class URLCommandTests: XCTestCase {
    func testWalkthrough() {
        let url = URL(string: "showhow://walkthrough?task=Make%20a%20pivot%20table&app=Numbers&mode=do-it")!
        XCTAssertEqual(URLCommand(url: url), .walkthrough(task: "Make a pivot table", context: nil, app: "Numbers", mode: .doIt, autoStart: false))
        XCTAssertNil(URLCommand(url: URL(string: "showhow://walkthrough")!))
        XCTAssertEqual(URLCommand(url: URL(string: "showhow://pause")!), .pause)
        XCTAssertEqual(URLCommand(url: URL(string: "showhow:document-last")!), .documentLast)
        XCTAssertNil(URLCommand(url: URL(string: "https://example.com")!))
    }

    func testShortcutConflicts() {
        XCTAssertEqual(SystemShortcuts.conflict(keyCode: 0x31, modifiers: [.command]), "Spotlight")
        XCTAssertNil(SystemShortcuts.conflict(keyCode: 0x31, modifiers: [.option]))
    }
}

final class MarkdownExporterTests: XCTestCase {
    func makeLog() -> SessionLog {
        var log = SessionLog(task: "Pivot table in Numbers", sourceLabel: "You", mode: .guide, model: "claude-opus-5-5",
                             startedAt: Date(timeIntervalSince1970: 1_792_300_000))
        log.steps = [
            LogStep(index: 1, startedAt: log.startedAt, screenshotFile: "shot-001.jpg", annotations: [], instruction: "Click Insert in the toolbar.",
                    detail: "It is the plus icon.", expectedAction: "click Insert", userAction: "clicked Insert", verificationScreenshotFile: "shot-002.jpg", completedAt: log.startedAt),
            LogStep(index: 2, startedAt: log.startedAt.addingTimeInterval(65), screenshotFile: "shot-002.jpg", instruction: "Choose Pivot Table."),
            LogStep(index: 3, startedAt: log.startedAt, expectedAction: "nothing shown"),
        ]
        log.outcome = "You made a pivot table."
        log.recordingFile = "recording.mov"
        log.recordingStartedAt = log.startedAt
        return log
    }

    func testSkeletonAndRender() {
        let doc = MarkdownExporter.skeleton(from: makeLog())
        XCTAssertEqual(doc.steps.count, 2, "steps with no instruction or annotation are dropped")
        XCTAssertEqual(doc.steps[0].image, "images/step-01.jpg")
        XCTAssertEqual(doc.steps[1].recordingOffset, 65)
        let md = MarkdownExporter.render(doc)
        XCTAssertTrue(md.hasPrefix("# Pivot table in Numbers\n"))
        XCTAssertTrue(md.contains("## Step 1\n\n![Step 1](images/step-01.jpg)\n\nClick Insert in the toolbar."))
        XCTAssertTrue(md.contains("> **Tip:** It is the plus icon."))
        XCTAssertTrue(md.contains("[recording.mov](recording.mov)"))
        XCTAssertTrue(md.contains("_Recording: 1:05_"))
    }

    func testPolishApplies() {
        let doc = MarkdownExporter.skeleton(from: makeLog())
        let polish = WriteupPolish(title: "Make a pivot table", summary: "Two lines.", prerequisites: ["Numbers"],
                                   steps: [.init(index: 2, instruction: "Pick Pivot Table from the menu.", tip: "", check: "A new sheet appears.")])
        let out = MarkdownExporter.apply(polish, to: doc)
        XCTAssertEqual(out.title, "Make a pivot table")
        XCTAssertEqual(out.steps[1].instruction, "Pick Pivot Table from the menu.")
        XCTAssertEqual(out.steps[1].check, "A new sheet appears.")
        XCTAssertEqual(out.steps[0].instruction, "Click Insert in the toolbar.")
        XCTAssertEqual(MarkdownExporter.folderName(for: out).suffix(18), "Make a pivot table")
    }

    func testStorePurgeKeepsDocumented() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionLogStore(root: root)
        var old = SessionLog(task: "old", sourceLabel: "You", mode: .guide, model: "m", startedAt: Date().addingTimeInterval(-10 * 86_400))
        try store.save(old)
        old.id = UUID()
        old.writeupPath = "/somewhere"
        try store.save(old)
        try store.save(SessionLog(task: "new", sourceLabel: "You", mode: .guide, model: "m"))
        XCTAssertEqual(store.purge(olderThan: 7), 1)
        XCTAssertEqual(store.recent().map(\.task).sorted(), ["new", "old"])
        // Delete now keeps only the documented session.
        XCTAssertEqual(store.deleteAll(), 1)
        XCTAssertEqual(store.recent().map(\.task), ["old"])
        try? FileManager.default.removeItem(at: root)
    }
}

final class BoardTests: XCTestCase {
    func testCameraZoomKeepsAnchor() {
        var camera = BoardCamera(offset: CGPoint(x: 100, y: 50), zoom: 1)
        let anchor = CGPoint(x: 300, y: 200)
        let before = camera.toWorld(anchor)
        camera.zoom(by: 2, anchor: anchor)
        XCTAssertEqual(camera.zoom, 2)
        let after = camera.toWorld(anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)
        camera.pan(byView: CGSize(width: 20, height: 0))
        XCTAssertEqual(camera.offset.x, after.x - anchor.x / 2 - 10, accuracy: 0.0001)
    }

    func testSnapshotFrameItems() {
        let frame = BoardSnapshotFrame(worldRect: CGRect(x: 1000, y: 0, width: 800, height: 500), imageSize: CGSize(width: 1600, height: 1000))
        let items = frame.items(from: [
            WhiteboardItemSpec(kind: "rect", points: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 100)], color: "red"),
            WhiteboardItemSpec(kind: "text", points: [CGPoint(x: 1600, y: 1000)], text: "Hi"),
            WhiteboardItemSpec(kind: "arrow", points: [CGPoint(x: 0, y: 0)]),
        ])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].shape, .rect(CGRect(x: 1000, y: 0, width: 100, height: 50)))
        XCTAssertEqual(items[0].color, .red)
        XCTAssertEqual(items[0].author, .agent)
        if case .text(let origin, let s, _) = items[1].shape {
            XCTAssertEqual(origin, CGPoint(x: 1800, y: 500))
            XCTAssertEqual(s, "Hi")
        } else { XCTFail() }
    }

    func testEraseAndCodable() throws {
        var doc = BoardDocument(items: [BoardItem(shape: .stroke(points: [.zero, CGPoint(x: 10, y: 10)])), BoardItem(shape: .ellipse(CGRect(x: 100, y: 100, width: 10, height: 10)))])
        XCTAssertTrue(doc.erase(at: CGPoint(x: 5, y: 5), radius: 2))
        XCTAssertEqual(doc.items.count, 1)
        let data = try JSONEncoder().encode(doc)
        XCTAssertEqual(try JSONDecoder().decode(BoardDocument.self, from: data), doc)
    }
}
