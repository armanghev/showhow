import AVFoundation
import Speech

/// Push-to-talk and hands-free listening with on-device SFSpeechRecognizer.
/// The listening badge on the panel and the overlay is on whenever the
/// microphone is live; the app never listens without it.
@MainActor
final class VoiceController {
    static let shared = VoiceController()

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private let model = AppModel.shared
    /// Hands-free: after each utterance, deliver it and listen again.
    private(set) var handsFree = false
    private var silenceTimer: Timer?

    var isListening: Bool { request != nil }

    enum VoiceError: LocalizedError {
        case notAuthorized
        case unavailable
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Mac Helper needs Microphone and Speech Recognition permission for voice."
            case .unavailable: return "Speech recognition is not available for your language right now."
            }
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && mic
    }

    func startListening(handsFree: Bool = false) {
        guard !isListening else { return }
        self.handsFree = handsFree
        Task {
            if !Self.isAuthorized {
                guard await Self.requestAuthorization() else {
                    model.attention = VoiceError.notAuthorized.localizedDescription
                    return
                }
            }
            do {
                try begin()
            } catch {
                model.attention = error.localizedDescription
                cleanUp()
            }
        }
    }

    private func begin() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw VoiceError.unavailable }
        SessionController.shared.narrator.stop()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        self.request = request
        transcript = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        model.listening = true
        DisplayManager.shared.overlayModel.listening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text {
                    self.transcript = text
                    self.model.partialTranscript = text
                    if self.handsFree { self.armSilenceTimer() }
                }
                if isFinal || failed { self.finishUtterance() }
            }
        }
    }

    /// Releasing push-to-talk, or the panel's stop button.
    func stopListening(deliver: Bool = true) {
        guard isListening else { return }
        handsFree = deliver ? handsFree : false
        if !deliver { transcript = "" }
        request?.endAudio()
        // The recognizer sends a final result shortly; finish anyway if not.
        let pending = request
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self.request === pending { self.finishUtterance() }
        }
        if !deliver { handsFree = false; finishUtterance() }
    }

    func toggleHandsFree() {
        if isListening { handsFree = false; stopListening() } else { startListening(handsFree: true) }
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.request?.endAudio() }
        }
    }

    private func finishUtterance() {
        guard request != nil else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let again = handsFree
        cleanUp()
        if !text.isEmpty { SessionController.shared.send(text, source: .voice) }
        if again { startListening(handsFree: true) }
    }

    private func cleanUp() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        task?.cancel()
        task = nil
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        transcript = ""
        model.partialTranscript = ""
        model.listening = false
        DisplayManager.shared.overlayModel.listening = false
    }
}
