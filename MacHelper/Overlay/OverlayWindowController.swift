import AppKit
import MacHelperCore
import SwiftUI

/// Shared state for every overlay window.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var annotations: [Annotation] = []
    /// Paused sessions dim the overlay and stop adding to it.
    @Published var dimmed = false
    /// A subtle indicator while Claude is thinking, so a step never feels frozen.
    @Published var thinkingDisplayID: UInt32?
    /// Shown whenever the microphone is live.
    @Published var listening = false
    /// Debug dot for checking coordinate mapping (Settings > General > Show debug dot).
    @Published var debugPoint: (UInt32, CGPoint)?

    func show(_ new: [Annotation], replace: Bool) {
        if replace { annotations = new } else { annotations += new }
    }

    func clear() {
        annotations = []
    }

    func annotations(for display: UInt32) -> [Annotation] {
        annotations.filter { $0.displayID == display }
    }
}

/// One borderless, click-through window per display that draws annotations.
/// It sits above full-screen apps and joins every Space.
@MainActor
final class OverlayWindowController: NSWindowController {
    let displayID: UInt32

    init(displayID: UInt32, screen: NSScreen, model: OverlayModel) {
        self.displayID = displayID
        let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: AnnotationLayer(displayID: displayID, model: model))
        window.setFrame(screen.frame, display: false)
        super.init(window: window)
        window.orderFrontRegardless()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
        window?.orderFrontRegardless()
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI content of an overlay window. Its coordinate space is the display's
/// local points with a top-left origin, which is exactly what `Annotation` uses.
struct AnnotationLayer: View {
    let displayID: UInt32
    @ObservedObject var model: OverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.annotations(for: displayID)) { annotation in
                AnnotationView(annotation: annotation)
                    .transition(.opacity)
            }
            if model.thinkingDisplayID == displayID {
                ThinkingIndicator()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 36)
            }
            if model.listening {
                ListeningBadge()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 36)
                    .padding(.trailing, 16)
            }
            if let debug = model.debugPoint, debug.0 == displayID {
                Circle().fill(Color.red).frame(width: 10, height: 10).position(debug.1)
            }
        }
        .opacity(model.dimmed ? 0.35 : 1)
        .animation(DesignTokens.animation(), value: model.annotations)
        .animation(DesignTokens.animation(), value: model.dimmed)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct ThinkingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(DesignTokens.accent)
                    .frame(width: 6, height: 6)
                    .opacity(phase ? 1 : 0.3)
                    .animation(DesignTokens.reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: phase)
            }
            Text("Thinking")
                .font(DesignTokens.captionEmphasis)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(VisualEffectBackground(material: .hudWindow, cornerRadius: DesignTokens.radiusPill))
        .onAppear { phase = true }
    }
}

struct ListeningBadge: View {
    var body: some View {
        Label("Listening", systemImage: "mic.fill")
            .font(DesignTokens.captionEmphasis)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.red))
            .accessibilityLabel("Microphone is on")
    }
}
