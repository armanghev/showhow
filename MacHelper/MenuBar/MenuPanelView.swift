import KeyboardShortcuts
import MacHelperCore
import SwiftUI

/// One action row in the menu panel.
private struct MenuRow: Identifiable {
    let id: String
    var title: String
    var symbol: String
    var shortcut: String?
    var indent = false
    var action: () -> Void
}

struct MenuPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MenuPanelState
    let controller: MenuPanelController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, DesignTokens.space2)
            actions
            Divider().padding(.horizontal, DesignTokens.space2)
            toggles
            Divider().padding(.horizontal, DesignTokens.space2)
            footer
        }
        .frame(width: MenuPanelController.width)
        .background(VisualEffectBackground(material: .popover, cornerRadius: DesignTokens.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous)
                .strokeBorder(Color.primary.opacity(DesignTokens.increaseContrast ? 0.5 : 0.1), lineWidth: 1)
        )
        .scaleEffect(state.visible ? 1 : 0.96, anchor: .top)
        .opacity(state.visible ? 1 : 0)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onChange(of: state.visible) { _, visible in if visible { focused = true } }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { activateSelection(); return .handled }
        .onKeyPress(.escape) { controller.close(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mac Helper menu")
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space2) {
            HStack(spacing: DesignTokens.space2) {
                StatusDot(phase: model.phase)
                Text(model.headline)
                    .font(DesignTokens.bodyEmphasis)
                    .lineLimit(2)
                Spacer(minLength: DesignTokens.space2)
                primaryButton
            }
            if model.phase.isActive && model.phase != .queued {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(DesignTokens.accent)
                    .accessibilityLabel("Progress")
            }
            if let attention = model.attention {
                Label(attention, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.caption)
                    .foregroundStyle(DesignTokens.warning)
                    .lineLimit(3)
            }
        }
        .padding(DesignTokens.space3)
    }

    @ViewBuilder
    private var primaryButton: some View {
        let session = SessionController.shared
        switch model.phase {
        case .queued:
            Button("Start") { session.startQueued(); controller.close() }.buttonStyle(PrimaryPillStyle())
        case .running:
            Button("Pause") { session.pause() }.buttonStyle(PrimaryPillStyle(tint: .orange))
        case .paused:
            HStack(spacing: 4) {
                Button("Resume") { session.resume() }.buttonStyle(PrimaryPillStyle())
                Button("Stop") { session.stop() }.buttonStyle(PrimaryPillStyle(tint: .secondary))
            }
        default:
            Button("Start") { session.panel.summon(); controller.close() }
                .buttonStyle(PrimaryPillStyle())
                .accessibilityHint("Opens the panel to type or say what you want to do")
        }
    }

    private var rows: [MenuRow] {
        let session = SessionController.shared
        var rows: [MenuRow] = [
            MenuRow(id: "start", title: "Start walkthrough…", symbol: "sparkles", shortcut: shortcut(.summon)) {
                session.panel.summon(); controller.close()
            },
            MenuRow(id: "document", title: "Document last walkthrough", symbol: "doc.text", shortcut: nil) {
                session.documentLast(); controller.close()
            },
            MenuRow(id: "whiteboard", title: model.whiteboardOpen ? "Close whiteboard" : "Open whiteboard", symbol: "scribble.variable",
                    shortcut: shortcut(.whiteboard)) {
                controller.close(); WhiteboardController.shared.toggle()
            },
            MenuRow(id: "recent", title: "Recent walkthroughs", symbol: state.recentExpanded ? "chevron.down" : "chevron.right", shortcut: nil) {
                withAnimation(DesignTokens.animation()) { state.recentExpanded.toggle() }
                DispatchQueue.main.async { controller.refit() }
            },
        ]
        if state.recentExpanded {
            if model.recent.isEmpty {
                rows.append(MenuRow(id: "recent-none", title: "None yet", symbol: "minus", shortcut: nil, indent: true) {})
            }
            for log in model.recent.prefix(6) {
                rows.append(MenuRow(id: log.id.uuidString, title: log.title, symbol: log.writeupPath == nil ? "clock" : "doc.richtext",
                                    shortcut: Self.relative(log.startedAt), indent: true) {
                    MenuActions.openRecent(log); controller.close()
                })
            }
        }
        return rows
    }

    private var actions: some View {
        VStack(spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button(action: row.action) {
                    HStack(spacing: DesignTokens.space2) {
                        Image(systemName: row.symbol)
                            .frame(width: 18)
                            .foregroundStyle(state.selection == index ? Color.white : Color.secondary)
                        Text(row.title).font(DesignTokens.body).lineLimit(1)
                        Spacer()
                        ShortcutHint(text: row.shortcut, highlighted: state.selection == index)
                    }
                    .padding(.leading, row.indent ? DesignTokens.space4 : 0)
                }
                .buttonStyle(MenuRowStyle(isSelected: state.selection == index))
                .onHover { inside in if inside { state.selection = index } else if state.selection == index { state.selection = nil } }
                .accessibilityLabel(row.title)
                .accessibilityHint(row.shortcut.map { "Shortcut \($0)" } ?? "")
            }
        }
        .padding(DesignTokens.space1 + 2)
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space2) {
            Picker("Mode", selection: Binding(get: { model.mode }, set: { SessionController.shared.setMode($0) })) {
                ForEach(AgentMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Mode")
            Toggle(isOn: Binding(get: { model.voiceOn }, set: { MenuActions.setVoice($0) })) {
                Label("Voice", systemImage: "waveform")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Toggle(isOn: Binding(get: { model.recordThisSession }, set: { SessionController.shared.setRecordThisSession($0) })) {
                Label("Record this session", systemImage: "record.circle")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .font(DesignTokens.body)
        .padding(DesignTokens.space3)
    }

    private var footer: some View {
        HStack {
            if AppSettings.shared.showCostInMenu {
                Text("Session \(model.sessionCost.formatted)")
                    .font(DesignTokens.caption)
                    .foregroundStyle(.secondary)
                    .help("Estimated from token usage")
            }
            Spacer()
            Button { controller.close(); SettingsWindowController.shared.show() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(DesignTokens.caption)
        }
        .padding(.horizontal, DesignTokens.space3)
        .padding(.vertical, DesignTokens.space2)
    }

    // MARK: Keyboard

    private func move(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        if let current = state.selection {
            state.selection = (current + delta + count) % count
        } else {
            state.selection = delta > 0 ? 0 : count - 1
        }
    }

    private func activateSelection() {
        guard let index = state.selection, rows.indices.contains(index) else { return }
        rows[index].action()
    }

    private func shortcut(_ name: KeyboardShortcuts.Name) -> String? {
        KeyboardShortcuts.getShortcut(for: name).map { "\($0)" }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
