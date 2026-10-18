import Foundation
import Security
import ShowHowCore
import SwiftUI

/// Settings stored in UserDefaults. The API key is in the Keychain instead.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("model") var modelRaw = ClaudeModel.opus.rawValue
    @AppStorage("effort") var effortRaw = Effort.medium.rawValue
    @AppStorage("defaultMode") var defaultModeRaw = AgentMode.guide.rawValue
    @AppStorage("screenshotLongEdge") var screenshotLongEdge = Double(ScreenshotSizing.defaultLongEdge)
    @AppStorage("contextEditing") var contextEditing = true
    @AppStorage("compaction") var compaction = true

    @AppStorage("voiceEnabled") var voiceEnabled = false
    @AppStorage("speakNarration") var speakNarration = true
    @AppStorage("voiceIdentifier") var voiceIdentifier = ""
    @AppStorage("speechRate") var speechRate = 0.5

    @AppStorage("allowStartNow") var allowStartNow = false
    @AppStorage("mcpEnabled") var mcpEnabled = true
    @AppStorage("mcpPort") var mcpPort = 0
    @AppStorage("mcpToken") var mcpToken = ""

    @AppStorage("documentsFolder") var documentsFolder = ""
    @AppStorage("recordByDefault") var recordByDefault = false
    @AppStorage("polishWriteups") var polishWriteups = true
    @AppStorage("previewBeforeSaving") var previewBeforeSaving = true

    @AppStorage("logRetentionDays") var logRetentionDays = 7
    @AppStorage("blurPasswordFields") var blurPasswordFields = true
    @AppStorage("pinnedAppBundleID") var pinnedAppBundleID = ""
    @AppStorage("onboardingDone") var onboardingDone = false
    @AppStorage("showCostInMenu") var showCostInMenu = true

    var model: ClaudeModel {
        get { ClaudeModel(rawValue: modelRaw) ?? .opus }
        set { modelRaw = newValue.rawValue }
    }

    var effort: Effort {
        get { Effort(rawValue: effortRaw) ?? .medium }
        set { effortRaw = newValue.rawValue }
    }

    var defaultMode: AgentMode {
        get { AgentMode(rawValue: defaultModeRaw) ?? .guide }
        set { defaultModeRaw = newValue.rawValue }
    }

    var requestConfig: RequestConfig {
        RequestConfig(model: model, effort: effort, contextEditing: contextEditing, compaction: compaction)
    }

    /// `~/Documents/ShowHow` unless the user picked another folder.
    var documentsURL: URL {
        if !documentsFolder.isEmpty { return URL(fileURLWithPath: documentsFolder, isDirectory: true) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("ShowHow", isDirectory: true)
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ShowHow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var sessionsDirectory: URL { supportDirectory.appendingPathComponent("Sessions", isDirectory: true) }
    static var boardsDirectory: URL { supportDirectory.appendingPathComponent("Boards", isDirectory: true) }

    /// Picks a stable random port and token the first time the MCP server runs.
    func ensureMCPCredentials() {
        if mcpPort == 0 { mcpPort = Int.random(in: 49_152...65_000) }
        if mcpToken.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 24)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            mcpToken = bytes.map { String(format: "%02x", $0) }.joined()
        }
    }
}
