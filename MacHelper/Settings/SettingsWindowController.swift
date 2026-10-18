import AppKit
import SwiftUI

/// Settings with toolbar tabs, laid out like Apple's own preference windows.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    enum Tab: Int, CaseIterable {
        case general, shortcuts, voice, integrations, documentation, privacy

        var title: String {
            switch self {
            case .general: return "General"
            case .shortcuts: return "Shortcuts"
            case .voice: return "Voice"
            case .integrations: return "Integrations"
            case .documentation: return "Documentation"
            case .privacy: return "Privacy"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .shortcuts: return "command"
            case .voice: return "waveform"
            case .integrations: return "puzzlepiece.extension"
            case .documentation: return "doc.richtext"
            case .privacy: return "hand.raised"
            }
        }
    }

    private let tabs = NSTabViewController()

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)

        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for tab in Tab.allCases {
            let controller = NSHostingController(rootView: Self.view(for: tab))
            controller.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.title = Tab.general.title
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func view(for tab: Tab) -> AnyView {
        let settings = AppSettings.shared
        switch tab {
        case .general: return AnyView(GeneralSettingsView(settings: settings))
        case .shortcuts: return AnyView(ShortcutSettingsView())
        case .voice: return AnyView(VoiceSettingsView(settings: settings))
        case .integrations: return AnyView(IntegrationSettingsView(settings: settings))
        case .documentation: return AnyView(DocumentationSettingsView(settings: settings))
        case .privacy: return AnyView(PrivacySettingsView(settings: settings))
        }
    }

    func show(tab: Tab? = nil) {
        if let tab {
            tabs.selectedTabViewItemIndex = tab.rawValue
            window?.title = tab.title
        }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
