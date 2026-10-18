import AVFoundation
import KeyboardShortcuts
import MacHelperCore
import ServiceManagement
import SwiftUI

// MARK: General

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var apiKey = Keychain.apiKey() ?? ""
    @State private var keySaved = Keychain.hasAPIKey
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                SecureField("Anthropic API key", text: $apiKey, prompt: Text("sk-ant-…"))
                    .onSubmit(saveKey)
                HStack {
                    Text(keySaved ? "Saved in your Keychain." : "Stored in your Keychain, never in a file.")
                        .font(DesignTokens.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(DesignTokens.caption)
                    Button("Save", action: saveKey).disabled(apiKey.isEmpty)
                }
            } header: {
                Text("Claude")
            }
            Section {
                Picker("Model", selection: $settings.modelRaw) {
                    ForEach(ClaudeModel.allCases) { model in
                        VStack(alignment: .leading) { Text(model.displayName) }.tag(model.rawValue)
                    }
                }
                Text(settings.model.blurb).font(DesignTokens.caption).foregroundStyle(.secondary)
                Picker("Effort", selection: $settings.effortRaw) {
                    ForEach(Effort.allCases) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
                Picker("Default mode", selection: $settings.defaultModeRaw) {
                    ForEach(AgentMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: settings.defaultModeRaw) { _, raw in
                    if !AppModel.shared.phase.isActive, let mode = AgentMode(rawValue: raw) { AppModel.shared.mode = mode }
                }
            } footer: {
                Text("Guide mode points and you click. Do-it mode clicks for you and needs Accessibility permission.")
                    .font(DesignTokens.caption).foregroundStyle(.secondary)
            }
            Section("Screenshots") {
                Picker("Detail", selection: $settings.screenshotLongEdge) {
                    Text("Standard (1568 px)").tag(1568.0)
                    Text("High (2048 px)").tag(2048.0)
                    Text("Maximum (2576 px)").tag(2576.0)
                }
                Text("Higher detail helps on dense screens and costs more per step.")
                    .font(DesignTokens.caption).foregroundStyle(.secondary)
                Toggle("Trim old screenshots from long sessions", isOn: $settings.contextEditing)
                Toggle("Summarize very long sessions on the server", isOn: $settings.compaction)
            }
            Section("App") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show session cost in the menu", isOn: $settings.showCostInMenu)
                Button("Show permissions…") { OnboardingWindowController.shared.show() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func saveKey() {
        keySaved = Keychain.setAPIKey(apiKey)
        if keySaved { AppModel.shared.attention = nil }
    }
}

// MARK: Shortcuts

struct ShortcutSettingsView: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                ForEach(KeyboardShortcuts.Name.macHelperShortcuts, id: \.rawValue) { name in
                    VStack(alignment: .leading, spacing: 2) {
                        KeyboardShortcuts.Recorder(name.title, name: name) { _ in refresh += 1 }
                        if let conflict = HotkeyManager.conflict(for: name) {
                            Label(conflict, systemImage: "exclamationmark.triangle.fill")
                                .font(DesignTokens.caption)
                                .foregroundStyle(DesignTokens.warning)
                                .id(refresh)
                        }
                    }
                }
            } footer: {
                Text("Hold the summon shortcut to talk when voice is on. Next step defaults to ⌃⌥→ because ⌥→ already moves by word in text fields.")
                    .font(DesignTokens.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore defaults") {
                    KeyboardShortcuts.reset(KeyboardShortcuts.Name.macHelperShortcuts)
                    refresh += 1
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Voice

struct VoiceSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var authorized = VoiceController.isAuthorized

    var body: some View {
        Form {
            Section {
                Toggle("Voice", isOn: Binding(get: { settings.voiceEnabled }, set: { MenuActions.setVoice($0) }))
                Toggle("Read instructions aloud", isOn: $settings.speakNarration)
                Picker("Voice", selection: $settings.voiceIdentifier) {
                    Text("System default").tag("")
                    ForEach(Narrator.voices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                    }
                }
                Slider(value: $settings.speechRate, in: 0.3...0.7) { Text("Speed") }
                Button("Preview") {
                    SessionController.shared.narrator.say("Click Insert in the menu bar, then choose Pivot Table.")
                }
            } footer: {
                Text("Speech recognition runs on your Mac when your language supports it. The listening badge is always shown while the microphone is on.")
                    .font(DesignTokens.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                HStack {
                    PermissionDot(granted: authorized)
                    Text("Microphone and Speech Recognition")
                    Spacer()
                    if !authorized {
                        Button("Allow") { Task { authorized = await VoiceController.requestAuthorization() } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Integrations

struct IntegrationSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                Toggle("Let Claude Desktop and Claude Code hand walkthroughs to Mac Helper", isOn: $settings.mcpEnabled)
                    .onChange(of: settings.mcpEnabled) { _, on in
                        if on { MCPHTTPServer.shared.start() } else { MCPHTTPServer.shared.stop() }
                    }
                LabeledContent("Address", value: MCPHTTPServer.shared.endpoint?.url ?? "Not running")
                    .textSelection(.enabled)
                Toggle("Allow them to start a walkthrough without me pressing Start", isOn: $settings.allowStartNow)
            } header: {
                Text("MCP hand-off")
            } footer: {
                Text("A hand-off only queues. Nothing on your screen is captured until you press Start, unless you allow it above.")
                    .font(DesignTokens.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code") {
                HStack {
                    Text("Adds Mac Helper as an MCP server.")
                    Spacer()
                    Button("Copy Claude Code command") {
                        status = IntegrationInstaller.copyClaudeCodeCommand() ? "Copied. Paste it in Terminal." : "Start the server first."
                    }
                }
            }
            Section("Claude Desktop") {
                HStack {
                    Text("Writes a mac-helper entry to Claude Desktop's config.")
                    Spacer()
                    Button("Install in Claude Desktop") {
                        do {
                            try IntegrationInstaller.installInClaudeDesktop()
                            status = "Installed. Restart Claude Desktop to load it."
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                }
            }
            if !status.isEmpty {
                Text(status).font(DesignTokens.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts, Raycast and links") {
                Text("machelper://walkthrough?task=Make%20a%20pivot%20table&app=Numbers")
                    .font(DesignTokens.mono)
                    .textSelection(.enabled)
                Text("Also: machelper://pause, resume, stop, document-last, whiteboard, summon.")
                    .font(DesignTokens.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Documentation

struct DocumentationSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Save write-ups in") {
                    HStack {
                        Text(settings.documentsURL.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Polish the text with Claude (text only, no screenshots)", isOn: $settings.polishWriteups)
                Toggle("Show a preview before saving", isOn: $settings.previewBeforeSaving)
                Toggle("Record the screen by default", isOn: $settings.recordByDefault)
            } footer: {
                Text("Say \"document this\" at any point, or use Document last walkthrough in the menu bar. Each write-up is a folder with README.md and annotated images, so it opens cleanly in Obsidian, GitHub or Xcode.")
                    .font(DesignTokens.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.documentsURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { settings.documentsFolder = url.path }
    }
}

// MARK: Privacy

struct PrivacySettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var deleted: Int?

    var body: some View {
        Form {
            Section {
                PermissionsList()
            } header: {
                Text("Permissions")
            }
            Section {
                Picker("Keep session logs for", selection: $settings.logRetentionDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                Toggle("Blur password fields in write-ups", isOn: $settings.blurPasswordFields)
                HStack {
                    Button("Show logs in Finder") { NSWorkspace.shared.open(AppSettings.sessionsDirectory) }
                    Button("Delete logs now") {
                        deleted = SessionController.shared.store.deleteAll()
                        AppModel.shared.recent = SessionController.shared.store.recent(limit: 8)
                    }
                    if let deleted { Text("Deleted \(deleted).").font(DesignTokens.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Session logs")
            } footer: {
                Text("Each session keeps its screenshots, actions and narration on this Mac so you can review it or write it up. Logs that became write-ups are kept.")
                    .font(DesignTokens.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Only see and act in", selection: $settings.pinnedAppBundleID) {
                    Text("Any app").tag("")
                    ForEach(Self.runningApps) { app in Text(app.name).tag(app.id) }
                }
            } header: {
                Text("Scope")
            } footer: {
                Text("When set, screenshots include only that app's windows and Do-it mode acts only while it is in front.")
                    .font(DesignTokens.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    struct AppChoice: Identifiable {
        var id: String
        var name: String
    }

    static var runningApps: [AppChoice] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { AppChoice(id: $0, name: app.localizedName ?? $0) } }
            .sorted { $0.name < $1.name }
    }
}
