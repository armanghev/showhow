import AppKit
import ShowHowCore

@main
enum ShowHowMain {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        _ = DisplayManager.shared
        StatusItemController.shared.install()
        HotkeyManager.shared.install()
        _ = SessionController.shared
        if settings.mcpEnabled { MCPHTTPServer.shared.start() }
        Updater.shared.start()

        // Session logs expire unless they became write-ups.
        let removed = SessionController.shared.store.purge(olderThan: settings.logRetentionDays)
        if removed > 0 { AppModel.shared.recent = SessionController.shared.store.recent(limit: 8) }

        if !settings.onboardingDone || !Keychain.hasAPIKey || !ScreenCapturer.hasPermission {
            OnboardingWindowController.shared.show()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SessionController.shared.kill()
        MCPHTTPServer.shared.stop()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SessionController.shared.panel.summon()
        return false
    }

    /// `showhow://` links from Shortcuts, Raycast, a browser or `open`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = URLCommand(url: url) else { continue }
            handle(command)
        }
    }

    private func handle(_ command: URLCommand) {
        let session = SessionController.shared
        switch command {
        case .walkthrough(let task, let context, let app, let mode, let autoStart):
            session.requestWalkthrough(task: task, context: context, app: app, mode: mode, source: .urlScheme)
            if autoStart && settings.allowStartNow { session.startQueued() }
        case .pause: session.pause()
        case .resume: session.resume()
        case .stop: session.stop()
        case .documentLast: session.documentLast()
        case .whiteboard: WhiteboardController.shared.open()
        case .summon: session.panel.summon()
        }
    }

    /// An app menu and an Edit menu, so ⌘C, ⌘V, ⌘Z and ⌘A work in the panel.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ShowHow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }
}
