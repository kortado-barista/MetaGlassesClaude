// ContentView.swift
// Main SwiftUI interface for the Ray-Ban Meta Glasses ↔ Claude app.

import SwiftUI
import Speech

struct ContentView: View {

    @ObservedObject var glassesManager: GlassesManager
    @StateObject private var voiceInput = VoiceInputManager()
    @StateObject private var claude = ClaudeClient()
    @StateObject private var tts = TTSManager()

    @State private var includeCamera = true
    @State private var errorMessage: String?
    @State private var hasPermissions = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                connectionBanner
                cameraPreview
                conversationList
                Spacer(minLength: 0)
                bottomControls
            }
            .navigationTitle("Glasses + Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { clearButton }
            .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
            .task { await setup() }
        }
    }

    // MARK: - Sub-views

    private var connectionBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(glassesManager.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(glassesManager.connectionState.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !glassesManager.isConnected {
                Button("Connect") {
                    glassesManager.startConnecting()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            } else {
                Button("Disconnect") {
                    glassesManager.disconnect()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var cameraPreview: some View {
        if glassesManager.hasVideoContent {
            CameraLayerView(layer: glassesManager.displayLayer)
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    Label("Live View", systemImage: "camera.fill")
                        .font(.caption2)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
                .padding(.horizontal)
                .padding(.top, 8)
        }
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(claude.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }

                    // Live transcript while recording
                    if !voiceInput.liveTranscript.isEmpty {
                        HStack {
                            Image(systemName: "mic.fill")
                                .foregroundStyle(.red)
                            Text(voiceInput.liveTranscript)
                                .italic()
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .padding(.horizontal)
                    }

                    // Loading indicator
                    if claude.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Claude is thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
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
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            Divider()

            Toggle(isOn: $includeCamera) {
                Label(
                    includeCamera ? "Camera: On" : "Camera: Off",
                    systemImage: includeCamera ? "camera.fill" : "camera.slash.fill"
                )
                .font(.subheadline)
            }
            .toggleStyle(.button)
            .tint(includeCamera ? .blue : .gray)
            .disabled(!glassesManager.isConnected)

            PushToTalkButton(
                voiceInput: voiceInput,
                onRelease: handleUtteranceComplete
            )

            if tts.isSpeaking {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.blue)
                    Text("Speaking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Stop") { tts.stop() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .tint(.red)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
        .background(.ultraThinMaterial)
    }

    private var clearButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Clear") {
                claude.clearHistory()
            }
            .disabled(claude.messages.isEmpty)
        }
    }

    // MARK: - Actions

    private func setup() async {
        let granted = await voiceInput.requestAuthorization()
        hasPermissions = granted
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
        ZStack {
            Circle()
                .fill(isRecording ? Color.red : Color.blue)
                .frame(width: 80, height: 80)
                .scaleEffect(isRecording ? 1.1 : 1.0)
                .animation(.spring(response: 0.2), value: isRecording)
                .shadow(color: (isRecording ? Color.red : Color.blue).opacity(0.4),
                        radius: isRecording ? 12 : 4)

            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
                .onChanged { _ in
                    if !isRecording {
                        voiceInput.startRecording()
                    }
                }
                .onEnded { _ in
                    voiceInput.stopRecording()
                    // Wait briefly for final recognition result, then fire callback
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let text = voiceInput.finalTranscript
                        if !text.isEmpty {
                            onRelease(text)
                        }
                    }
                }
        )

        Text(isRecording ? "Release to send" : "Hold to speak")
            .font(.caption)
            .foregroundStyle(.secondary)
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

// MARK: - CameraLayerView

import AVFoundation

struct CameraLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    class HostView: UIView {
        var videoLayer: AVSampleBufferDisplayLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            videoLayer?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.layer.addSublayer(layer)
        view.videoLayer = layer
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.setNeedsLayout()
    }
}

// MARK: - Preview

#Preview {
    ContentView(glassesManager: GlassesManager())
}
