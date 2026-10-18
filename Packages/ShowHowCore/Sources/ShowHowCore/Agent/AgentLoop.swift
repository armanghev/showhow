import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Sends one request and returns the assistant message. `ClaudeClient` is the
/// real implementation; tests script responses.
public protocol MessageSending: AnyObject {
    func send(_ request: MessagesRequest, observer: StreamObserver?) async throws -> AssistantMessage
}

extension ClaudeClient: MessageSending {}

/// The agent loop from section 2 of the plan: screenshot, ask Claude, run or
/// translate its tool calls, wait for the user, repeat.
///
/// The transcript is append-only. Pausing cancels the running task; whatever
/// tool calls were left unanswered are answered on resume, and resume itself is
/// a new user turn with a fresh screenshot, never an edit of an earlier one.
public final class AgentLoop: @unchecked Sendable {
    public let host: AgentHost
    public let recorder: SessionRecorder
    public private(set) var config: RequestConfig
    public private(set) var messages: [JSONValue] = []
    public private(set) var mode: AgentMode
    public private(set) var activeDisplayID: UInt32 = 0
    public private(set) var meter = CostMeter()
    public var onEvent: (@Sendable (AgentEvent) -> Void)?

    private let sender: MessageSending
    private let apiKey: String
    private let lock = NSLock()
    private var queuedUserMessages: [String] = []
    private var pendingSystemNotes: [String] = []
    private var pending: PendingBatch?
    private var lastScreenshot: Screenshot?
    private var mappings: [UInt32: ScreenshotMapping] = [:]
    private var lastElements: [UIElementSummary] = []
    private var lastAnnotationTarget: CGRect?
    private var stepNumber = 0
    private var started = false

    /// Tool calls from the latest assistant message that still need results.
    struct PendingBatch {
        var toolUses: [ToolUse]
        var results: [String: JSONValue] = [:]
    }

    public init(sender: MessageSending, apiKey: String, config: RequestConfig, mode: AgentMode, host: AgentHost, recorder: SessionRecorder) {
        self.sender = sender
        self.apiKey = apiKey
        self.config = config
        self.mode = mode
        self.host = host
        self.recorder = recorder
    }

    // MARK: Inputs from the UI

    /// A message typed or spoken while Claude is busy. It is delivered with the
    /// next batch of tool results.
    public func enqueueUserMessage(_ text: String) {
        lock.lock(); queuedUserMessages.append(text); lock.unlock()
    }

    public func setMode(_ newMode: AgentMode) {
        lock.lock()
        let changed = newMode != mode
        mode = newMode
        if changed {
            pendingSystemNotes.append(newMode == .guide
                ? "The user switched to Guide mode. From now on, computer actions are shown as instructions and the user performs them."
                : "The user switched to Do-it mode. From now on, computer actions are performed for real. Remember request_confirmation for risky actions.")
        }
        lock.unlock()
        if changed { emit(.modeChanged(newMode)) }
    }

    // MARK: Running

    /// Starts the session with the user's task.
    public func start(task: String, context: String?) async -> AgentOutcome {
        precondition(!started, "start(task:) may only be called once")
        started = true
        do {
            let displays = await host.displays()
            if let preferred = await host.preferredDisplayID() {
                activeDisplayID = preferred
            } else {
                activeDisplayID = displays.first(where: \.isMain)?.id ?? displays.first?.id ?? 0
            }
            var text = "Task: \(task)"
            if let context, !context.isEmpty { text += "\n\nContext from the requester:\n\(context)" }
            let content = try await turnContext(intro: text)
            recorder.note(.user, task)
            append(user: content)
            return await runLoop()
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Continues after a pause. Unanswered tool calls get results first.
    public func resume(note: String = "The session was paused and has now resumed. The screen may have changed.") async -> AgentOutcome {
        do {
            if var batch = pending {
                let shot = try await captureActive()
                var attachedScreen = false
                for use in batch.toolUses where batch.results[use.id] == nil {
                    if use.name == AgentTools.Name.waitForUser, !attachedScreen {
                        batch.results[use.id] = toolResult(use, content: [.text(note + " Check the screen and continue from this step.")] + imageAndElements(shot))
                        attachedScreen = true
                    } else {
                        batch.results[use.id] = toolResult(use, content: [.text("Not executed: the session was paused before this ran.")], isError: true)
                    }
                }
                if !attachedScreen, let last = batch.toolUses.last, var result = batch.results[last.id],
                   case .array(let content)? = result["content"]
                {
                    result["content"] = .array(content + [.text(note)] + imageAndElements(shot))
                    batch.results[last.id] = result
                }
                pending = batch
                try await deliverPendingResults()
            } else if !messages.isEmpty {
                append(user: try await turnContext(intro: note))
            } else {
                return .failed("Nothing to resume.")
            }
            return await runLoop()
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Continues a finished conversation with a follow-up from the user.
    public func followUp(_ text: String) async -> AgentOutcome {
        do {
            recorder.note(.user, text)
            emit(.userMessageDelivered(text))
            append(user: try await turnContext(intro: text))
            return await runLoop()
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func runLoop() async -> AgentOutcome {
        do {
            while true {
                try Task.checkCancellation()
                emit(.turnStarted)
                let response = try await sendWithFeatureFallback()
                meter.add(response.usage, model: config.model)
                recorder.update { $0.cost.add(response.usage, model: self.config.model) }
                emit(.usage(response.usage, config.model))
                messages.append(response.asMessage)

                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    recorder.note(.assistant, text)
                    emit(.assistantText(text))
                }

                if response.stopReason == "refusal" {
                    let category = response.stopDetails?["category"]?.stringValue
                    let explanation = response.stopDetails?["explanation"]?.stringValue
                    return .refused(category: category, message: explanation ?? "Claude declined to help with this request.")
                }

                let uses = response.toolUses
                if uses.isEmpty {
                    if response.stopReason == "max_tokens" {
                        return .failed("The response was cut off. Try a narrower task or a lower effort setting.")
                    }
                    recorder.update { $0.outcome = text }
                    return .finished(summary: text)
                }

                pending = PendingBatch(toolUses: uses)
                try await executePendingBatch()
                try await deliverPendingResults()
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func sendWithFeatureFallback() async throws -> AssistantMessage {
        let observer = LoopStreamObserver(emit: { [weak self] event in self?.emit(event) })
        while true {
            let request = MessagesRequest.agentTurn(config: config, system: SystemPrompt.text, tools: AgentTools.definitions, messages: messages, apiKey: apiKey)
            do {
                return try await sender.send(request, observer: observer)
            } catch let error as ClaudeError {
                switch error.rejectedFeature {
                case .compaction? where config.compaction:
                    config.compaction = false
                    emit(.warning("Server-side compaction is unavailable; continuing without it."))
                case .contextEditing? where config.contextEditing:
                    config.contextEditing = false
                    emit(.warning("Context editing is unavailable; continuing without it."))
                default:
                    throw error
                }
            }
        }
    }

    // MARK: Tool execution

    private func executePendingBatch() async throws {
        guard var batch = pending else { return }
        var halted = false
        var guideShown: [(ToolUse, ComputerAction)] = []

        for use in batch.toolUses where batch.results[use.id] == nil {
            try Task.checkCancellation()
            if halted {
                batch.results[use.id] = toolResult(use, content: [.text(use.isComputerAction
                    ? "Not executed: an earlier computer action in this turn failed."
                    : "Not executed: an earlier action in this turn failed.")], isError: true)
                continue
            }
            do {
                if use.isComputerAction {
                    let action = try ComputerAction.parse(name: use.name, input: use.input)
                    if mode == .guide && !action.isObservation {
                        try await showGuideInstruction(action, for: use)
                        guideShown.append((use, action))
                        batch.results[use.id] = toolResult(use, content: [.text("Shown to the user as an instruction (Guide mode).")])
                    } else {
                        let result = try await runComputer(action, use: use)
                        batch.results[use.id] = result
                        // A declined or refused action counts as a failure: stop the batch.
                        if result["is_error"]?.boolValue == true { halted = true }
                    }
                } else {
                    batch.results[use.id] = try await runCustomTool(use)
                }
            } catch is CancellationError {
                pending = batch
                throw CancellationError()
            } catch {
                halted = true
                batch.results[use.id] = toolResult(use, content: [.text(error.localizedDescription)], isError: true)
            }
            pending = batch
        }
        pending = batch

        // Guide mode: computer actions were drawn as instructions. Unless Claude
        // also called wait_for_user in this batch, wait for the user here so the
        // step is still one-at-a-time, and attach what they did to the last result.
        let waitedExplicitly = batch.toolUses.contains { $0.name == AgentTools.Name.waitForUser && !$0.isComputerAction }
        if let last = guideShown.last, !waitedExplicitly, !halted {
            let expected = GuideTranslator.instruction(for: last.1) ?? "Do the highlighted step"
            let trigger: AdvanceTrigger
            switch last.1 {
            case .type, .key, .holdKey: trigger = .typing
            default: trigger = .click
            }
            let content = try await waitAndDescribe(expected: expected, advanceOn: trigger)
            batch.results[last.0.id] = toolResult(last.0, content: [.text("Shown to the user as an instruction (Guide mode).")] + content)
            pending = batch
        }

        // Do-it mode: make sure Claude sees the outcome of the batch.
        if mode == .doIt, !halted, let lastUse = batch.toolUses.last, lastUse.isComputerAction, lastUse.name != "screenshot", lastUse.name != "zoom",
           var result = batch.results[lastUse.id], case .array(var content)? = result["content"]
        {
            try await Task.sleep(nanoseconds: 400_000_000)
            let shot = try await captureActive()
            content += imageAndElements(shot)
            result["content"] = .array(content)
            batch.results[lastUse.id] = result
            pending = batch
        }
    }

    private func deliverPendingResults() async throws {
        guard let batch = pending else { return }
        var content: [JSONValue] = batch.toolUses.map { use in
            batch.results[use.id] ?? toolResult(use, content: [.text("Not executed.")], isError: true)
        }

        let (queued, notes) = drainQueues()
        for message in queued {
            content.append(["type": "text", "text": .string(message)])
            recorder.note(.user, message)
            emit(.userMessageDelivered(message))
        }
        pending = nil
        append(user: content)
        for note in notes { messages.append(["role": "system", "content": .string(note)]) }
    }

    private func drainQueues() -> ([String], [String]) {
        lock.lock(); defer { lock.unlock() }
        let result = (queuedUserMessages, pendingSystemNotes)
        queuedUserMessages = []
        pendingSystemNotes = []
        return result
    }

    private func runComputer(_ action: ComputerAction, use: ToolUse) async throws -> JSONValue {
        if await host.whiteboardIsOpen(), !action.isObservation {
            return toolResult(use, content: [.text("The whiteboard is open, so computer actions are unavailable. Use whiteboard_draw instead.")], isError: true)
        }
        switch action {
        case .screenshot:
            let shot = try await captureActive()
            return toolResult(use, content: imageAndElements(shot))
        case .zoom(let region):
            if await host.whiteboardIsOpen() {
                return toolResult(use, content: [.text("Zoom is unavailable while the whiteboard is open.")], isError: true)
            }
            guard let mapping = mappings[activeDisplayID] ?? lastScreenshot?.mapping else {
                return toolResult(use, content: [.text("Take a screenshot first.")], isError: true)
            }
            let local = CoordinateMapper.displayRect(fromPixel: region, mapping: mapping)
            let shot = try await host.captureRegion(displayID: mapping.displayID, region: local)
            return toolResult(use, content: [shot.imageBlock])
        case .cursorPosition:
            let global = await host.cursorLocation()
            guard let mapping = mappings[activeDisplayID] else { return toolResult(use, content: [.text("X=0, Y=0")]) }
            let p = CoordinateMapper.pixel(fromGlobal: global, mapping: mapping)
            return toolResult(use, content: [.text("X=\(Int(p.x)), Y=\(Int(p.y))")])
        case .wait(let duration):
            try await Task.sleep(nanoseconds: UInt64(min(duration, 30) * 1_000_000_000))
            return toolResult(use, content: [.text("OK")])
        default:
            // Do-it mode.
            guard let mapping = mappings[activeDisplayID] else {
                return toolResult(use, content: [.text("Take a screenshot first so coordinates can be mapped.")], isError: true)
            }
            let target = action.targetPixel.flatMap { element(atPixel: $0, mapping: mapping) }
            let secure = await host.focusedElementIsSecure()
            switch ConfirmationPolicy.evaluate(action, target: target, focusedIsSecure: secure) {
            case .refuse(let reason):
                recorder.note(.action, "Refused: \(reason)")
                return toolResult(use, content: [.text(reason)], isError: true)
            case .confirm(let reason):
                let approved = await host.confirm(reason)
                recorder.note(.action, approved ? "Approved: \(reason)" : "Declined: \(reason)")
                if !approved {
                    return toolResult(use, content: [.text("The user declined: \(reason). Do not retry it; ask what they would like instead.")], isError: true)
                }
            case .allow:
                break
            }
            emit(.toolActivity(GuideTranslator.instruction(for: action) ?? use.name))
            try await host.perform(action, mapping: mapping)
            recorder.note(.action, "\(use.name) \(use.input.encodedString())")
            return toolResult(use, content: [.text("OK")])
        }
    }

    private func runCustomTool(_ use: ToolUse) async throws -> JSONValue {
        if use.input["__invalid_json__"] != nil {
            return toolResult(use, content: [.text("The tool input was not valid JSON. Call the tool again.")], isError: true)
        }
        switch use.name {
        case AgentTools.Name.annotate:
            let replace = use.input["replace"]?.boolValue ?? true
            let annotations = resolveAnnotations(use.input["annotations"]?.arrayValue ?? [])
            if annotations.isEmpty {
                return toolResult(use, content: [.text("No annotation could be placed. Give a box or point in screenshot pixels, or an element_id from the list.")], isError: true)
            }
            await host.show(annotations, replace: replace)
            lastAnnotationTarget = annotations.last.flatMap { $0.rect ?? $0.point.map { CGRect(x: $0.x - 10, y: $0.y - 10, width: 20, height: 20) } }
            let names = annotations.compactMap { $0.elementID }.compactMap { id in lastElements.first { $0.id == id }?.title }
            recorder.recordStepContent(screenshotFile: lastScreenshotFile, mapping: lastScreenshot?.mapping, annotations: annotations,
                                       elementNames: names, secureRects: secureRects())
            return toolResult(use, content: [.text("Drawn \(annotations.count) annotation(s).")])

        case AgentTools.Name.narrate:
            let instruction = use.input["instruction"]?.stringValue ?? ""
            let detail = use.input["detail"]?.stringValue ?? ""
            await host.setInstruction(instruction, detail: detail)
            recorder.recordStepContent(screenshotFile: lastScreenshotFile, mapping: lastScreenshot?.mapping, instruction: instruction, detail: detail, secureRects: secureRects())
            recorder.note(.note, instruction)
            return toolResult(use, content: [.text("Shown.")])

        case AgentTools.Name.waitForUser:
            let step = use.input["step_number"]?.intValue ?? (stepNumber + 1)
            let total = use.input["total_steps"]?.intValue ?? 0
            let expected = use.input["expected_action"]?.stringValue ?? ""
            let trigger = use.input["advance_on"]?.stringValue.flatMap(AdvanceTrigger.init(rawValue:)) ?? .any
            stepNumber = step
            await host.setProgress(step: step, total: total)
            emit(.stepStarted(step, total: total))
            recorder.recordStepContent(screenshotFile: lastScreenshotFile, mapping: lastScreenshot?.mapping, expected: expected, secureRects: secureRects())
            if mode == .doIt {
                // In Do-it mode there is nothing for the user to do; continue.
                return toolResult(use, content: [.text("Do-it mode is on, so there is no need to wait. Continue with the next action.")])
            }
            let content = try await waitAndDescribe(expected: expected, advanceOn: trigger)
            return toolResult(use, content: content)

        case AgentTools.Name.requestConfirmation:
            let summary = use.input["action_summary"]?.stringValue ?? "Continue?"
            let approved = await host.confirm(summary)
            recorder.note(.action, approved ? "Approved: \(summary)" : "Declined: \(summary)")
            return toolResult(use, content: [.text(approved ? "The user approved. Go ahead." : "The user declined. Do not do it; ask what they would like instead.")])

        case AgentTools.Name.documentSession:
            let record = use.input["record_screen"]?.boolValue ?? false
            let message = await host.enableDocumentation(record: record)
            return toolResult(use, content: [.text(message)])

        case AgentTools.Name.listDisplays:
            return toolResult(use, content: [.text(await displaySummary())])

        case AgentTools.Name.switchDisplay:
            guard let id = use.input["display_id"]?.intValue, await host.displays().contains(where: { $0.id == UInt32(id) }) else {
                return toolResult(use, content: [.text("No display with that id. " + (await displaySummary()))], isError: true)
            }
            activeDisplayID = UInt32(id)
            let shot = try await captureActive()
            return toolResult(use, content: [.text("Display \(id) is now active.")] + imageAndElements(shot))

        case AgentTools.Name.whiteboardDraw:
            guard await host.whiteboardIsOpen() else {
                return toolResult(use, content: [.text("The whiteboard is closed. Ask the user to open it from the menu bar if a sketch would help.")], isError: true)
            }
            try await host.whiteboardDraw(WhiteboardItemSpec.parse(use.input), clear: use.input["clear"]?.boolValue ?? false)
            return toolResult(use, content: [.text("Drawn.")])

        case AgentTools.Name.whiteboardSnapshot:
            guard await host.whiteboardIsOpen() else {
                return toolResult(use, content: [.text("The whiteboard is closed.")], isError: true)
            }
            let shot = try await host.whiteboardSnapshot()
            return toolResult(use, content: [shot.imageBlock])

        default:
            return toolResult(use, content: [.text("Unknown tool \(use.name).")], isError: true)
        }
    }

    /// Waits for the user and returns the tool result content describing what happened.
    private func waitAndDescribe(expected: String, advanceOn: AdvanceTrigger) async throws -> [JSONValue] {
        let event = await host.waitForUser(expected: expected, advanceOn: advanceOn)
        try Task.checkCancellation()
        // Give the UI a moment to settle before checking the result.
        try await Task.sleep(nanoseconds: 600_000_000)
        let shot = try await captureActive()
        let file = lastScreenshotFile
        switch event {
        case .acted(let description):
            recorder.completeStep(userAction: description, verificationFile: file)
            return [.text("The user \(description). Here is the screen now; check whether the step worked.")] + imageAndElements(shot)
        case .next:
            recorder.completeStep(userAction: "pressed Next", verificationFile: file)
            return [.text("The user pressed Next to say this step is done. Here is the screen now; check it.")] + imageAndElements(shot)
        case .skip:
            recorder.completeStep(userAction: "skipped this step", verificationFile: file)
            return [.text("The user skipped this step. Continue with the next one.")] + imageAndElements(shot)
        case .question(let question):
            recorder.note(.user, question)
            emit(.userMessageDelivered(question))
            return [.text("The user has not finished this step yet. They asked: \"\(question)\". Answer briefly in text, then call wait_for_user again for the same step.")] + imageAndElements(shot)
        }
    }

    // MARK: Screenshots and context

    private var lastScreenshotFile: String?

    private func captureActive() async throws -> Screenshot {
        let shot: Screenshot
        if await host.whiteboardIsOpen() {
            shot = try await host.whiteboardSnapshot()
        } else {
            shot = try await host.capture(displayID: activeDisplayID)
            mappings[shot.mapping.displayID] = shot.mapping
            lastElements = await host.visibleElements(displayID: shot.mapping.displayID)
        }
        lastScreenshot = shot
        lastScreenshotFile = recorder.saveScreenshot(shot)
        return shot
    }

    private func imageAndElements(_ shot: Screenshot) -> [JSONValue] {
        var blocks: [JSONValue] = [shot.imageBlock]
        if shot.mapping.displayID != 0 {
            blocks.append(.text("Visible elements (id role \"title\" [x,y,width,height] in screenshot pixels):\n" + ElementListFormatter.format(lastElements, mapping: shot.mapping)))
        }
        return blocks
    }

    private func turnContext(intro: String) async throws -> [JSONValue] {
        let shot = try await captureActive()
        let board = await host.whiteboardIsOpen()
        var context = intro + "\n\nMode: \(mode == .guide ? "Guide (the user performs every action)" : "Do-it (computer actions are performed for real)")."
        context += "\n" + (await displaySummary())
        if board { context += "\nThe whiteboard is open; the image is the board, not the screen." }
        return [.text(context)] + imageAndElements(shot)
    }

    private func displaySummary() async -> String {
        let displays = await host.displays()
        let mouse = await host.cursorLocation()
        let mouseDisplay = CoordinateMapper.display(containing: mouse, in: displays)?.id
        let lines = displays.map { d -> String in
            var line = "- display \(d.id): \(d.name), \(Int(d.frame.width))x\(Int(d.frame.height)) points at (\(Int(d.frame.minX)), \(Int(d.frame.minY)))"
            if d.id == activeDisplayID { line += ", active" }
            if d.id == mouseDisplay { line += ", mouse is here" }
            if d.isMain { line += ", main" }
            return line
        }
        return "Displays:\n" + lines.joined(separator: "\n")
    }

    private func element(atPixel p: CGPoint, mapping: ScreenshotMapping) -> UIElementSummary? {
        let global = CoordinateMapper.globalPoint(fromPixel: p, mapping: mapping)
        return lastElements
            .filter { $0.frame.contains(global) }
            .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    private func secureRects() -> [CGRect] {
        guard let mapping = lastScreenshot?.mapping else { return [] }
        return lastElements.filter { $0.isSecure && $0.displayID == mapping.displayID }
            .map { CoordinateMapper.displayRect(fromGlobal: $0.frame, display: mapping.displayFrame) }
    }

    private func showGuideInstruction(_ action: ComputerAction, for use: ToolUse) async throws {
        guard let mapping = mappings[activeDisplayID] else { return }
        let annotations = GuideTranslator.annotations(for: action, mapping: mapping, elements: lastElements, lastTarget: lastAnnotationTarget)
        guard !annotations.isEmpty else { return }
        await host.show(annotations, replace: true)
        if let instruction = GuideTranslator.instruction(for: action) {
            await host.setInstruction(instruction, detail: "")
        }
        lastAnnotationTarget = annotations.last?.rect ?? lastAnnotationTarget
        recorder.recordStepContent(screenshotFile: lastScreenshotFile, mapping: mapping, annotations: annotations,
                                   instruction: GuideTranslator.instruction(for: action),
                                   elementNames: annotations.compactMap(\.elementID).compactMap { id in lastElements.first { $0.id == id }?.title },
                                   secureRects: secureRects())
    }

    /// Resolves `annotate` specs (screenshot pixels or element ids) to display points.
    func resolveAnnotations(_ specs: [JSONValue]) -> [Annotation] {
        specs.compactMap { spec -> Annotation? in
            guard let kind = spec["kind"]?.stringValue.flatMap(AnnotationKind.init(rawValue:)) else { return nil }
            let display = spec["display_id"]?.intValue.map(UInt32.init) ?? activeDisplayID
            guard let mapping = mappings[display] else { return nil }
            func pt(_ key: String) -> CGPoint? {
                guard let x = spec[key]?["x"]?.doubleValue, let y = spec[key]?["y"]?.doubleValue else { return nil }
                return CoordinateMapper.displayPoint(fromPixel: CGPoint(x: x, y: y), mapping: mapping)
            }
            var rect: CGRect?
            let elementID = spec["element_id"]?.stringValue
            if let elementID, let el = lastElements.first(where: { $0.id == elementID }) {
                rect = CoordinateMapper.displayRect(fromGlobal: el.frame, display: mapping.displayFrame)
            } else if let b = spec["box"], let x = b["x"]?.doubleValue, let y = b["y"]?.doubleValue,
                      let w = b["width"]?.doubleValue, let h = b["height"]?.doubleValue
            {
                rect = CoordinateMapper.displayRect(fromPixel: CGRect(x: x, y: y, width: w, height: h), mapping: mapping)
            }
            let point = pt("point")
            let from = pt("from_point")
            if rect == nil, point == nil { return nil }
            if kind == .arrow, point == nil, rect == nil { return nil }
            return Annotation(kind: kind, displayID: display, label: spec["label"]?.stringValue ?? "",
                              rect: rect, point: point ?? rect.map { CGPoint(x: $0.midX, y: $0.midY) }, fromPoint: from,
                              textToType: spec["text_to_type"]?.stringValue, elementID: elementID)
        }
    }

    // MARK: Helpers

    private func append(user content: [JSONValue]) {
        messages.append(["role": "user", "content": .array(content)])
    }

    private func toolResult(_ use: ToolUse, content: [JSONValue], isError: Bool = false) -> JSONValue {
        var result: [String: JSONValue] = [
            "type": "tool_result",
            "tool_use_id": .string(use.id),
            "content": .array(content),
        ]
        if let toolset = use.toolsetName { result["toolset_name"] = .string(toolset) }
        if isError { result["is_error"] = true }
        return .object(result)
    }

    private func emit(_ event: AgentEvent) {
        onEvent?(event)
    }
}

extension JSONValue {
    static func text(_ s: String) -> JSONValue { ["type": "text", "text": .string(s)] }
}

private final class LoopStreamObserver: StreamObserver {
    let emit: (AgentEvent) -> Void
    init(emit: @escaping (AgentEvent) -> Void) { self.emit = emit }
    func streamDidReceiveText(_ delta: String) { emit(.textDelta(delta)) }
    func streamDidReceiveProgressNote(_ delta: String) { emit(.progressNote(delta)) }
    func streamDidStartToolUse(name: String, toolsetName: String?) { emit(.toolActivity(name)) }
}
