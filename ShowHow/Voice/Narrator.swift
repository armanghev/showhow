import AVFoundation

/// Speaks instructions with AVSpeechSynthesizer (free and offline).
@MainActor
final class Narrator {
    private let synthesizer = AVSpeechSynthesizer()
    private let settings = AppSettings.shared

    /// Speaks when voice mode and narration are both on.
    func speak(_ text: String) {
        guard AppModel.shared.voiceOn, settings.speakNarration else { return }
        say(text)
    }

    /// Answers to spoken questions are read out too.
    func speakIfAnswer(_ text: String) {
        guard AppModel.shared.voiceOn, settings.speakNarration, text.count < 600 else { return }
        say(text)
    }

    func say(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: clean)
        if !settings.voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = Float(settings.speechRate) * AVSpeechUtteranceMaximumSpeechRate * 0.9
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }
            .sorted { $0.name < $1.name }
    }
}
