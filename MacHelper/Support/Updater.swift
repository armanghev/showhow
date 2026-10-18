import AppKit
import Sparkle

/// Sparkle updates, switched on only when Info.plist has a SUFeedURL (set it
/// in Config/Release.xcconfig once you host an appcast).
@MainActor
final class Updater {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    func start() {
        guard controller == nil,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
