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
        // Use the most natural voice available
        utterance.voice = TTSManager.preferredVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95 // Slightly slower for clarity
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // A short pre-utterance delay prevents cutting off the first syllable
        // if the BT device needs a moment to activate its audio channel.
        utterance.preUtteranceDelay = 0.1

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Voice Selection

    /// Returns the best available English voice, preferring premium/enhanced voices
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let englishVoices = allVoices.filter { $0.language.hasPrefix("en") }

        // Priority: Premium > Enhanced > Default
        // Premium voices have "premium" in identifier, Enhanced have "enhanced"
        // Also prefer specific high-quality voices by name
        let premiumVoiceNames = ["Zoe", "Evan", "Samantha", "Karen", "Daniel", "Moira"]

        // Try premium quality first
        if let premium = englishVoices.first(where: { $0.quality == .premium }) {
            return premium
        }

        // Try enhanced quality
        if let enhanced = englishVoices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }

        // Try known good voices
        for name in premiumVoiceNames {
            if let voice = englishVoices.first(where: { $0.name.contains(name) }) {
                return voice
            }
        }

        // Fallback to any en-US voice
        return AVSpeechSynthesisVoice(language: "en-US")
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
