import AppKit
import ShowHowCore

/// Owns the one walkthrough session: its state machine, agent loop and task.
/// Every entry point (panel, menu bar, hotkeys, voice, MCP, URL scheme) calls
/// into here, so they all follow the same rules.
@MainActor
final class SessionController: HandoffDelegate {
    static let shared = SessionController()

    let model = AppModel.shared
    let settings = AppSettings.shared
    let panel = FloatingPanelController()
    let narrator = Narrator()
    let takeover = TakeoverMonitor()
    private(set) lazy var host = MacAgentHost(controller: self)
    let store = SessionLogStore(root: AppSettings.sessionsDirectory)

    private var machine = SessionStateMachine()
    private var loop: AgentLoop?
    private var recorder: SessionRecorder?
    private var runTask: Task<Void, Never>?
    private var screenRecorder: ScreenRecorder?
    private var queue: [QueuedRequest] = []
    private(set) var currentID: String?
    private var hideTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    private init() {
        takeover.onTakeover = { [weak self] in
            guard let self, self.model.mode == .doIt, self.model.phase == .running else { return }
            self.pause(.takeover)
            self.model.append(.system, "You moved the mouse, so I paused. Press Resume when you want me to continue.")
            self.panel.show(expanded: true)
        }
        model.recent = store.recent(limit: 8)
    }

    // MARK: State

    @discardableResult
    private func transition(_ event: SessionEvent) -> Bool {
        guard machine.handle(event) else { return false }
        model.phase = machine.phase
        return true
    }

    var isActive: Bool { machine.phase.isActive }

    // MARK: Queue and start

    /// Queues a walkthrough. Nothing is captured until the user presses Start.
    @discardableResult
    func requestWalkthrough(task: String, context: String?, app: String?, mode: AgentMode?, source: SessionSource) -> String {
        let request = QueuedRequest(id: UUID().uuidString, task: task, context: context, app: app, mode: mode, source: source)
        queue.append(request)
        showNextQueued()
        return request.id
    }

    private func showNextQueued() {
        guard !isActive || machine.phase == .queued, let next = queue.first else { return }
        model.queued = next
        transition(.queue)
        panel.show(expanded: true)
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Start (panel button, hotkey tap, menu, or `start_now`).
    func startQueued() {
        guard let request = model.queued else { return }
        queue.removeAll { $0.id == request.id }
        model.queued = nil
        begin(request)
    }

    /// A task typed or spoken with nothing queued.
    func startNew(task: String, source: SessionSource = .panel) {
        begin(QueuedRequest(id: UUID().uuidString, task: task, context: nil, app: nil, mode: nil, source: source))
    }

    private func begin(_ request: QueuedRequest) {
        if isActive && machine.phase != .queued { stop() }
        guard let apiKey = Keychain.apiKey() else {
            fail("Add your Anthropic API key in Settings > General first.")
            SettingsWindowController.shared.show(tab: .general)
            return
        }
        guard ScreenCapturer.hasPermission else {
            ScreenCapturer.requestPermission()
            fail("ShowHow needs Screen Recording permission to see your screen.")
            OnboardingWindowController.shared.show()
            return
        }
        if let app = request.app { Self.activate(appNamed: app) }

        var mode = request.mode ?? model.mode
        if mode == .doIt && !AXReader.isTrusted {
            mode = .guide
            model.attention = "Do-it mode needs Accessibility permission, so this walkthrough uses Guide mode."
        }

        let log = SessionLog(id: UUID(uuidString: request.id) ?? UUID(), task: request.task, context: request.context,
                             sourceLabel: request.source.label, mode: mode, model: settings.model.rawValue)
        let recorder = SessionRecorder(log: log, store: store)
        let client = ClaudeClient(transport: URLSessionLineTransport())
        let loop = AgentLoop(sender: client, apiKey: apiKey, config: settings.requestConfig, mode: mode, host: host, recorder: recorder)
        // One stream keeps events in order on the main actor.
        let (events, sink) = AsyncStream<AgentEvent>.makeStream()
        loop.onEvent = { sink.yield($0) }
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        self.loop = loop
        self.recorder = recorder
        currentID = log.id.uuidString

        ScreenCapturer.shared.maxLongEdge = CGFloat(settings.screenshotLongEdge)
        ScreenCapturer.shared.pinnedBundleID = settings.pinnedAppBundleID.nilIfEmpty
        model.resetForNewSession(title: log.title, source: request.source.label, mode: mode)
        model.append(.user, request.task)
        if machine.phase == .queued || !machine.phase.isActive {
            if machine.phase != .queued { transition(.reset) }
            transition(.start)
        }
        InputController.shared.reset()
        DisplayManager.shared.overlayModel.dimmed = false
        DisplayManager.shared.overlayModel.clear()
        panel.show(expanded: false)
        if model.recordThisSession { startRecording() }

        run { await loop.start(task: request.task, context: request.context) }
    }

    /// Runs a loop entry point after any previous one has fully unwound.
    private func run(_ body: @escaping () async -> AgentOutcome) {
        let previous = runTask
        hideTask?.cancel()
        runTask = Task { [weak self] in
            await previous?.value
            let outcome = await body()
            self?.finish(outcome)
        }
    }

    private func finish(_ outcome: AgentOutcome) {
        model.thinking = false
        DisplayManager.shared.overlayModel.thinkingDisplayID = nil
        switch outcome {
        case .cancelled:
            return // pause and stop already updated the state
        case .finished(let summary):
            if !summary.isEmpty { narrator.speak(Self.firstSentence(of: summary)) }
            transition(.finish)
            endSession()
        case .refused(let category, let message):
            let line = category.map { "Claude declined (\($0)): \(message)" } ?? message
            model.append(.system, line)
            model.attention = line
            transition(.fail(line))
            endSession()
        case .failed(let message):
            model.append(.system, message)
            model.attention = message
            transition(.fail(message))
            endSession()
        }
    }

    private func endSession() {
        takeover.stop()
        DisplayManager.shared.overlayModel.clear()
        stopRecording()
        recorder?.update { $0.endedAt = Date() }
        if let log = recorder?.log, log.documentRequested { exportWriteup(log) }
        model.recent = store.recent(limit: 8)
        scheduleHide()
        showNextQueued()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, !self.isActive, self.model.writeupPreview == nil, !self.panel.isPinnedOpen else { return }
            self.panel.hide()
        }
    }

    private func fail(_ message: String) {
        model.attention = message
        model.append(.system, message)
        panel.show(expanded: true)
    }

    // MARK: Pause, resume, stop

    func pause(_ reason: PauseReason = .user) {
        guard transition(.pause(reason)) else { return }
        runTask?.cancel()
        InputController.shared.halt()
        takeover.stop()
        narrator.stop()
        model.thinking = false
        DisplayManager.shared.overlayModel.dimmed = true
        DisplayManager.shared.overlayModel.thinkingDisplayID = nil
        recorder?.note(.system, "Paused (\(reason.rawValue))")
    }

    func resume(note: String? = nil) {
        guard let loop, transition(.resume) else { return }
        InputController.shared.reset()
        DisplayManager.shared.overlayModel.dimmed = false
        recorder?.note(.system, "Resumed")
        let text = note ?? "The session was paused and has now resumed. The screen may have changed."
        run { await loop.resume(note: text) }
    }

    func togglePause() {
        switch machine.phase {
        case .running: pause(.user)
        case .paused: resume()
        case .queued: startQueued()
        default: break
        }
    }

    /// Stop: ends the session (or drops the queued request).
    func stop() {
        if machine.phase == .queued, let queued = model.queued {
            queue.removeAll { $0.id == queued.id }
            model.queued = nil
            transition(.cancel)
            showNextQueued()
            if !isActive { panel.hide() }
            return
        }
        guard isActive else { return }
        runTask?.cancel()
        InputController.shared.halt()
        narrator.stop()
        transition(.cancel)
        recorder?.update { $0.outcome = $0.outcome ?? "Stopped by the user." }
        model.append(.system, "Stopped.")
        endSession()
    }

    /// Kill switch (⌘⇧Escape): stop everything at once.
    func kill() {
        InputController.shared.halt()
        VoiceController.shared.stopListening(deliver: false)
        host.answerConfirmation(false)
        stop()
        DisplayManager.shared.overlayModel.clear()
    }

    // MARK: Messages from the user

    /// Text typed in the panel or a finished voice transcript.
    func send(_ raw: String, source: SessionSource = .panel) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch machine.phase {
        case .running, .paused(.whiteboard), .paused(.question):
            model.append(.user, text)
            if host.actionMonitor.isWaiting {
                host.actionMonitor.resolve(.question(text))
            } else if case .paused = machine.phase, let loop {
                // At the whiteboard: answer on the board, then wait again.
                let previous = runTask
                runTask = Task { [weak self] in
                    await previous?.value
                    let outcome = await loop.resume(note: "The user is at the whiteboard and says: \(text)")
                    if case .cancelled = outcome { return }
                    if case .finished = outcome { return }
                    self?.finish(outcome)
                }
            } else {
                loop?.enqueueUserMessage(text)
            }
        case .paused:
            model.append(.user, text)
            loop?.enqueueUserMessage(text)
            resume(note: "The session was paused and has now resumed. The user's message follows.")
        case .queued:
            startQueued()
            model.append(.user, text)
            loop?.enqueueUserMessage(text)
        case .done, .failed:
            if let loop, machine.phase == .done {
                model.append(.user, text)
                transition(.start)
                InputController.shared.reset()
                panel.show(expanded: false)
                run { await loop.followUp(text) }
            } else {
                startNew(task: text, source: source)
            }
        case .idle:
            startNew(task: text, source: source)
        }
    }

    func next() { host.actionMonitor.resolve(.next) }
    func skip() { host.actionMonitor.resolve(.skip) }

    func setMode(_ mode: AgentMode) {
        if mode == .doIt && !AXReader.isTrusted {
            AXReader.requestTrust()
            model.attention = "Turn on Accessibility for ShowHow in System Settings to use Do-it mode."
            model.mode = .guide
            return
        }
        model.mode = mode
        loop?.setMode(mode)
        if mode == .guide { takeover.stop() }
    }

    // MARK: Whiteboard

    func whiteboardOpened() {
        model.whiteboardOpen = true
        if machine.phase == .running { pause(.whiteboard) }
    }

    func whiteboardClosed() {
        model.whiteboardOpen = false
        if case .paused(.whiteboard) = machine.phase {
            runTask?.cancel()
            resume(note: "The whiteboard is closed. This is the screen again; carry on with the walkthrough from where it was.")
        }
    }

    // MARK: Documentation and recording

    /// Turns on the write-up for the running session.
    func enableDocumentation(record: Bool) -> String {
        guard let recorder else { return "There is no session to document." }
        recorder.update {
            $0.documentRequested = true
            $0.recordRequested = $0.recordRequested || record
        }
        model.documenting = true
        if record { startRecording() }
        let folder = settings.documentsURL.path
        return "Documentation is on. A Markdown write-up with annotated screenshots of every step (including earlier ones) will be saved to \(folder) when the walkthrough ends\(record ? ", with a screen recording" : "")."
    }

    private func startRecording() {
        guard screenRecorder == nil, let recorder else { return }
        let displayID = DisplayManager.shared.focusedWindowDisplayID ?? DisplayManager.shared.mouseDisplayID ?? CGMainDisplayID()
        let url = store.folder(for: recorder.log.id).appendingPathComponent("recording.mov")
        let screenRecorder = ScreenRecorder()
        self.screenRecorder = screenRecorder
        model.recording = true
        Task {
            do {
                try await screenRecorder.start(displayID: displayID, url: url)
                recorder.update {
                    $0.recordRequested = true
                    $0.recordingFile = url.lastPathComponent
                    $0.recordingStartedAt = Date()
                }
            } catch {
                self.model.recording = false
                self.screenRecorder = nil
                self.model.append(.system, "Recording could not start: \(error.localizedDescription)")
            }
        }
    }

    private func stopRecording() {
        guard let screenRecorder else { return }
        self.screenRecorder = nil
        model.recording = false
        Task { await screenRecorder.stop() }
    }

    func setRecordThisSession(_ on: Bool) {
        model.recordThisSession = on
        if machine.phase == .running || machine.phase.isActive && machine.phase != .queued {
            if on { startRecording() } else { stopRecording() }
        }
    }

    /// Document last walkthrough (menu, panel, MCP, URL scheme).
    func documentLast() {
        guard let log = recorder?.log ?? store.recent(limit: 1).first else {
            fail("There is no recent walkthrough to document.")
            return
        }
        if isActive, log.id.uuidString == currentID {
            _ = enableDocumentation(record: false)
            model.append(.system, "I'll write this up when the walkthrough ends.")
            panel.show(expanded: true)
            return
        }
        exportWriteup(log)
    }

    @discardableResult
    func exportWriteup(_ log: SessionLog) -> Task<URL?, Never> {
        model.exporting = true
        panel.show(expanded: true)
        let exporter = WriteupExporter(store: store, settings: settings)
        return Task {
            defer { self.model.exporting = false }
            do {
                // Wait for a recording to finish writing before copying it.
                try? await Task.sleep(nanoseconds: 500_000_000)
                let staged = try await exporter.stage(log)
                if self.settings.previewBeforeSaving {
                    self.model.writeupPreview = staged
                    self.panel.show(expanded: true)
                    return nil
                }
                return self.saveWriteup(staged)
            } catch {
                self.fail("The write-up failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    @discardableResult
    func saveWriteup(_ preview: WriteupPreview, reveal: Bool = true) -> URL? {
        do {
            let destination = try WriteupExporter.move(staging: preview.stagingFolder, into: settings.documentsURL)
            let id = preview.sessionID
            if var log = try? store.load(id) {
                log.writeupPath = destination.path
                try? store.save(log)
                if recorder?.log.id == id { recorder?.update { $0.writeupPath = destination.path } }
            }
            model.writeupPreview = nil
            model.documenting = false
            model.append(.system, "Saved the write-up to \(destination.path).")
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([destination.appendingPathComponent("README.md")]) }
            return destination
        } catch {
            fail("Could not save the write-up: \(error.localizedDescription)")
            return nil
        }
    }

    func discardWriteup() {
        if let preview = model.writeupPreview { try? FileManager.default.removeItem(at: preview.stagingFolder) }
        model.writeupPreview = nil
    }

    func exportPDF(_ preview: WriteupPreview) {
        Task {
            do {
                let url = try await PDFExporter.export(folder: preview.stagingFolder, markdown: preview.markdown)
                model.append(.system, "Made \(url.lastPathComponent); it will be saved with the write-up.")
            } catch {
                fail("PDF export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Events from the loop

    private func handle(_ event: AgentEvent) {
        switch event {
        case .turnStarted:
            model.thinking = true
            model.streamingText = ""
            DisplayManager.shared.overlayModel.thinkingDisplayID = loop?.activeDisplayID
        case .textDelta(let delta):
            model.streamingText += delta
        case .progressNote(let note):
            model.progressNote = note
        case .assistantText(let text):
            model.streamingText = ""
            model.append(.assistant, text)
            if !model.waitingForUser { narrator.speakIfAnswer(text) }
        case .toolActivity(let line):
            model.progressNote = line
        case .usage:
            if let loop { model.sessionCost = loop.meter }
            model.thinking = false
            DisplayManager.shared.overlayModel.thinkingDisplayID = nil
        case .modeChanged(let mode):
            model.mode = mode
        case .stepStarted(let step, let total):
            model.step = step
            if total > 0 { model.totalSteps = total }
        case .userMessageDelivered:
            break // shown when sent
        case .warning(let message):
            model.append(.note, message)
        }
    }

    // MARK: HandoffDelegate (MCP)

    func requestWalkthrough(task: String, context: String?, app: String?, mode: AgentMode?, client: String) async -> String {
        requestWalkthrough(task: task, context: context, app: app, mode: mode, source: .mcp(client: client))
    }

    func startNow(sessionID: String) async -> Result<String, HandoffError> {
        guard settings.allowStartNow else {
            return .failure(HandoffError("Starting without the user is turned off in ShowHow (Settings > Integrations). The walkthrough is waiting for them to press Start."))
        }
        guard model.queued?.id == sessionID else { return .failure(HandoffError("That walkthrough is not queued.")) }
        startQueued()
        return .success("Started.")
    }

    func pause(sessionID: String) async -> Result<String, HandoffError> {
        guard sessionID == currentID, machine.phase == .running else { return .failure(HandoffError("That walkthrough is not running.")) }
        pause(.user)
        return .success("Paused.")
    }

    func resume(sessionID: String) async -> Result<String, HandoffError> {
        guard sessionID == currentID, case .paused = machine.phase else { return .failure(HandoffError("That walkthrough is not paused.")) }
        resume()
        return .success("Resumed.")
    }

    func cancel(sessionID: String) async -> Result<String, HandoffError> {
        if let index = queue.firstIndex(where: { $0.id == sessionID }) {
            if model.queued?.id == sessionID { stop() } else { queue.remove(at: index) }
            return .success("Cancelled.")
        }
        guard sessionID == currentID, isActive else { return .failure(HandoffError("That walkthrough is not active.")) }
        stop()
        return .success("Stopped.")
    }

    func status(sessionID: String) async -> Result<JSONValue, HandoffError> {
        if let queued = queue.first(where: { $0.id == sessionID }) {
            return .success(["session_id": .string(sessionID), "state": "queued", "task": .string(queued.task),
                             "note": "Waiting for the user to press Start."])
        }
        if sessionID == currentID {
            var status: [String: JSONValue] = [
                "session_id": .string(sessionID),
                "state": .string(Self.stateName(machine.phase)),
                "task": .string(model.taskTitle),
                "mode": .string(model.mode.rawValue),
                "step": .number(Double(model.step)),
                "total_steps": .number(Double(model.totalSteps)),
                "last_narration": .string(model.instruction),
                "documenting": .bool(model.documenting),
            ]
            if let last = model.transcript.last(where: { $0.role == .assistant }) { status["last_message"] = .string(last.text) }
            if let path = recorder?.log.writeupPath { status["writeup_path"] = .string(path) }
            if case .failed(let message) = machine.phase { status["error"] = .string(message) }
            return .success(.object(status))
        }
        if let id = UUID(uuidString: sessionID), let log = try? store.load(id) {
            var status: [String: JSONValue] = ["session_id": .string(sessionID), "state": "done", "task": .string(log.task),
                                               "steps": .number(Double(log.steps.count))]
            if let outcome = log.outcome { status["outcome"] = .string(outcome) }
            if let path = log.writeupPath { status["writeup_path"] = .string(path) }
            return .success(.object(status))
        }
        return .failure(HandoffError("No session with that id."))
    }

    func documentSession(sessionID: String, record: Bool) async -> Result<String, HandoffError> {
        if sessionID == currentID, isActive {
            return .success(enableDocumentation(record: record))
        }
        guard let id = UUID(uuidString: sessionID), let log = try? store.load(id) else {
            return .failure(HandoffError("No session log with that id. Logs are kept for \(settings.logRetentionDays) days."))
        }
        let task = exportWriteup(log)
        if let url = await task.value { return .success(url.appendingPathComponent("README.md").path) }
        if let preview = model.writeupPreview {
            return .success("The write-up \"\(preview.title)\" is ready for the user to review in ShowHow; it is saved to \(settings.documentsURL.path) when they press Save.")
        }
        return .failure(HandoffError("The write-up could not be made."))
    }

    func openWhiteboard() async -> Result<String, HandoffError> {
        WhiteboardController.shared.open()
        return .success("The whiteboard is open on the user's screen.")
    }

    func whiteboardDraw(_ items: [WhiteboardItemSpec], clear: Bool) async -> Result<String, HandoffError> {
        if !WhiteboardController.shared.isOpen { WhiteboardController.shared.open() }
        do {
            try WhiteboardController.shared.draw(items, clear: clear)
            return .success("Drawn \(items.count) item(s).")
        } catch {
            return .failure(HandoffError(error.localizedDescription))
        }
    }

    // MARK: Helpers

    static func stateName(_ phase: SessionPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .queued: return "queued"
        case .running: return "running"
        case .paused: return "paused"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    static func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.firstIndex(where: { ".!?\n".contains($0) }) {
            return String(trimmed[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(trimmed.prefix(200))
    }

    /// Brings the named app to the front, launching it if needed.
    static func activate(appNamed name: String) {
        let lower = name.lowercased()
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.lowercased() == lower || $0.bundleIdentifier?.lowercased() == lower }) {
            running.activate(options: [])
            return
        }
        let candidates = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for dir in candidates {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                return
            }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
}
