import XCTest
@testable import ShowHowCore

final class CoordinateMapperTests: XCTestCase {
    // A 1512x982 Retina laptop as main, and a 2560x1440 non-Retina display to its
    // left and slightly above (negative x, negative y in Quartz space).
    let laptop = DisplayInfo(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isMain: true)
    let external = DisplayInfo(id: 2, name: "External", frame: CGRect(x: -2560, y: -300, width: 2560, height: 1440), scale: 1, isMain: false)

    func mapping(for d: DisplayInfo) -> ScreenshotMapping {
        ScreenshotMapping(displayID: d.id, displayFrame: d.frame, imageSize: ScreenshotSizing.targetSize(for: d.pixelSize))
    }

    func testRetinaPixelToGlobal() {
        let m = mapping(for: laptop)
        XCTAssertEqual(m.imageSize.width, 1568)
        // The image is 1568 px wide for 1512 points.
        let center = CoordinateMapper.globalPoint(fromPixel: CGPoint(x: m.imageSize.width / 2, y: m.imageSize.height / 2), mapping: m)
        XCTAssertEqual(center.x, 756, accuracy: 0.5)
        XCTAssertEqual(center.y, 491, accuracy: 0.6)
    }

    func testSecondDisplayWithNegativeOrigin() {
        let m = mapping(for: external)
        XCTAssertEqual(m.imageSize.width, 1568)
        let topLeft = CoordinateMapper.globalPoint(fromPixel: .zero, mapping: m)
        XCTAssertEqual(topLeft, CGPoint(x: -2560, y: -300))
        let bottomRight = CoordinateMapper.globalPoint(fromPixel: CGPoint(x: m.imageSize.width, y: m.imageSize.height), mapping: m)
        XCTAssertEqual(bottomRight.x, 0, accuracy: 0.01)
        XCTAssertEqual(bottomRight.y, 1140, accuracy: 2)
    }

    func testRoundTripBothDisplays() {
        for d in [laptop, external] {
            let m = mapping(for: d)
            let pixel = CGPoint(x: 123, y: 456)
            let global = CoordinateMapper.globalPoint(fromPixel: pixel, mapping: m)
            let back = CoordinateMapper.pixel(fromGlobal: global, mapping: m)
            XCTAssertEqual(back.x, pixel.x, accuracy: 0.001)
            XCTAssertEqual(back.y, pixel.y, accuracy: 0.001)
        }
    }

    func testAXFrameToPixelRect() {
        let m = mapping(for: external)
        // A 100x40 point button at display-local (200, 100).
        let global = CGRect(x: -2560 + 200, y: -300 + 100, width: 100, height: 40)
        let r = CoordinateMapper.pixelRect(fromGlobal: global, mapping: m)
        let k = m.imageSize.width / 2560
        XCTAssertEqual(r.minX, 200 * k, accuracy: 0.01)
        XCTAssertEqual(r.width, 100 * k, accuracy: 0.01)
    }

    func testAppKitConversion() {
        // AppKit frame of the external display: y measured up from the main display's bottom.
        let appKit = CoordinateMapper.appKitFrame(of: external.frame, mainDisplayHeight: laptop.frame.height)
        XCTAssertEqual(appKit, CGRect(x: -2560, y: 982 - 1140, width: 2560, height: 1440))
        XCTAssertEqual(CoordinateMapper.quartzFrame(ofAppKit: appKit, mainDisplayHeight: 982), external.frame)
        let p = CGPoint(x: 10, y: 20)
        XCTAssertEqual(CoordinateMapper.globalPoint(fromAppKit: CoordinateMapper.appKitPoint(fromGlobal: p, mainDisplayHeight: 982), mainDisplayHeight: 982), p)
    }

    func testRegionMapping() {
        // A zoom of display-local rect (100,100,200,100) captured at 400x200 px.
        let m = ScreenshotMapping(displayID: 1, displayFrame: laptop.frame, imageSize: CGSize(width: 400, height: 200), sourceRect: CGRect(x: 100, y: 100, width: 200, height: 100))
        XCTAssertEqual(CoordinateMapper.displayPoint(fromPixel: CGPoint(x: 400, y: 200), mapping: m), CGPoint(x: 300, y: 200))
    }

    func testDisplayContaining() {
        XCTAssertEqual(CoordinateMapper.display(containing: CGPoint(x: -10, y: 0), in: [laptop, external])?.id, 2)
        XCTAssertEqual(CoordinateMapper.display(containing: CGPoint(x: 3000, y: 10), in: [laptop, external])?.id, 1)
    }

    func testSizingRespectsTokenBudget() {
        let size = ScreenshotSizing.targetSize(for: CGSize(width: 6016, height: 3384), maxLongEdge: 2576)
        XCTAssertLessThanOrEqual(ScreenshotSizing.visualTokens(size), ScreenshotSizing.modelVisualTokenLimit)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 2576)
        XCTAssertEqual(ScreenshotSizing.targetSize(for: CGSize(width: 800, height: 600)), CGSize(width: 800, height: 600))
    }
}

final class ComputerActionTests: XCTestCase {
    func testParsesMembers() throws {
        XCTAssertEqual(try ComputerAction.parse(name: "left_click", input: ["coordinate": [10, 20], "text": "shift"]),
                       .click(button: .left, count: 1, at: CGPoint(x: 10, y: 20), modifiers: ["shift"]))
        XCTAssertEqual(try ComputerAction.parse(name: "double_click", input: [:]), .click(button: .left, count: 2, at: nil, modifiers: []))
        XCTAssertEqual(try ComputerAction.parse(name: "zoom", input: ["region": [400, 350, 100, 200]]), .zoom(region: CGRect(x: 100, y: 200, width: 300, height: 150)))
        XCTAssertEqual(try ComputerAction.parse(name: "key", input: ["text": "Tab", "repeat": 4]), .key(combo: "Tab", repeatCount: 4))
        XCTAssertEqual(try ComputerAction.parse(name: "scroll", input: ["scroll_direction": "down", "scroll_amount": 3, "coordinate": [5, 6]]),
                       .scroll(direction: .down, amount: 3, at: CGPoint(x: 5, y: 6), modifiers: []))
        XCTAssertEqual(try ComputerAction.parse(name: "left_click_drag", input: ["start_coordinate": [1, 2], "coordinate": [3, 4]]),
                       .drag(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), modifiers: []))
        XCTAssertThrowsError(try ComputerAction.parse(name: "teleport", input: [:]))
        XCTAssertThrowsError(try ComputerAction.parse(name: "type", input: [:]))
    }

    func testKeyMapping() {
        XCTAssertEqual(KeyMapping.parse("super+s"), KeyMapping.Chord(keyCode: 0x01, modifiers: [.command]))
        XCTAssertEqual(KeyMapping.parse("ctrl+shift+Tab"), KeyMapping.Chord(keyCode: 0x30, modifiers: [.control, .shift]))
        XCTAssertEqual(KeyMapping.parse("Return")?.keyCode, 0x24)
        XCTAssertEqual(KeyMapping.parse("alt+Left")?.modifiers, [.option])
        XCTAssertEqual(KeyMapping.parse("F5")?.keyCode, 0x60)
        XCTAssertNil(KeyMapping.parse("hyper+q"))
        XCTAssertEqual(KeyMapping.symbols(for: "super+shift+s"), "⇧⌘S")
        XCTAssertEqual(KeyMapping.symbols(for: "Return"), "↩")
    }
}

final class GuideTranslatorTests: XCTestCase {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 500)
    var mapping: ScreenshotMapping { ScreenshotMapping(displayID: 7, displayFrame: display, imageSize: CGSize(width: 2000, height: 1000)) }

    func testClickSnapsToElement() {
        let button = UIElementSummary(id: "e3", role: "AXButton", title: "Insert", frame: CGRect(x: 100, y: 50, width: 80, height: 30), displayID: 7)
        let a = GuideTranslator.annotations(for: .click(button: .left, count: 1, at: CGPoint(x: 260, y: 120), modifiers: []), mapping: mapping, elements: [button], lastTarget: nil)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].kind, .highlight)
        XCTAssertEqual(a[0].rect, CGRect(x: 100, y: 50, width: 80, height: 30))
        XCTAssertEqual(a[0].label, "Click here: Insert")
        XCTAssertEqual(a[0].elementID, "e3")
    }

    func testClickWithoutElementDrawsCircleAtMappedPoint() {
        let a = GuideTranslator.annotations(for: .click(button: .right, count: 1, at: CGPoint(x: 400, y: 400), modifiers: ["super"]), mapping: mapping, elements: [], lastTarget: nil)
        XCTAssertEqual(a.first?.kind, .circle)
        XCTAssertEqual(a.first?.point, CGPoint(x: 200, y: 200))
        XCTAssertEqual(a.first?.label, "⌘-Right-click here")
    }

    func testTypeAndKey() {
        let target = CGRect(x: 10, y: 10, width: 100, height: 20)
        XCTAssertEqual(GuideTranslator.annotations(for: .type(text: "hello"), mapping: mapping, elements: [], lastTarget: target).first?.textToType, "hello")
        XCTAssertEqual(GuideTranslator.annotations(for: .key(combo: "super+z", repeatCount: 1), mapping: mapping, elements: [], lastTarget: target).first?.label, "Press ⌘Z")
        XCTAssertTrue(GuideTranslator.annotations(for: .screenshot, mapping: mapping, elements: [], lastTarget: nil).isEmpty)
    }

    func testConfirmationPolicy() {
        let send = UIElementSummary(id: "e1", role: "AXButton", title: "Send", frame: .zero, displayID: 1)
        let sendLater = UIElementSummary(id: "e2", role: "AXButton", title: "Send Later", frame: .zero, displayID: 1)
        let sender = UIElementSummary(id: "e3", role: "AXStaticText", title: "Sender", frame: .zero, displayID: 1)
        let click = ComputerAction.click(button: .left, count: 1, at: .zero, modifiers: [])
        XCTAssertEqual(ConfirmationPolicy.evaluate(click, target: send, focusedIsSecure: false), .confirm(reason: "Click \"Send\""))
        XCTAssertEqual(ConfirmationPolicy.evaluate(click, target: sendLater, focusedIsSecure: false), .confirm(reason: "Click \"Send Later\""))
        XCTAssertEqual(ConfirmationPolicy.evaluate(click, target: sender, focusedIsSecure: false), .allow)
        if case .refuse = ConfirmationPolicy.evaluate(.type(text: "hunter2"), target: nil, focusedIsSecure: true) {} else { XCTFail() }
    }

    func testElementListFormatting() {
        let els = [
            UIElementSummary(id: "e1", role: "AXStaticText", title: "Label", frame: CGRect(x: 0, y: 0, width: 50, height: 10), displayID: 7),
            UIElementSummary(id: "e2", role: "AXButton", title: "OK \"now\"", frame: CGRect(x: 10, y: 10, width: 50, height: 20), displayID: 7),
            UIElementSummary(id: "e3", role: "AXButton", title: "Elsewhere", frame: CGRect(x: 10, y: 10, width: 50, height: 20), displayID: 8),
            UIElementSummary(id: "e4", role: "AXSecureTextField", title: "Password", value: "secret", frame: CGRect(x: 0, y: 100, width: 200, height: 20), displayID: 7, isSecure: true),
        ]
        let text = ElementListFormatter.format(els, mapping: mapping)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "e2 AXButton \"OK 'now'\" [20,20,100,40]")
        XCTAssertFalse(text.contains("Elsewhere"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertTrue(text.contains("(password field)"))
    }
}

final class SessionStateMachineTests: XCTestCase {
    func testHappyPath() {
        var m = SessionStateMachine()
        XCTAssertTrue(m.handle(.queue))
        XCTAssertEqual(m.phase, .queued)
        XCTAssertTrue(m.handle(.start))
        XCTAssertTrue(m.handle(.pause(.user)))
        XCTAssertEqual(m.phase, .paused(reason: .user))
        XCTAssertFalse(m.handle(.start))
        XCTAssertTrue(m.handle(.resume))
        XCTAssertTrue(m.handle(.finish))
        XCTAssertEqual(m.phase, .done)
        XCTAssertFalse(m.handle(.pause(.user)))
    }

    func testUserPauseWinsOverTakeover() {
        var m = SessionStateMachine(phase: .running)
        m.handle(.pause(.takeover))
        m.handle(.pause(.user))
        XCTAssertEqual(m.phase, .paused(reason: .user))
        m.handle(.pause(.takeover))
        XCTAssertEqual(m.phase, .paused(reason: .user))
    }

    func testFailAndCancel() {
        var m = SessionStateMachine(phase: .running)
        m.handle(.fail("boom"))
        XCTAssertEqual(m.phase, .failed(message: "boom"))
        XCTAssertTrue(m.handle(.start))
        XCTAssertTrue(m.handle(.cancel))
        XCTAssertEqual(m.phase, .done)
        XCTAssertFalse(SessionPhase.done.isActive)
    }
}
