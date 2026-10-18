import MacHelperCore
import SwiftUI

/// Draws one annotation: highlight box, circle, arrow, callout, or "type this" bubble.
struct AnnotationView: View {
    let annotation: Annotation
    @State private var pulse = false

    private var color: Color { annotation.kind == .typeBubble ? DesignTokens.typeBubble : DesignTokens.annotation }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shape
            label
        }
        .onAppear {
            guard !DesignTokens.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement()
        .accessibilityLabel(annotation.label)
    }

    @ViewBuilder
    private var shape: some View {
        switch annotation.kind {
        case .highlight:
            if let r = annotation.rect {
                RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
                    .fill(DesignTokens.annotationFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
                            .stroke(color, lineWidth: DesignTokens.strokeWidth)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.radiusSmall + 4, style: .continuous)
                            .stroke(color.opacity(pulse ? 0.0 : 0.45), lineWidth: DesignTokens.haloWidth)
                            .padding(-6)
                    )
                    .frame(width: r.width + 8, height: r.height + 8)
                    .position(x: r.midX, y: r.midY)
            }
        case .circle:
            if let r = circleRect {
                Circle()
                    .stroke(color, lineWidth: DesignTokens.strokeWidth)
                    .background(Circle().fill(DesignTokens.annotationFill))
                    .overlay(Circle().stroke(color.opacity(pulse ? 0 : 0.4), lineWidth: DesignTokens.haloWidth).padding(-8))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        case .arrow:
            if let head = annotation.point {
                let tail = annotation.fromPoint ?? CGPoint(x: head.x - 90, y: head.y - 70)
                ArrowShape(from: tail, to: head)
                    .stroke(color, style: StrokeStyle(lineWidth: DesignTokens.strokeWidth + 1, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
        case .callout, .typeBubble:
            if let r = annotation.rect {
                RoundedRectangle(cornerRadius: DesignTokens.radiusSmall, style: .continuous)
                    .stroke(color, style: StrokeStyle(lineWidth: DesignTokens.strokeWidthThin, dash: annotation.kind == .callout ? [6, 4] : []))
                    .frame(width: r.width + 6, height: r.height + 6)
                    .position(x: r.midX, y: r.midY)
            }
        }
    }

    private var circleRect: CGRect? {
        if let r = annotation.rect {
            let side = max(max(r.width, r.height) + 16, 36)
            return CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
        }
        if let p = annotation.point { return CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44) }
        return nil
    }

    /// Where the label goes: below the target when there is room, else above.
    private var labelAnchor: CGPoint {
        if annotation.kind == .arrow, let tail = annotation.fromPoint ?? annotation.point.map({ CGPoint(x: $0.x - 90, y: $0.y - 70) }) {
            return CGPoint(x: tail.x, y: tail.y - 22)
        }
        let r = annotation.rect ?? circleRect ?? CGRect(origin: annotation.point ?? CGPoint(x: 80, y: 80), size: .zero)
        return CGPoint(x: r.minX, y: r.maxY + 12)
    }

    @ViewBuilder
    private var label: some View {
        if !annotation.label.isEmpty || annotation.textToType != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !annotation.label.isEmpty {
                    Text(annotation.label)
                        .font(DesignTokens.annotationLabel)
                        .foregroundStyle(.white)
                }
                if let text = annotation.textToType {
                    Text(text)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.18)))
                        .textSelection(.disabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: DesignTokens.radiusMedium, style: .continuous).fill(color))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .fixedSize()
            .alignmentGuide(.leading) { _ in -labelAnchor.x }
            .alignmentGuide(.top) { _ in -labelAnchor.y }
        }
    }
}

/// A line with an arrowhead at `to`.
struct ArrowShape: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let bend = CGPoint(x: mid.x + (to.y - from.y) * 0.12, y: mid.y - (to.x - from.x) * 0.12)
        path.addQuadCurve(to: to, control: bend)
        let angle = atan2(to.y - bend.y, to.x - bend.x)
        let head: CGFloat = 16
        path.move(to: to)
        path.addLine(to: CGPoint(x: to.x - head * cos(angle - .pi / 7), y: to.y - head * sin(angle - .pi / 7)))
        path.move(to: to)
        path.addLine(to: CGPoint(x: to.x - head * cos(angle + .pi / 7), y: to.y - head * sin(angle + .pi / 7)))
        return path
    }
}
