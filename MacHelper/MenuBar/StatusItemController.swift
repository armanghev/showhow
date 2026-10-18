import AppKit
import Combine
import KeyboardShortcuts
import MacHelperCore

/// The menu bar item: an animated template glyph, a custom panel on left-click
/// and a compact native menu on right-click.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menuPanel = MenuPanelController()
    private var cancellables: Set<AnyCancellable> = []
    private var iconState: StatusIconState = .idle
    private var frame = 0
    private var animationTimer: Timer?

    func install() {
        guard let button = statusItem.button else { return }
        button.image = StatusIconRenderer.image(for: .idle, frame: 0)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel(StatusIconRenderer.accessibilityLabel(for: .idle))

        let model = AppModel.shared
        Publishers.CombineLatest3(model.$phase, model.$listening, model.$attention)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, listening, attention in
                MainActor.assumeIsolated { self?.update(phase: phase, listening: listening, attention: attention) }
            }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.restartAnimation() } }
            .store(in: &cancellables)
    }

    private func update(phase: SessionPhase, listening: Bool, attention: String?) {
        let state: StatusIconState
        if listening {
            state = .listening
        } else if attention != nil || { if case .failed = phase { return true } else { return false } }() {
            state = .attention
        } else {
            switch phase {
            case .running: state = .running
            case .paused: state = .paused
            default: state = .idle
            }
        }
        guard state != iconState else { return }
        iconState = state
        frame = 0
        statusItem.button?.setAccessibilityLabel(StatusIconRenderer.accessibilityLabel(for: state))
        restartAnimation()
    }

    private func restartAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        statusItem.button?.image = StatusIconRenderer.image(for: iconState, frame: 0)
        let frames = StatusIconRenderer.frameCount(for: iconState)
        guard frames > 1, !DesignTokens.reduceMotion else { return }
        let interval = iconState == .listening ? 0.12 : 0.15
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frame = (self.frame + 1) % frames
                self.statusItem.button?.image = StatusIconRenderer.image(for: self.iconState, frame: self.frame)
            }
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showNativeMenu()
        } else {
            guard let window = sender.window else { showNativeMenu(); return }
            let anchor = window.convertToScreen(sender.convert(sender.bounds, to: nil))
            if !menuPanel.toggle(below: anchor) { showNativeMenu() }
        }
    }

    // MARK: Right-click menu (and the fallback if the panel cannot show)

    private func showNativeMenu() {
        menuPanel.close()
        let menu = NSMenu()
        let model = AppModel.shared
        let session = SessionController.shared

        let header = NSMenuItem(title: model.headline, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        switch model.phase {
        case .queued: menu.addItem(item("Start", "play.fill") { session.startQueued() })
        case .running: menu.addItem(item("Pause", "pause.fill", shortcut: .pauseResume) { session.pause() })
        case .paused: menu.addItem(item("Resume", "play.fill", shortcut: .pauseResume) { session.resume() })
        default: menu.addItem(item("Start walkthrough…", "sparkles", shortcut: .summon) { session.panel.summon() })
        }
        if model.phase.isActive && model.phase != .queued {
            menu.addItem(item("Stop", "stop.fill", shortcut: .killSwitch) { session.stop() })
        }
        menu.addItem(item("Document last walkthrough", "doc.text") { session.documentLast() })
        menu.addItem(item("Open whiteboard", "scribble.variable", shortcut: .whiteboard) { WhiteboardController.shared.toggle() })

        let recent = NSMenuItem(title: "Recent walkthroughs", action: nil, keyEquivalent: "")
        recent.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        let submenu = NSMenu()
        if model.recent.isEmpty {
            let none = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for log in model.recent {
            submenu.addItem(item(log.title, log.writeupPath == nil ? "clock" : "doc.richtext") { MenuActions.openRecent(log) })
        }
        recent.submenu = submenu
        menu.addItem(recent)

        menu.addItem(.separator())
        let modeItem = NSMenuItem(title: "Do-it mode", action: nil, keyEquivalent: "")
        modeItem.state = model.mode == .doIt ? .on : .off
        menu.addItem(item(modeItem.title, nil, state: modeItem.state) { session.setMode(model.mode == .doIt ? .guide : .doIt) })
        menu.addItem(item("Voice", nil, state: model.voiceOn ? .on : .off) { MenuActions.setVoice(!model.voiceOn) })
        menu.addItem(item("Record this session", nil, state: model.recordThisSession ? .on : .off) { session.setRecordThisSession(!model.recordThisSession) })
        menu.addItem(.separator())
        if Updater.shared.isAvailable {
            menu.addItem(item("Check for Updates…", "arrow.down.circle") { Updater.shared.checkForUpdates() })
        }
        let settings = item("Settings…", "gearshape") { SettingsWindowController.shared.show() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = item("Quit Mac Helper", nil) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)

        if let button = statusItem.button {
            _ = menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    private func item(_ title: String, _ symbol: String?, shortcut: KeyboardShortcuts.Name? = nil,
                      state: NSControl.StateValue = .off, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.state = state
        if let shortcut, let value = KeyboardShortcuts.getShortcut(for: shortcut) {
            item.toolTip = "\(value)"
            item.setShortcut(for: shortcut)
        }
        return item
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Actions shared by the menu panel and the native menu.
@MainActor
enum MenuActions {
    static func openRecent(_ log: SessionLog) {
        if let path = log.writeupPath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path).appendingPathComponent("README.md"))
        } else {
            SessionController.shared.exportWriteup(log)
        }
    }

    static func setVoice(_ on: Bool) {
        AppModel.shared.voiceOn = on
        AppSettings.shared.voiceEnabled = on
        if on && !VoiceController.isAuthorized {
            Task { _ = await VoiceController.requestAuthorization() }
        }
        if !on { VoiceController.shared.stopListening(deliver: false) }
    }
}
