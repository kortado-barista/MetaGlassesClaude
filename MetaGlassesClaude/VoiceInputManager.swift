// VoiceInputManager.swift
// Manages live speech recognition using Apple's Speech framework.
// Configures AVAudioSession so the glasses' Bluetooth HFP mic is preferred
// as the input source when the glasses are connected.

import Foundation
import Speech
import AVFoundation
import Combine

enum VoiceInputState {
    case idle
    case recording
    case processing
    case error(String)
}

@MainActor
final class VoiceInputManager: ObservableObject {

    @Published var state: VoiceInputState = .idle
    @Published var liveTranscript = ""   // updates in real time while recording
    @Published var finalTranscript = ""  // set when utterance is complete

    /// Called automatically when an utterance is finalized.
    var onUtteranceComplete: ((String) -> Void)?

    // MARK: - Private

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        // Speech recognition
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        // Microphone
        if #available(iOS 17.0, *) {
            let micStatus = await AVAudioApplication.requestRecordPermission()
            return micStatus
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Recording lifecycle

    func startRecording() {
        guard audioEngine.isRunning == false else { return }

        do {
            try configureAudioSession()
            try beginRecognition()
            state = .recording
            liveTranscript = ""
            finalTranscript = ""
        } catch {
            state = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard audioEngine.isRunning else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        state = .processing
        // recognitionTask completion handler will finalize the transcript
    }

    // MARK: - Audio session

    /// Configure AVAudioSession so that the glasses' Bluetooth HFP microphone
    /// is used as the audio input when the glasses are connected.
    ///
    /// iOS automatically routes the audio input to the most recently connected
    /// Bluetooth HFP device when `.allowBluetooth` is set. The Ray-Ban Meta
    /// glasses register as a Bluetooth headset (HFP), so their mic will be
    /// preferred over the phone mic while they are connected.
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [
                .allowBluetooth,       // enables HFP (mic input from BT device)
                .allowBluetoothA2DP,   // allows high-quality BT audio output
                .defaultToSpeaker      // fallback output when BT is absent
            ]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Speech recognition

    private func beginRecognition() throws {
        // Cancel any in-flight task
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Use on-device recognition when available (faster, works offline)
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw VoiceInputError.recognizerUnavailable
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finalize(transcript: result.bestTranscription.formattedString)
                    }
                }

                if let error {
                    // NSURLErrorDomain -1001 / kLSRErrorDomain 301 are normal "end of speech"
                    let nsError = error as NSError
                    let isNormalEnd = nsError.code == 301 || nsError.code == 1110
                    if !isNormalEnd {
                        self.state = .error("Recognition error: \(error.localizedDescription)")
                    }
                    if self.audioEngine.isRunning {
                        self.audioEngine.stop()
                        self.recognitionRequest?.endAudio()
                    }
                }
            }
        }

        // Remove any existing tap before installing a new one
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func finalize(transcript: String) {
        finalTranscript = transcript
        liveTranscript = ""
        state = .idle
        recognitionTask = nil
        recognitionRequest = nil
        if !transcript.isEmpty {
            onUtteranceComplete?(transcript)
        }
    }
}

// MARK: - Errors

enum VoiceInputError: LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer is not available. Check your internet connection or device settings."
        }
    }
}
