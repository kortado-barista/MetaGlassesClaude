// ContentView.swift
// Main SwiftUI interface for the Ray-Ban Meta Glasses ↔ Claude app.

import SwiftUI
import Speech
import AVFoundation
import Combine

struct ContentView: View {

    @ObservedObject var glassesManager: GlassesManager
    @StateObject private var voiceInput = VoiceInputManager()
    @StateObject private var claude = ClaudeClient()
    @StateObject private var tts = TTSManager()
    @StateObject private var wakeWord = WakeWordManager()

    @State private var includeCamera = true
    @State private var errorMessage: String?
    @State private var showConversation = false
    @State private var proactiveAlertsEnabled = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                cameraSection
                statusStrip
                bottomControls
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showConversation) { conversationSheet }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
        .task { await setup() }
        .task(id: proactiveAlertsEnabled) { await runProactiveAlerts() }
        .onReceive(wakeWord.detectedPublisher) { onWakeWord() }
        .onChange(of: scenePhase) { phase in
            if phase == .background { maintainBackgroundAudio() }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(glassesManager.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(glassesManager.connectionState.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if wakeWord.isListening {
                Label("Listening", systemImage: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .padding(.trailing, 4)
            }

            if !glassesManager.isConnected {
                Button("Connect") { glassesManager.startConnecting() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else {
                Button("Disconnect") { glassesManager.disconnect() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Camera section

    @ViewBuilder
    private var cameraSection: some View {
        if let frame = glassesManager.latestFrame {
            Image(uiImage: frame)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Label("Live", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "camera.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(glassesManager.isConnected ? "Starting camera…" : "Connect glasses to see live view")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Status strip

    @ViewBuilder
    private var statusStrip: some View {
        if !voiceInput.liveTranscript.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text(voiceInput.liveTranscript)
                    .italic()
                    .lineLimit(2)
            }
            .font(.subheadline)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        } else if claude.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Claude is thinking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        } else if tts.isSpeaking {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.blue)
                Text("Speaking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { tts.stop() }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .tint(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 14) {
            // Primary row: Read Aloud · PTT · Conversation
            HStack(spacing: 28) {
                CircleButton(icon: "text.viewfinder", label: "Read", color: .orange, size: 58) {
                    handleReadAloud()
                }
                .disabled(glassesManager.latestFrame == nil || claude.isLoading)

                PushToTalkButton(voiceInput: voiceInput, onRelease: handleUtteranceComplete)

                CircleButton(
                    icon: "bubble.left.and.bubble.right",
                    label: "Chat",
                    color: .purple,
                    size: 58,
                    badge: claude.messages.isEmpty ? nil : "\(claude.messages.count)"
                ) {
                    showConversation = true
                }
            }

            // Secondary row: toggles
            HStack(spacing: 12) {
                Toggle(isOn: $includeCamera) {
                    Label(
                        includeCamera ? "Camera" : "Camera",
                        systemImage: includeCamera ? "camera.fill" : "camera.slash.fill"
                    )
                    .font(.caption)
                }
                .toggleStyle(.button)
                .tint(includeCamera ? .blue : .gray)
                .disabled(!glassesManager.isConnected)
                .controlSize(.small)

                Divider().frame(height: 20)

                Toggle(isOn: $proactiveAlertsEnabled) {
                    Label("Alerts", systemImage: "eye")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .tint(proactiveAlertsEnabled ? .green : .gray)
                .disabled(!glassesManager.isConnected)
                .controlSize(.small)

                Divider().frame(height: 20)

                Toggle(isOn: Binding(
                    get: { wakeWord.isListening },
                    set: { $0 ? wakeWord.start() : wakeWord.stop() }
                )) {
                    Label("Wake", systemImage: "waveform.badge.mic")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .tint(wakeWord.isListening ? .blue : .gray)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    // MARK: - Conversation sheet

    private var conversationSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(claude.messages) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: claude.messages.count) { _ in
                    if let last = claude.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { showConversation = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { claude.clearHistory() }
                        .disabled(claude.messages.isEmpty)
                }
            }
        }
    }

    // MARK: - Actions

    private func setup() async {
        let granted = await voiceInput.requestAuthorization()
        if !granted {
            errorMessage = "Microphone and speech recognition access are required. Enable them in Settings."
        }
        await glassesManager.setup()
        glassesManager.startConnecting()
    }

    private func handleUtteranceComplete(text: String) {
        Task {
            let image = includeCamera ? glassesManager.captureCurrentFrame() : nil
            do {
                let response = try await claude.sendMessage(text: text, image: image)
                tts.speak(response)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleReadAloud() {
        guard let frame = glassesManager.captureCurrentFrame() else { return }
        Task {
            do {
                let response = try await claude.sendMessage(
                    text: ClaudeClient.readAloudPrompt,
                    image: frame
                )
                tts.speak(response)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func onWakeWord() {
        if case .recording = voiceInput.state { return }
        // Route the completed utterance through handleUtteranceComplete
        voiceInput.onUtteranceComplete = { text in
            self.voiceInput.onUtteranceComplete = nil
            self.handleUtteranceComplete(text: text)
        }
        voiceInput.startRecording()
    }

    private func runProactiveAlerts() async {
        guard proactiveAlertsEnabled else { return }
        while !Task.isCancelled && proactiveAlertsEnabled {
            try? await Task.sleep(for: .seconds(60))
            guard proactiveAlertsEnabled, !Task.isCancelled else { break }
            guard let frame = glassesManager.captureCurrentFrame() else { continue }
            if let alert = try? await claude.sendSilentQuery(
                prompt: "Is there anything important or unusual in this scene I should know about?",
                image: frame
            ) {
                tts.speak(alert)
            }
        }
    }

    private func maintainBackgroundAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
        )
        try? session.setActive(true)
    }
}

// MARK: - CircleButton

struct CircleButton: View {
    let icon: String
    let label: String
    let color: Color
    var size: CGFloat = 56
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: size * 0.36, weight: .medium))
                    Text(label)
                        .font(.caption2)
                }
                .frame(width: size, height: size)
                .background(color.opacity(0.85))
                .foregroundStyle(.white)
                .clipShape(Circle())
                .shadow(color: color.opacity(0.4), radius: 4)

                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                        .offset(x: 4, y: -4)
                }
            }
        }
    }
}

// MARK: - PushToTalkButton

/// A press-and-hold button that starts recording on press and stops on release.
struct PushToTalkButton: View {
    @ObservedObject var voiceInput: VoiceInputManager
    let onRelease: (String) -> Void

    @GestureState private var isPressed = false

    private var isRecording: Bool {
        if case .recording = voiceInput.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.blue)
                    .frame(width: 80, height: 80)
                    .scaleEffect(isRecording ? 1.12 : 1.0)
                    .animation(.spring(response: 0.2), value: isRecording)
                    .shadow(
                        color: (isRecording ? Color.red : Color.blue).opacity(0.5),
                        radius: isRecording ? 14 : 5
                    )

                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in state = true }
                    .onChanged { _ in
                        if !isRecording { voiceInput.startRecording() }
                    }
                    .onEnded { _ in
                        voiceInput.stopRecording()
                        // Brief wait for the recognizer to deliver its final result
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let text = voiceInput.finalTranscript
                            if !text.isEmpty { onRelease(text) }
                        }
                    }
            )

            Text(isRecording ? "Release to send" : "Hold to speak")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: ConversationMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if let img = message.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 160, maxHeight: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isUser ? Color.blue : Color(.secondarySystemBackground))
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal)
    }
}

// MARK: - Preview

#Preview {
    ContentView(glassesManager: GlassesManager())
}
