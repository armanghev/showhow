import AppKit
import ShowHowCore
import SwiftUI

/// One line of the session transcript shown in the floating panel.
struct TranscriptItem: Identifiable, Equatable {
    enum Role { case user, assistant, note, system }
    let id = UUID()
    var role: Role
    var text: String
}

/// A walkthrough waiting for the user to press Start (from MCP, the URL scheme
/// or the panel).
struct QueuedRequest: Identifiable, Equatable {
    var id: String
    var task: String
    var context: String?
    var app: String?
    var mode: AgentMode?
    var source: SessionSource
}

/// An on-screen yes/no before a risky action.
struct PendingConfirmation: Identifiable {
    let id = UUID()
    var summary: String
}

/// A write-up staged for review before it is saved to Documents.
struct WriteupPreview: Identifiable {
    let id = UUID()
    var sessionID: UUID
    var title: String
    var stepCount: Int
    var stagingFolder: URL
    var firstImage: NSImage?
    var markdown: String
}

/// Observable state shared by the menu panel, the floating panel and the
/// status icon. The session controller is the only writer.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var phase: SessionPhase = .idle
    @Published var queued: QueuedRequest?
    @Published var taskTitle = ""
    @Published var sourceLabel = ""
    @Published var step = 0
    @Published var totalSteps = 0
    @Published var instruction = ""
    @Published var detail = ""
    @Published var transcript: [TranscriptItem] = []
    @Published var streamingText = ""
    @Published var progressNote = ""
    @Published var thinking = false
    @Published var waitingForUser = false
    @Published var mode: AgentMode = AppSettings.shared.defaultMode
    @Published var voiceOn = AppSettings.shared.voiceEnabled
    @Published var listening = false
    @Published var partialTranscript = ""
    @Published var recordThisSession = AppSettings.shared.recordByDefault
    @Published var documenting = false
    @Published var recording = false
    @Published var sessionCost = CostMeter()
    @Published var attention: String?
    @Published var pendingConfirmation: PendingConfirmation?
    @Published var writeupPreview: WriteupPreview?
    @Published var exporting = false
    @Published var recent: [SessionLog] = []
    @Published var whiteboardOpen = false
    @Published var panelExpanded = false

    /// "Pivot table in Numbers, step 3 of 7", or the queued hand-off.
    var headline: String {
        if let queued, !phase.isActive || phase == .queued {
            return "Ready when you are: \(queued.task)"
        }
        switch phase {
        case .idle: return "Ready to help"
        case .queued: return "Ready when you are: \(taskTitle)"
        case .running, .paused:
            var line = taskTitle.isEmpty ? "Walkthrough" : taskTitle
            if step > 0 { line += totalSteps > 0 ? ", step \(step) of \(totalSteps)" : ", step \(step)" }
            if case .paused(let reason) = phase {
                switch reason {
                case .takeover: line += " (paused: you took over)"
                case .whiteboard: line += " (whiteboard open)"
                default: line += " (paused)"
                }
            }
            return line
        case .done: return taskTitle.isEmpty ? "Done" : "Done: \(taskTitle)"
        case .failed(let message): return message
        }
    }

    var progress: Double {
        guard totalSteps > 0 else { return phase == .running ? 0.05 : 0 }
        return min(1, Double(max(step - 1, 0)) / Double(totalSteps))
    }

    func append(_ role: TranscriptItem.Role, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.append(TranscriptItem(role: role, text: trimmed))
        if transcript.count > 200 { transcript.removeFirst(transcript.count - 200) }
    }

    func resetForNewSession(title: String, source: String, mode: AgentMode) {
        taskTitle = title
        sourceLabel = source
        self.mode = mode
        step = 0
        totalSteps = 0
        instruction = ""
        detail = ""
        transcript = []
        streamingText = ""
        progressNote = ""
        documenting = false
        recording = false
        sessionCost = CostMeter()
        attention = nil
    }
}
