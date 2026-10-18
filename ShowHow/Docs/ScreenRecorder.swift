import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Opt-in screen recording of the walkthrough display into a .mov.
/// SCRecordingOutput on macOS 15 and later; an AVAssetWriter fallback on 14.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private let sampleQueue = DispatchQueue(label: "com.armanghev.ShowHow.recording")

    func start(displayID: UInt32, url: URL) async throws {
        let (filter, display) = try await ScreenCapturer.shared.makeFilter(displayID: displayID)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        // Cap at 1920 px wide to keep files reasonable.
        let factor = min(1, 1920 / (CGFloat(display.width) * scale))
        config.width = Int(CGFloat(display.width) * scale * factor) & ~1
        config.height = Int(CGFloat(display.height) * scale * factor) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.queueDepth = 6
        try? FileManager.default.removeItem(at: url)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        if #available(macOS 15.0, *) {
            let recording = SCRecordingOutputConfiguration()
            recording.outputURL = url
            recording.outputFileType = .mov
            recording.videoCodecType = .h264
            let output = SCRecordingOutput(configuration: recording, delegate: RecordingDelegate.shared)
            try stream.addRecordingOutput(output)
        } else {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: config.width,
                AVVideoHeightKey: config.height,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CaptureError.encodingFailed }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CaptureError.encodingFailed }
            self.writer = writer
            self.input = input
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        if let writer, let input {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                sampleQueue.async {
                    input.markAsFinished()
                    writer.finishWriting { c.resume() }
                }
            }
        }
        writer = nil
        input = nil
    }

    // MARK: AVAssetWriter path (macOS 14)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let writer, let input else { return }
        // Only complete frames carry pixels.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
    }
}

@available(macOS 15.0, *)
private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    static let shared = RecordingDelegate()
}
