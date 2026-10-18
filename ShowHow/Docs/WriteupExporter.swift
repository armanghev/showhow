import AppKit
import CoreImage
import ShowHowCore

/// Turns a session log into a Markdown write-up folder:
///
///     README.md, images/step-01.jpg …, recording.mov (if recorded)
///
/// The skeleton and images are deterministic (annotations burned in, password
/// fields blurred). One text-only Claude call then polishes the wording.
@MainActor
struct WriteupExporter {
    let store: SessionLogStore
    let settings: AppSettings

    enum ExportError: LocalizedError {
        case noSteps
        var errorDescription: String? { "That walkthrough has no steps to write up yet." }
    }

    /// Builds the write-up in a staging folder inside the session's log folder.
    func stage(_ log: SessionLog) async throws -> WriteupPreview {
        var doc = MarkdownExporter.skeleton(from: log)
        guard !doc.steps.isEmpty else { throw ExportError.noSteps }

        if settings.polishWriteups, let key = Keychain.apiKey() {
            if let polish = await Self.polish(log: log, skeleton: doc, apiKey: key, model: settings.model) {
                doc = MarkdownExporter.apply(polish, to: doc)
            }
        }

        let staging = store.folder(for: log.id)
            .appendingPathComponent("writeup-staging", isDirectory: true)
            .appendingPathComponent(MarkdownExporter.folderName(for: doc), isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)

        // The same filter the skeleton uses, so step N gets image N.
        let steps = log.steps.filter { !$0.instruction.isEmpty || !$0.annotations.isEmpty }
        var firstImage: NSImage?
        for (offset, step) in steps.enumerated() {
            guard let file = step.screenshotFile else { continue }
            let source = store.imageURL(session: log.id, file: file)
            guard let data = try? Data(contentsOf: source), let cgImage = ImageEncoding.cgImage(from: data) else { continue }
            let mapping = step.screenshotMapping ?? ScreenshotMapping(displayID: 0, displayFrame: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height),
                                                                       imageSize: CGSize(width: cgImage.width, height: cgImage.height))
            let rendered = AnnotationBurner.render(cgImage, annotations: step.annotations, mapping: mapping,
                                                   blur: settings.blurPasswordFields ? step.secureRects : [])
            let output = try ImageEncoding.jpeg(rendered, quality: 0.85)
            try output.write(to: staging.appendingPathComponent(MarkdownExporter.imageName(for: offset + 1)))
            if firstImage == nil { firstImage = NSImage(cgImage: rendered, size: .zero) }
        }

        if let recording = log.recordingFile {
            let source = store.folder(for: log.id).appendingPathComponent(recording)
            if fm.fileExists(atPath: source.path) {
                try? fm.copyItem(at: source, to: staging.appendingPathComponent("recording.mov"))
            } else {
                doc.recording = nil
            }
        }

        let markdown = MarkdownExporter.render(doc)
        try markdown.write(to: staging.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return WriteupPreview(sessionID: log.id, title: doc.title, stepCount: doc.steps.count, stagingFolder: staging,
                              firstImage: firstImage, markdown: markdown)
    }

    /// Moves a staged folder into Documents, picking a free name.
    static func move(staging: URL, into documents: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        let base = staging.lastPathComponent
        var destination = documents.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = documents.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        try fm.moveItem(at: staging, to: destination)
        return destination
    }

    /// One text-only request; returns nil (keeping the plain skeleton) on any failure.
    static func polish(log: SessionLog, skeleton: WriteupDocument, apiKey: String, model: ClaudeModel) async -> WriteupPolish? {
        let request = MessagesRequest.structured(model: model, system: MarkdownExporter.polishSystem,
                                                 prompt: MarkdownExporter.polishPrompt(for: log, skeleton: skeleton),
                                                 schema: MarkdownExporter.polishSchema, apiKey: apiKey)
        let client = ClaudeClient(transport: URLSessionLineTransport())
        do {
            let message = try await client.send(request, observer: nil)
            guard message.stopReason != "refusal", let data = message.text.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(WriteupPolish.self, from: data)
        } catch {
            return nil
        }
    }
}

/// Draws annotations into a screenshot so the image shows the highlight
/// without the overlay, and blurs password fields.
enum AnnotationBurner {
    static func render(_ image: CGImage, annotations: [Annotation], mapping: ScreenshotMapping, blur: [CGRect]) -> CGImage {
        let width = image.width, height = image.height
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Blur secure fields first, in pixel space (CoreGraphics is y-up here).
        let covered = mapping.coveredRect
        let sx = 1 / mapping.pointsPerPixelX, sy = 1 / mapping.pointsPerPixelY
        func pixelRect(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - covered.minX) * sx, y: (r.minY - covered.minY) * sy, width: r.width * sx, height: r.height * sy)
        }
        if !blur.isEmpty {
            let ciContext = CIContext()
            let source = CIImage(cgImage: image)
            for rect in blur {
                let top = pixelRect(rect).insetBy(dx: -4, dy: -4)
                let flipped = CGRect(x: top.minX, y: CGFloat(height) - top.maxY, width: top.width, height: top.height)
                let blurred = source.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 14, kCIInputCenterKey: CIVector(x: flipped.midX, y: flipped.midY)])
                    .applyingGaussianBlur(sigma: 8)
                    .cropped(to: flipped)
                if let patch = ciContext.createCGImage(blurred, from: flipped) {
                    cg.draw(patch, in: flipped)
                }
            }
        }

        // Annotations: flip to a top-left origin and draw with AppKit.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let scale = (sx + sy) / 2
        for annotation in annotations {
            draw(annotation, pixelRect: pixelRect, pixelPoint: { CGPoint(x: ($0.x - covered.minX) * sx, y: ($0.y - covered.minY) * sy) }, scale: scale)
        }
        NSGraphicsContext.restoreGraphicsState()
        return cg.makeImage() ?? image
    }

    private static func draw(_ a: Annotation, pixelRect: (CGRect) -> CGRect, pixelPoint: (CGPoint) -> CGPoint, scale: CGFloat) {
        let color = a.kind == .typeBubble ? NSColor(srgbRed: 0.18, green: 0.62, blue: 0.40, alpha: 1) : DesignTokens.annotationNS
        color.setStroke()
        let line = DesignTokens.strokeWidth * scale
        var labelAnchor: CGPoint?
        switch a.kind {
        case .highlight, .callout, .typeBubble:
            guard let r = a.rect.map(pixelRect)?.insetBy(dx: -4 * scale, dy: -4 * scale) else { break }
            color.withAlphaComponent(0.14).setFill()
            let path = NSBezierPath(roundedRect: r, xRadius: 6 * scale, yRadius: 6 * scale)
            if a.kind == .highlight { path.fill() }
            path.lineWidth = line
            if a.kind == .callout { path.setLineDash([6 * scale, 4 * scale], count: 2, phase: 0) }
            path.stroke()
            labelAnchor = CGPoint(x: r.minX, y: r.maxY + 10 * scale)
        case .circle:
            var r: CGRect
            if let rect = a.rect.map(pixelRect) {
                let side = max(rect.width, rect.height) + 16 * scale
                r = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            } else if let p = a.point.map(pixelPoint) {
                r = CGRect(x: p.x - 22 * scale, y: p.y - 22 * scale, width: 44 * scale, height: 44 * scale)
            } else { break }
            let path = NSBezierPath(ovalIn: r)
            path.lineWidth = line
            path.stroke()
            labelAnchor = CGPoint(x: r.minX, y: r.maxY + 10 * scale)
        case .arrow:
            guard let head = a.point.map(pixelPoint) else { break }
            let tail = a.fromPoint.map(pixelPoint) ?? CGPoint(x: head.x - 90 * scale, y: head.y - 70 * scale)
            let path = NSBezierPath()
            path.lineWidth = line + scale
            path.lineCapStyle = .round
            path.move(to: tail)
            path.line(to: head)
            let angle = atan2(head.y - tail.y, head.x - tail.x)
            let size = 16 * scale
            path.move(to: head)
            path.line(to: CGPoint(x: head.x - size * cos(angle - .pi / 7), y: head.y - size * sin(angle - .pi / 7)))
            path.move(to: head)
            path.line(to: CGPoint(x: head.x - size * cos(angle + .pi / 7), y: head.y - size * sin(angle + .pi / 7)))
            path.stroke()
            labelAnchor = CGPoint(x: tail.x, y: tail.y - 30 * scale)
        }
        var text = a.label
        if let typed = a.textToType { text += text.isEmpty ? typed : ": \(typed)" }
        guard let anchor = labelAnchor, !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 13 * scale, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let pad = 8 * scale
        let box = CGRect(x: anchor.x, y: anchor.y, width: size.width + pad * 2, height: size.height + pad)
        color.setFill()
        NSBezierPath(roundedRect: box, xRadius: 8 * scale, yRadius: 8 * scale).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attributes)
    }
}
