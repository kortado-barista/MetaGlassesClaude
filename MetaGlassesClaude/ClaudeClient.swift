// ClaudeClient.swift
// Sends multimodal (text + optional image) messages to the Anthropic Messages API
// and maintains a rolling conversation history for multi-turn context.

import Foundation
import Combine
import UIKit

// MARK: - Message model

struct ConversationMessage: Identifiable {
    let id = UUID()
    let role: String      // "user" or "assistant"
    let text: String
    let image: UIImage?   // only set for user messages that included a frame
    let timestamp: Date

    init(role: String, text: String, image: UIImage? = nil) {
        self.role = role
        self.text = text
        self.image = image
        self.timestamp = Date()
    }
}

// MARK: - ClaudeClient

@MainActor
final class ClaudeClient: ObservableObject {

    @Published var messages: [ConversationMessage] = []
    @Published var isLoading = false

    private let apiKey: String
    private let model: String
    private let maxTokens: Int

    // The raw API payload history (what gets sent to the API).
    // Separate from ConversationMessage so we can include base64 images.
    private var apiHistory: [[String: Any]] = []

    init(
        apiKey: String = Config.anthropicAPIKey,
        model: String = Config.claudeModel,
        maxTokens: Int = Config.maxTokens
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
    }

    // MARK: - Public API

    /// Send a user message with an optional camera frame.
    /// Appends to conversation history so subsequent calls have full context.
    func sendMessage(text: String, image: UIImage? = nil) async throws -> String {
        isLoading = true
        defer { isLoading = false }

        // Build content blocks for the API payload
        var contentBlocks: [[String: Any]] = []

        if let image {
            // Encode on a GCD global queue (not Swift's cooperative pool) so the
            // cooperative pool stays free for latestFrame updates from the decoder.
            let base64: String = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    if let result = Self.jpegBase64(from: image) {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: ClaudeError.imageEncodingFailed)
                    }
                }
            }
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64
                ]
            ])
        }

        contentBlocks.append([
            "type": "text",
            "text": text
        ])

        let userEntry: [String: Any] = [
            "role": "user",
            "content": contentBlocks
        ]
        apiHistory.append(userEntry)

        // Record in the local conversation model
        let userMsg = ConversationMessage(role: "user", text: text, image: image)
        messages.append(userMsg)

        // Call the API
        let responseText = try await callAPI()

        // Record the assistant response
        let assistantEntry: [String: Any] = [
            "role": "assistant",
            "content": [["type": "text", "text": responseText]]
        ]
        apiHistory.append(assistantEntry)
        messages.append(ConversationMessage(role: "assistant", text: responseText))

        return responseText
    }

    /// Send a one-shot query that does NOT appear in conversation history.
    /// Returns nil when Claude indicates nothing noteworthy (used for proactive alerts).
    func sendSilentQuery(prompt: String, image: UIImage?) async throws -> String? {
        var contentBlocks: [[String: Any]] = []

        if let image {
            let base64: String = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    if let result = Self.jpegBase64(from: image) {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: ClaudeError.imageEncodingFailed)
                    }
                }
            }
            contentBlocks.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]
            ])
        }
        contentBlocks.append(["type": "text", "text": prompt])

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 150,
            "system": """
                You are a passive awareness assistant in a pair of smart glasses. \
                Respond with one concise sentence only if there is something genuinely \
                important or useful to flag (hazard, urgent text, notable event). \
                If there is nothing noteworthy, respond with exactly: nothing
                """,
            "messages": [["role": "user", "content": contentBlocks]]
        ]

        let response = try await callAPIWithPayload(payload)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("nothing") ? nil : trimmed
    }

    /// Prompt for the "Read It Aloud" mode — reads visible text with context.
    static let readAloudPrompt = """
        Look at this image carefully. If there is text visible (a sign, menu, label, \
        document, screen, etc.), read it aloud naturally and add brief helpful context \
        (for example: 'This is a restaurant menu. The specials today are…'). \
        If there is no readable text, describe what you see in one sentence.
        """

    /// Clear conversation history (starts a fresh session).
    func clearHistory() {
        messages.removeAll()
        apiHistory.removeAll()
    }

    // MARK: - API call

    private func callAPI() async throws -> String {
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": """
                You are a friendly assistant built into a pair of smart glasses. \
                Responses are read aloud via text-to-speech, so be warm but very brief — \
                1-2 sentences maximum. No lists, no markdown, no filler phrases. \
                Get straight to the point.
                """,
            "messages": apiHistory
        ]
        return try await callAPIWithPayload(payload)
    }

    private func callAPIWithPayload(_ payload: [String: Any]) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            throw ClaudeError.apiError(statusCode: httpResponse.statusCode, body: body)
        }

        return try parseResponse(data: data)
    }

    // MARK: - Parsing

    private func parseResponse(data: Data) throws -> String {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let first = content.first,
            let text = first["text"] as? String
        else {
            throw ClaudeError.unexpectedResponseShape
        }
        return text
    }

    // MARK: - Helpers

    /// Encode UIImage to JPEG base64.
    /// Resizes to max 640px wide first — keeps the payload small (~80-150KB)
    /// so the WiFi upload finishes quickly and doesn't interfere with Bluetooth.
    private nonisolated static func jpegBase64(from image: UIImage) -> String? {
        let scaled = image.scaledToMaxWidth(640)
        var quality: CGFloat = 0.7
        while quality >= 0.1 {
            if let data = scaled.jpegData(compressionQuality: quality),
               data.count <= 1_000_000 {
                return data.base64EncodedString()
            }
            quality -= 0.2
        }
        return nil
    }
}

// MARK: - Errors

enum ClaudeError: LocalizedError {
    case imageEncodingFailed
    case invalidResponse
    case apiError(statusCode: Int, body: String)
    case unexpectedResponseShape

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Failed to encode camera frame as JPEG."
        case .invalidResponse:
            return "Received an invalid response from the server."
        case .apiError(let code, let body):
            return "API error \(code): \(body)"
        case .unexpectedResponseShape:
            return "Claude returned an unexpected response format."
        }
    }
}

// MARK: - UIImage helpers

private extension UIImage {
    /// Returns a copy scaled so the longer dimension is ≤ maxWidth.
    /// If the image is already smaller, returns self unchanged.
    func scaledToMaxWidth(_ maxWidth: CGFloat) -> UIImage {
        let scale = min(maxWidth / size.width, maxWidth / size.height, 1)
        guard scale < 1 else { return self }
        let newSize = CGSize(width: (size.width * scale).rounded(),
                             height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
