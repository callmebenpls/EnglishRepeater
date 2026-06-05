import Foundation
import AVFoundation

/// On-device text-to-speech wrapper around `AVSpeechSynthesizer`.
///
/// Kept separate from `PlayerViewModel` so the TTS lifecycle (delegate, completion
/// handling, interruption) lives in one focused place. Speaks through the shared audio
/// session, so it works with the screen locked / through AirPods as long as the caller
/// has paused any other audio first.
final class SpeechReader: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak `text` clearly. `onFinish` is called on the main thread when speech ends
    /// naturally — NOT when it is cancelled by a new `speak` or `stop`.
    ///
    /// - Parameter rate: 0.0...1.0 in `AVSpeechUtterance` terms. Default is slightly
    ///   below the system default for clarity.
    func speak(_ text: String,
               language: String = "en-US",
               rate: Float = 0.44,
               onFinish: (() -> Void)? = nil) {
        let spoken = SpeechReader.sanitizeForSpeech(text)
        guard !spoken.isEmpty else {
            onFinish?()
            return
        }

        // Cancelling fires didCancel (not didFinish), so the previous onFinish is dropped
        // intentionally — an interrupting call should not trigger the old completion.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        self.onFinish = onFinish

        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = SpeechReader.preferredVoice(for: language)
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate,
                             min(AVSpeechUtteranceMaximumSpeechRate, rate))
        utterance.postUtteranceDelay = 0

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Strip punctuation so the voice reads the words straight through, without the extra
    /// pauses or odd artifacts that commas/periods/quotes can introduce. Intra-word
    /// apostrophes are kept (so "don't" stays a contraction); hyphens and dashes become
    /// spaces (so "well-known" reads as two clear words). Runs of whitespace collapse.
    static func sanitizeForSpeech(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar == "'" || scalar == "\u{2019}" {   // straight or curly apostrophe
                out.append("'")
            } else if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// Stop any current speech immediately. Does not call `onFinish`.
    func stop() {
        onFinish = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    /// Prefer a higher-quality (enhanced/premium) voice for the language when the user
    /// has one downloaded; fall back to the default voice for the language.
    private static func preferredVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let langVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
        if let premium = langVoices.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = langVoices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: language)
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension SpeechReader: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        let completion = onFinish
        onFinish = nil
        DispatchQueue.main.async {
            self.isSpeaking = false
            completion?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }
}
