import AppKit
import MacHelperCore

/// The agent loop's view of the Mac: ScreenCaptureKit for eyes, the overlay
/// for pointing, CGEvent for hands, the Accessibility API for element names.
@MainActor
final class MacAgentHost: AgentHost {
    private unowned let controller: SessionController
    private let model = AppModel.shared
    private let displaysManager = DisplayManager.shared
    let actionMonitor = UserActionMonitor()
    private var confirmation: CheckedContinuation<Bool, Never>?

    init(controller: SessionController) {
        self.controller = controller
    }

    // MARK: Displays and capture

    func displays() async -> [DisplayInfo] {
        displaysManager.displays
    }

    func preferredDisplayID() async -> UInt32? {
        displaysManager.focusedWindowDisplayID ?? displaysManager.mouseDisplayID
    }

    func capture(displayID: UInt32) async throws -> Screenshot {
        model.thinking = true
        return try await ScreenCapturer.shared.capture(displayID: displayID)
    }

    func captureRegion(displayID: UInt32, region: CGRect) async throws -> Screenshot {
        try await ScreenCapturer.shared.captureRegion(displayID: displayID, region: region)
    }

    func visibleElements(displayID: UInt32) async -> [UIElementSummary] {
        let displays = displaysManager.displays
        return await Task.detached(priority: .userInitiated) {
            AXReader.visibleElements(displays: displays).filter { $0.displayID == displayID }
        }.value
    }

    func cursorLocation() async -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Overlay and panel

    func show(_ annotations: [Annotation], replace: Bool) async {
        displaysManager.overlayModel.show(annotations, replace: replace)
        if let target = annotations.last {
            controller.panel.avoid(target.footprint, on: target.displayID)
        }
    }

    func clearAnnotations() async {
        displaysManager.overlayModel.clear()
    }

    func setInstruction(_ instruction: String, detail: String) async {
        model.instruction = instruction
        model.detail = detail
        model.append(.assistant, detail.isEmpty ? instruction : "\(instruction)\n\(detail)")
        controller.narrator.speak(detail.isEmpty ? instruction : "\(instruction). \(detail)")
    }

    func setProgress(step: Int, total: Int) async {
        model.step = step
        if total > 0 { model.totalSteps = total }
    }

    func waitForUser(expected: String, advanceOn: AdvanceTrigger) async -> UserEvent {
        model.thinking = false
        displaysManager.overlayModel.thinkingDisplayID = nil
        model.waitingForUser = true
        defer { model.waitingForUser = false }
        return await actionMonitor.wait(expected: expected, advanceOn: advanceOn)
    }

    func confirm(_ summary: String) async -> Bool {
        model.thinking = false
        controller.narrator.speak("Before I do this, please confirm. \(summary)")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                answerConfirmation(false)
                confirmation = c
                model.pendingConfirmation = PendingConfirmation(summary: summary)
                controller.panel.show(expanded: true)
                if Task.isCancelled { answerConfirmation(false) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answerConfirmation(false) }
        }
    }

    /// Called by the panel's Allow / Don't buttons.
    func answerConfirmation(_ approved: Bool) {
        guard let c = confirmation else { return }
        confirmation = nil
        model.pendingConfirmation = nil
        c.resume(returning: approved)
    }

    // MARK: Do-it mode

    func perform(_ action: ComputerAction, mapping: ScreenshotMapping) async throws {
        if let pinned = AppSettings.shared.pinnedAppBundleID.nilIfEmpty,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != pinned
        {
            throw HandoffError("This session is pinned to one app, and that app is not in front. Ask the user to switch back to it.")
        }
        controller.takeover.start()
        try await InputController.shared.perform(action, mapping: mapping)
    }

    func focusedElementIsSecure() async -> Bool {
        await Task.detached { AXReader.focusedElementIsSecure() }.value
    }

    // MARK: Whiteboard

    func whiteboardIsOpen() async -> Bool {
        WhiteboardController.shared.isOpen
    }

    func whiteboardSnapshot() async throws -> Screenshot {
        try WhiteboardController.shared.snapshot()
    }

    func whiteboardDraw(_ items: [WhiteboardItemSpec], clear: Bool) async throws {
        try WhiteboardController.shared.draw(items, clear: clear)
    }

    // MARK: Documentation

    func enableDocumentation(record: Bool) async -> String {
        controller.enableDocumentation(record: record || model.recordThisSession)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
