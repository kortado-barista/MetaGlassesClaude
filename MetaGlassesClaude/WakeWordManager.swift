// WakeWordManager.swift
// Always-on wake word detection (e.g. "Hey Claude") via Picovoice Porcupine.
//
// SETUP REQUIRED before enabling:
//   1. Add the Porcupine iOS SDK via Swift Package Manager:
//      File → Add Package Dependencies → https://github.com/Picovoice/porcupine
//   2. Get a free access key at https://console.picovoice.ai
//   3. Add to Config.swift:  static let porcupineAccessKey = "YOUR_KEY_HERE"
//   4. Either use a built-in keyword (e.g. .jarvis) or train a custom "Hey Claude"
//      at https://console.picovoice.ai/ppn, then add the .ppn file to the project.
//   5. Set wakeWordEnabled = true below and uncomment the Porcupine code.

import Foundation
import Combine

// MARK: - Enable flag

/// Set to true after completing the Porcupine SDK setup above.
private let wakeWordEnabled = false

// MARK: - WakeWordManager

@MainActor
final class WakeWordManager: ObservableObject {

    @Published var isListening = false

    /// Fires on the main actor each time the wake word is detected.
    let detectedPublisher = PassthroughSubject<Void, Never>()

    private var porcupineManager: AnyObject?

    func start() {
        guard !isListening else { return }
        guard wakeWordEnabled else {
            print("[WakeWord] Disabled — complete Porcupine setup in WakeWordManager.swift first")
            return
        }
        startPorcupine()
        isListening = true
    }

    func stop() {
        stopPorcupine()
        isListening = false
    }

    // MARK: - Porcupine integration
    //
    // After adding the Porcupine SPM package, replace the two stub functions below
    // with the following (also add `import Porcupine` at the top of this file):
    //
    // private func startPorcupine() {
    //     do {
    //         let manager = try PorcupineManager(
    //             accessKey: Config.porcupineAccessKey,
    //             keyword: .jarvis,           // swap for .init(keywordPath:) with your .ppn
    //             onDetection: { [weak self] _ in
    //                 Task { @MainActor [weak self] in
    //                     self?.detectedPublisher.send()
    //                 }
    //             }
    //         )
    //         try manager.start()
    //         porcupineManager = manager
    //     } catch {
    //         print("[WakeWord] PorcupineManager init failed: \(error)")
    //     }
    // }
    //
    // private func stopPorcupine() {
    //     (porcupineManager as? PorcupineManager)?.stop()
    //     porcupineManager = nil
    // }

    private func startPorcupine() {
        // Stub — replace with Porcupine implementation after SDK setup.
    }

    private func stopPorcupine() {
        // Stub — replace with Porcupine implementation after SDK setup.
    }
}
