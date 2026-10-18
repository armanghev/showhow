import AppKit
import SwiftUI

/// Live permission state for the onboarding screen and Settings > Privacy.
@MainActor
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published var screenRecording = ScreenCapturer.hasPermission
    @Published var accessibility = AXReader.isTrusted
    @Published var voice = VoiceController.isAuthorized
    @Published var apiKey = Keychain.hasAPIKey
    private var timer: Timer?

    func startPolling() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        screenRecording = ScreenCapturer.hasPermission
        accessibility = AXReader.isTrusted
        voice = VoiceController.isAuthorized
        apiKey = Keychain.hasAPIKey
    }

    static func openSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionDot: View {
    var granted: Bool

    var body: some View {
        Circle()
            .fill(granted ? Color.green : Color.orange)
            .frame(width: 9, height: 9)
            .accessibilityLabel(granted ? "Granted" : "Not granted")
    }
}

/// One row per permission with a live status dot and a button to the right
/// System Settings pane.
struct PermissionsList: View {
    @ObservedObject private var monitor = PermissionMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space3) {
            row(granted: monitor.screenRecording, title: "Screen Recording", detail: "Needed to see your screen. Guide mode needs only this.") {
                ScreenCapturer.requestPermission()
                PermissionMonitor.openSettingsPane("Privacy_ScreenCapture")
            }
            row(granted: monitor.accessibility, title: "Accessibility", detail: "Names buttons precisely, and lets Do-it mode click and type for you.") {
                AXReader.requestTrust()
                PermissionMonitor.openSettingsPane("Privacy_Accessibility")
            }
            row(granted: monitor.voice, title: "Microphone and Speech", detail: "Optional, for talking to Mac Helper.") {
                Task { monitor.voice = await VoiceController.requestAuthorization() }
            }
        }
        .onAppear { monitor.startPolling() }
        .onDisappear { monitor.stopPolling() }
    }

    private func row(granted: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.space3) {
            PermissionDot(granted: granted).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DesignTokens.bodyEmphasis)
                Text(detail).font(DesignTokens.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("On").font(DesignTokens.caption).foregroundStyle(.secondary)
            } else {
                Button("Open Settings", action: action)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingView: View {
    @ObservedObject private var monitor = PermissionMonitor.shared
    @State private var apiKey = ""
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space4) {
            HStack(spacing: DesignTokens.space3) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(DesignTokens.accent)
                VStack(alignment: .leading) {
                    Text("Welcome to Mac Helper").font(.system(size: 20, weight: .semibold))
                    Text("Claude looks at your screen and shows you where to click.")
                        .foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: DesignTokens.space2) {
                    HStack {
                        PermissionDot(granted: monitor.apiKey)
                        Text("Anthropic API key").font(DesignTokens.bodyEmphasis)
                    }
                    if !monitor.apiKey {
                        HStack {
                            SecureField("sk-ant-…", text: $apiKey)
                            Button("Save") {
                                Keychain.setAPIKey(apiKey)
                                monitor.refresh()
                            }
                            .disabled(apiKey.isEmpty)
                        }
                    }
                }
                .padding(DesignTokens.space2)
            }
            GroupBox {
                PermissionsList().padding(DesignTokens.space2)
            }
            HStack {
                Text("Start with Screen Recording for Guide mode. You can turn on the rest later.")
                    .font(DesignTokens.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
            }
            Text("Tip: press ⌥Space anywhere to ask for help.")
                .font(DesignTokens.caption)
                .foregroundStyle(.secondary)
        }
        .padding(DesignTokens.space6)
        .frame(width: 520)
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 480),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let view = OnboardingView { [weak self] in
            AppSettings.shared.onboardingDone = true
            self?.close()
        }
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
