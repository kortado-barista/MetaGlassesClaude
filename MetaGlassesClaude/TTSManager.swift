// TTSManager.swift
// Wraps AVSpeechSynthesizer for text-to-speech output.
// When the Ray-Ban glasses are connected via Bluetooth, iOS automatically
// routes AVSpeechSynthesizer audio through the active BT audio device
// (the glasses speakers) — no extra routing code is needed.

import AVFoundation
import Combine

@MainActor
final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    func speak(_ text: String) {
        guard !text.isEmpty else { return }

        // Stop any current speech before starting new
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        // Prefer premium/enhanced neural voice; falls back to standard en-US
        utterance.voice = TTSManager.bestVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // A short pre-utterance delay prevents cutting off the first syllable
        // if the BT device needs a moment to activate its audio channel.
        utterance.preUtteranceDelay = 0.1

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    // MARK: - Voice selection

    /// Returns the highest-quality en-US voice available on this device.
    /// iOS 16+ ships Premium neural voices; iOS 15 has Enhanced; older has Standard.
    /// Selecting by highest rawValue automatically picks Premium > Enhanced > Default.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" }

        // Score: higher = better. Prefer premium/enhanced quality first,
        // then modern Eloquence/neural voices over old compact/novelty voices.
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            let qualityScore = v.quality.rawValue * 100
            let isEloquence = v.identifier.contains("eloquence") ? 10 : 0
            let isCompact   = v.identifier.contains("compact")   ? -20 : 0
            let isNovelty   = v.identifier.contains("speech.synthesis.voice") ? -30 : 0
            return qualityScore + isEloquence + isCompact + isNovelty
        }

        return all.max(by: { score($0) < score($1) })
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}
