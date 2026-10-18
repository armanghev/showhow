import AppKit
import SwiftUI

/// One visual language for the menu panel, the floating panel, the overlay and
/// the whiteboard. Spacing sits on an 8 pt grid; type comes from the system font.
enum DesignTokens {
    // MARK: Color

    /// The app accent: an indigo that reads on light and dark screens.
    static let accent = Color(nsColor: accentNS)
    static let accentNS = NSColor(srgbRed: 0.33, green: 0.36, blue: 0.95, alpha: 1)
    /// Annotation colors stay saturated over any app's UI.
    static let annotation = Color(nsColor: annotationNS)
    static let annotationNS = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.21, alpha: 1)
    static let annotationFill = annotation.opacity(0.14)
    static let typeBubble = Color(nsColor: NSColor(srgbRed: 0.18, green: 0.62, blue: 0.40, alpha: 1))
    static let warning = Color.orange
    static let danger = Color.red

    // MARK: Spacing (8 pt grid)

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24

    // MARK: Radii

    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 8
    static let radiusLarge: CGFloat = 12
    static let radiusPill: CGFloat = 999

    // MARK: Type ramp

    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionEmphasis = Font.system(size: 11, weight: .semibold)
    static let annotationLabel = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let mono = Font.system(size: 12, design: .monospaced)

    // MARK: Annotation strokes

    static let strokeWidth: CGFloat = 3
    static let strokeWidthThin: CGFloat = 2
    static let haloWidth: CGFloat = 8

    // MARK: Motion

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static let quick: Double = 0.16
    static let standard: Double = 0.24

    static func animation(_ duration: Double = standard) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }
}

/// An `NSVisualEffectView` for SwiftUI, falling back to a solid window color
/// when Reduce Transparency is on.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat = DesignTokens.radiusLarge

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.wantsLayer = true
        update(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        update(view)
    }

    private func update(_ view: NSVisualEffectView) {
        view.material = DesignTokens.reduceTransparency ? .windowBackground : material
        view.blendingMode = blending
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
    }
}

/// A row in the menu panel: symbol, title, optional shortcut on the right.
struct MenuRowStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, DesignTokens.space2)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
                    .fill(isSelected || configuration.isPressed ? Color.accentColor.opacity(configuration.isPressed ? 0.9 : 0.8) : .clear)
            )
            .foregroundStyle(isSelected || configuration.isPressed ? Color.white : Color.primary)
            .contentShape(Rectangle())
    }
}

/// The capsule primary button used in both panels.
struct PrimaryPillStyle: ButtonStyle {
    var tint: Color = DesignTokens.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignTokens.bodyEmphasis)
            .padding(.horizontal, DesignTokens.space3)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.75 : 1)))
            .foregroundStyle(.white)
    }
}

struct ShortcutHint: View {
    var text: String?
    var highlighted = false

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(DesignTokens.caption)
                .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary)
        }
    }
}
