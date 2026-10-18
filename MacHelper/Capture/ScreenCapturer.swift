import AppKit
import CoreGraphics
import ImageIO
import MacHelperCore
import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Mac Helper needs Screen Recording permission. Open System Settings > Privacy & Security > Screen & System Audio Recording and turn it on."
        case .displayNotFound:
            return "That display is no longer connected."
        case .encodingFailed:
            return "Could not encode the screenshot."
        }
    }
}

/// Screenshots through ScreenCaptureKit, excluding Mac Helper's own windows so
/// Claude never sees its own drawings or the panel.
final class ScreenCapturer {
    static let shared = ScreenCapturer()

    /// Long edge of screenshots sent to Claude (Settings > General).
    var maxLongEdge: CGFloat = ScreenshotSizing.defaultLongEdge
    /// When set, captures only this app's windows (the "scope to one app" safety rail).
    var pinnedBundleID: String?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// A downscaled screenshot of a whole display.
    func capture(displayID: UInt32) async throws -> Screenshot {
        let (filter, display) = try await makeFilter(displayID: displayID)
        let frame = CGDisplayBounds(displayID)
        let scale = CGFloat(filter.pointPixelScale)
        let target = ScreenshotSizing.targetSize(for: CGSize(width: frame.width * scale, height: frame.height * scale), maxLongEdge: maxLongEdge)

        let config = SCStreamConfiguration()
        config.width = Int(target.width)
        config.height = Int(target.height)
        config.showsCursor = true
        config.capturesAudio = false
        config.scalesToFit = true
        _ = display

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let size = CGSize(width: image.width, height: image.height)
        let data = try ImageEncoding.jpeg(image)
        return Screenshot(data: data, mediaType: "image/jpeg", mapping: ScreenshotMapping(displayID: displayID, displayFrame: frame, imageSize: size))
    }

    /// A region of a display (display-local points) at full resolution, then
    /// downscaled to fit the model's limits: the `zoom` action.
    func captureRegion(displayID: UInt32, region: CGRect) async throws -> Screenshot {
        let (filter, _) = try await makeFilter(displayID: displayID)
        let frame = CGDisplayBounds(displayID)
        let clipped = region.intersection(CGRect(origin: .zero, size: frame.size))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { throw CaptureError.displayNotFound }
        let scale = CGFloat(filter.pointPixelScale)
        let target = ScreenshotSizing.targetSize(for: CGSize(width: clipped.width * scale, height: clipped.height * scale), maxLongEdge: maxLongEdge)

        let config = SCStreamConfiguration()
        config.sourceRect = clipped
        config.width = Int(target.width)
        config.height = Int(target.height)
        config.showsCursor = false
        config.scalesToFit = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let data = try ImageEncoding.jpeg(image, quality: 0.9)
        return Screenshot(data: data, mediaType: "image/jpeg",
                          mapping: ScreenshotMapping(displayID: displayID, displayFrame: frame, imageSize: CGSize(width: image.width, height: image.height), sourceRect: clipped))
    }

    /// The filter used both for screenshots and for recordings.
    func makeFilter(displayID: UInt32, excludeOwnWindows: Bool = true) async throws -> (SCContentFilter, SCDisplay) {
        guard Self.hasPermission else { throw CaptureError.permissionDenied }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.displayNotFound }

        if let pinned = pinnedBundleID, !pinned.isEmpty,
           let app = content.applications.first(where: { $0.bundleIdentifier == pinned })
        {
            return (SCContentFilter(display: display, including: [app], exceptingWindows: []), display)
        }

        let ownBundle = Bundle.main.bundleIdentifier
        let excluded = excludeOwnWindows ? content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundle } : []
        return (SCContentFilter(display: display, excludingWindows: excluded), display)
    }
}

enum ImageEncoding {
    static func jpeg(_ image: CGImage, quality: Double = 0.8) throws -> Data {
        try encode(image, type: UTType.jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    static func png(_ image: CGImage) throws -> Data {
        try encode(image, type: UTType.png, properties: [:])
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { throw CaptureError.encodingFailed }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.encodingFailed }
        return data as Data
    }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
