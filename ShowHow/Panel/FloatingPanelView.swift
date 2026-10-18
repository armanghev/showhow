import ShowHowCore
import SwiftUI

struct FloatingPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState
    let controller: FloatingPanelController

    var body: some View {
        Group {
            if state.expanded {
                ExpandedPanel(model: model, state: state, controller: controller)
            } else {
                PillView(model: model, controller: controller)
            }
        }
        .background(VisualEffectBackground(material: .hudWindow, cornerRadius: state.expanded ? DesignTokens.radiusLarge : 30))
        .overlay(
            RoundedRectangle(cornerRadius: state.expanded ? DesignTokens.radiusLarge : 30, style: .continuous)
                .strokeBorder(Color.primary.opacity(DesignTokens.increaseContrast ? 0.5 : 0.08), lineWidth: 1)
        )
        .onHover { controller.hoverChanged($0) }
    }
}

// MARK: Pill

private struct PillView: View {
    @ObservedObject var model: AppModel
    let controller: FloatingPanelController

    var body: some View {
        HStack(spacing: DesignTokens.space3) {
            ZStack {
                Circle().fill(DesignTokens.accent)
                Text(model.step > 0 ? "\(model.step)" : "•")
                    .font(DesignTokens.captionEmphasis)
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            .accessibilityLabel(model.step > 0 ? "Step \(model.step)" : "Walkthrough")

            VStack(alignment: .leading, spacing: 1) {
                Text(pillLine)
                    .font(DesignTokens.bodyEmphasis)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if model.thinking {
                    Text(model.progressNote.isEmpty ? "Looking at your screen…" : model.progressNote)
                        .font(DesignTokens.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if model.waitingForUser {
                    Text("Your turn. I'll notice when you're done.")
                        .font(DesignTokens.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if model.listening { MicBadge() }
            if model.documenting { Image(systemName: "doc.text").foregroundStyle(.secondary).help("Documenting this session") }
            PauseButton(model: model)
            Button { controller.setExpanded(true) } label: {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Expand panel")
        }
        .padding(.horizontal, DesignTokens.space4)
        .frame(width: FloatingPanelController.pillSize.width, height: FloatingPanelController.pillSize.height)
    }

    private var pillLine: String {
        if !model.instruction.isEmpty { return model.instruction }
        return model.headline
    }
}

private struct PauseButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.phase {
        case .running:
            Button { SessionController.shared.pause() } label: { Image(systemName: "pause.fill") }
                .buttonStyle(.borderless)
                .help("Pause")
                .accessibilityLabel("Pause walkthrough")
        case .paused:
            Button { SessionController.shared.resume() } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .help("Resume")
                .accessibilityLabel("Resume walkthrough")
        default:
            EmptyView()
        }
    }
}

private struct MicBadge: View {
    var body: some View {
        Image(systemName: "mic.fill")
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(Color.red))
            .accessibilityLabel("Microphone is on")
    }
}

// MARK: Expanded

private struct ExpandedPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState
    let controller: FloatingPanelController
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.space3) {
                        if let queued = model.queued, model.phase == .queued || !model.phase.isActive {
                            QueuedCard(request: queued)
                        }
                        if let confirmation = model.pendingConfirmation {
                            ConfirmationCard(confirmation: confirmation)
                        }
                        if let preview = model.writeupPreview {
                            WriteupPreviewCard(preview: preview)
                        }
                        if model.exporting {
                            HStack { ProgressView().controlSize(.small); Text("Writing up the walkthrough…").font(DesignTokens.caption) }
                        }
                        ForEach(model.transcript) { item in
                            TranscriptRow(item: item)
                        }
                        if !model.streamingText.isEmpty {
                            TranscriptRow(item: TranscriptItem(role: .assistant, text: model.streamingText))
                        }
                        if model.thinking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(model.progressNote.isEmpty ? "Thinking…" : model.progressNote)
                                    .font(DesignTokens.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(DesignTokens.space4)
                }
                .onChange(of: model.transcript.count) { _, _ in
                    withAnimation(DesignTokens.animation()) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if model.waitingForUser || (model.phase.isActive && !model.instruction.isEmpty) {
                Divider()
                stepBar
            }
            Divider()
            inputRow
            footer
        }
        .frame(width: FloatingPanelController.expandedSize.width, height: FloatingPanelController.expandedSize.height)
        .onChange(of: state.focusToken) { _, _ in fieldFocused = true }
        .onAppear { if state.focusToken > 0 { fieldFocused = true } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space2) {
            HStack(spacing: DesignTokens.space2) {
                StatusDot(phase: model.phase)
                Text(model.headline)
                    .font(DesignTokens.title)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if model.listening { MicBadge() }
                PauseButton(model: model)
                if model.phase.isActive && model.phase != .queued {
                    Button { SessionController.shared.stop() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.borderless)
                        .help("Stop the walkthrough")
                        .accessibilityLabel("Stop walkthrough")
                }
                Button { controller.setExpanded(false) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Collapse panel")
                if !model.phase.isActive {
                    Button { controller.hide() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Close panel")
                }
            }
            if model.phase.isActive && model.totalSteps > 0 {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(DesignTokens.accent)
            }
            HStack(spacing: DesignTokens.space2) {
                Picker("Mode", selection: Binding(get: { model.mode }, set: { SessionController.shared.setMode($0) })) {
                    ForEach(AgentMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("Guide: I point, you click. Do it: I click for you.")
                if !model.sourceLabel.isEmpty && model.sourceLabel != "You" {
                    Label("From \(model.sourceLabel)", systemImage: "arrow.down.forward.circle")
                        .font(DesignTokens.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.documenting {
                    Label("Documenting", systemImage: "doc.text").font(DesignTokens.caption).foregroundStyle(.secondary)
                }
                if model.recording {
                    Label("Recording", systemImage: "record.circle").font(DesignTokens.caption).foregroundStyle(.red)
                }
            }
            if let attention = model.attention {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DesignTokens.warning)
                    Text(attention).font(DesignTokens.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.attention = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                }
                .padding(DesignTokens.space2)
                .background(RoundedRectangle(cornerRadius: DesignTokens.radiusMedium).fill(DesignTokens.warning.opacity(0.12)))
            }
        }
        .padding(DesignTokens.space4)
    }

    private var stepBar: some View {
        HStack(spacing: DesignTokens.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.step > 0 ? "Step \(model.step)\(model.totalSteps > 0 ? " of \(model.totalSteps)" : "")" : "Current step")
                    .font(DesignTokens.captionEmphasis)
                    .foregroundStyle(.secondary)
                Text(model.instruction.isEmpty ? "Waiting for you" : model.instruction)
                    .font(DesignTokens.bodyEmphasis)
                    .lineLimit(2)
            }
            Spacer()
            if model.waitingForUser {
                Button("Skip") { SessionController.shared.skip() }
                    .buttonStyle(.borderless)
                Button("Next") { SessionController.shared.next() }
                    .buttonStyle(PrimaryPillStyle())
                    .help("I did it (⌃⌥→)")
            }
        }
        .padding(.horizontal, DesignTokens.space4)
        .padding(.vertical, DesignTokens.space2)
    }

    private var inputRow: some View {
        HStack(spacing: DesignTokens.space2) {
            if model.listening {
                Text(model.partialTranscript.isEmpty ? "Listening…" : model.partialTranscript)
                    .font(DesignTokens.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            } else {
                TextField(placeholder, text: $state.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.body)
                    .lineLimit(1...4)
                    .focused($fieldFocused)
                    .onSubmit { controller.submit() }
            }
            Button {
                VoiceController.shared.isListening ? VoiceController.shared.stopListening() : VoiceController.shared.startListening(handsFree: true)
            } label: {
                Image(systemName: model.listening ? "mic.fill" : "mic")
                    .foregroundStyle(model.listening ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(model.listening ? "Stop listening" : "Talk hands-free (or hold ⌥Space)")
            .accessibilityLabel(model.listening ? "Stop listening" : "Start listening")
            Button { controller.submit() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.borderless)
            .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, DesignTokens.space4)
        .padding(.vertical, DesignTokens.space3)
    }

    private var placeholder: String {
        switch model.phase {
        case .idle, .done, .failed: return "What do you want to do? e.g. \"Make a pivot table in Numbers\""
        case .queued: return "Add anything before starting…"
        default: return "Ask a question or say \"document this\"…"
        }
    }

    private var footer: some View {
        HStack {
            Text("This session \(model.sessionCost.formatted)")
                .font(DesignTokens.caption)
                .foregroundStyle(.secondary)
                .help("Estimated from token usage")
            Spacer()
            if !model.phase.isActive, !model.recent.isEmpty {
                Button("Document last walkthrough") { SessionController.shared.documentLast() }
                    .buttonStyle(.borderless)
                    .font(DesignTokens.caption)
            }
        }
        .padding(.horizontal, DesignTokens.space4)
        .padding(.bottom, DesignTokens.space2)
    }
}

struct StatusDot: View {
    var phase: SessionPhase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(phase.label)
    }

    private var color: Color {
        switch phase {
        case .running: return .green
        case .paused: return .orange
        case .queued: return DesignTokens.accent
        case .failed: return .red
        default: return .secondary
        }
    }
}

private struct TranscriptRow: View {
    var item: TranscriptItem

    var body: some View {
        HStack(alignment: .top) {
            if item.role == .user { Spacer(minLength: 40) }
            content
            if item.role == .assistant { Spacer(minLength: 20) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.role {
        case .user:
            Text(item.text)
                .font(DesignTokens.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DesignTokens.radiusLarge, style: .continuous).fill(DesignTokens.accent))
                .textSelection(.enabled)
        case .assistant:
            Text(Self.markdown(item.text))
                .font(DesignTokens.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .note, .system:
            Text(item.text)
                .font(DesignTokens.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: Cards

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space2) { content }
            .padding(DesignTokens.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DesignTokens.radiusMedium, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

private struct QueuedCard: View {
    var request: QueuedRequest

    var body: some View {
        Card {
            Label("Ready when you are", systemImage: "hand.wave").font(DesignTokens.captionEmphasis).foregroundStyle(.secondary)
            Text(request.task).font(DesignTokens.bodyEmphasis)
            if let context = request.context {
                Text(context).font(DesignTokens.caption).foregroundStyle(.secondary).lineLimit(4)
            }
            Text("Asked by \(request.source.label)\(request.app.map { " · in \($0)" } ?? "")")
                .font(DesignTokens.caption)
                .foregroundStyle(.secondary)
            Text("Nothing on your screen is captured until you press Start.")
                .font(DesignTokens.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now") { SessionController.shared.stop() }
                    .buttonStyle(.borderless)
                Button("Start") { SessionController.shared.startQueued() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ConfirmationCard: View {
    var confirmation: PendingConfirmation

    var body: some View {
        Card {
            Label("Confirm before I do this", systemImage: "hand.raised.fill")
                .font(DesignTokens.captionEmphasis)
                .foregroundStyle(DesignTokens.warning)
            Text(confirmation.summary).font(DesignTokens.bodyEmphasis)
            HStack {
                Spacer()
                Button("Don't") { SessionController.shared.host.answerConfirmation(false) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { SessionController.shared.host.answerConfirmation(true) }
                    .buttonStyle(PrimaryPillStyle(tint: DesignTokens.warning))
            }
        }
    }
}

private struct WriteupPreviewCard: View {
    var preview: WriteupPreview

    var body: some View {
        Card {
            Label("Write-up ready to save", systemImage: "doc.richtext").font(DesignTokens.captionEmphasis).foregroundStyle(.secondary)
            Text(preview.title).font(DesignTokens.bodyEmphasis)
            Text("\(preview.stepCount) step\(preview.stepCount == 1 ? "" : "s"). Password fields are blurred.")
                .font(DesignTokens.caption)
                .foregroundStyle(.secondary)
            if let image = preview.firstImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusSmall))
            }
            HStack {
                Button("Look through it") { NSWorkspace.shared.open(preview.stagingFolder) }
                    .buttonStyle(.borderless)
                Button("PDF") { SessionController.shared.exportPDF(preview) }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Discard") { SessionController.shared.discardWriteup() }
                    .buttonStyle(.borderless)
                Button("Save") { _ = SessionController.shared.saveWriteup(preview) }
                    .buttonStyle(PrimaryPillStyle())
            }
        }
    }
}
