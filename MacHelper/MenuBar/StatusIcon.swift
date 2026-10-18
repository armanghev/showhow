import AppKit

/// The status item's states, from section 7 of the plan.
enum StatusIconState: Equatable {
    case idle
    case running
    case listening
    case paused
    case attention
}

/// Draws the menu bar glyph as a template image so it follows the menu bar's
/// light, dark and tinted appearance. Animated states have a few frames.
enum StatusIconRenderer {
    static let size = CGSize(width: 24, height: 18)

    static func frameCount(for state: StatusIconState) -> Int {
        switch state {
        case .running: return 12
        case .listening: return 8
        default: return 1
        }
    }

    static func image(for state: StatusIconState, frame: Int) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let filled = state != .idle
            let name = filled ? "hand.point.up.left.fill" : "hand.point.up.left"
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            if let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let g = glyph.size
                let origin = CGPoint(x: 1, y: (rect.height - g.height) / 2)
                glyph.draw(in: CGRect(origin: origin, size: g))
            }
            NSColor.black.setFill()
            let badgeCenter = CGPoint(x: rect.maxX - 4.5, y: rect.maxY - 4.5)
            switch state {
            case .idle:
                break
            case .running:
                // A slow pulse: alpha follows a sine over the frames.
                let t = Double(frame) / Double(frameCount(for: .running))
                let alpha = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 2 * .pi))
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: CGRect(x: badgeCenter.x - 3, y: badgeCenter.y - 3, width: 6, height: 6)).fill()
            case .listening:
                let heights: [[CGFloat]] = [[3, 7, 5], [5, 4, 7], [7, 6, 3], [4, 8, 5], [6, 3, 6], [3, 6, 8], [5, 7, 4], [8, 4, 6]]
                let h = heights[frame % heights.count]
                for (i, height) in h.enumerated() {
                    let x = rect.maxX - 8 + CGFloat(i) * 2.6
                    NSBezierPath(roundedRect: CGRect(x: x, y: rect.maxY - 1 - height, width: 1.8, height: height), xRadius: 0.9, yRadius: 0.9).fill()
                }
            case .paused:
                NSBezierPath(rect: CGRect(x: rect.maxX - 7, y: rect.maxY - 8, width: 1.8, height: 7)).fill()
                NSBezierPath(rect: CGRect(x: rect.maxX - 3.6, y: rect.maxY - 8, width: 1.8, height: 7)).fill()
            case .attention:
                // A solid dot with a clear ring so it reads against the glyph.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: CGRect(x: badgeCenter.x - 4.5, y: badgeCenter.y - 4.5, width: 9, height: 9)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: CGRect(x: badgeCenter.x - 3, y: badgeCenter.y - 3, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func accessibilityLabel(for state: StatusIconState) -> String {
        switch state {
        case .idle: return "Mac Helper"
        case .running: return "Mac Helper, walkthrough running"
        case .listening: return "Mac Helper, listening"
        case .paused: return "Mac Helper, paused"
        case .attention: return "Mac Helper needs attention"
        }
    }
}
