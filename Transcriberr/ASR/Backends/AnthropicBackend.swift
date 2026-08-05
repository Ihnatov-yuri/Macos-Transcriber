import Foundation

/// Anthropic Claude backend.
/// Text-only (Claude has no native audio API). Used for post-processing
/// presets when the user prefers Claude over Gemma / GPT.
actor AnthropicBackend: ASRBackend {
    nonisolated let id = "anthropic"
    private(set) var isReady = false

    private let model: String
    private var apiKey: String?

    init(model: String = "claude-opus-4-7") {
        self.model = model
    }

    func load(modelPath: URL?) async throws {
        let store = APIKeyStore()
        apiKey = store.value(for: .anthropic)
        isReady = (apiKey?.isEmpty == false)
        if !isReady {
            throw ASRError.modelLoadFailed(reason: "Anthropic API key not set (Settings → API Keys)")
        }
    }

    func release() async { isReady = false; apiKey = nil }

    func transcribeChunk(
        samples: [Float],
        languages: Set<String>,
        translateTo: String?,
        diarize: Bool,
        previousContext: String?,
        speakerHints: [SpeakerHint]
    ) async throws -> String {
        throw ASRError.backendUnavailable(
            reason: "Claude has no audio API; use Gemma 4 / OpenAI / Gemini for ASR, then run Claude on the transcript."
        )
    }

    func generateText(
        systemInstruction: String,
        userMessage: String,
        maxTokens: Int
    ) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw ASRError.modelLoadFailed(reason: "Anthropic API key missing")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": 0.3,
            "system": systemInstruction,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw ASRError.backendUnavailable(reason: "Anthropic HTTP \(code): \(body.prefix(300))")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let content = json?["content"] as? [[String: Any]],
           let first = content.first,
           let text = first["text"] as? String {
            return text
        }
        throw ASRError.backendUnavailable(reason: "Anthropic returned unexpected payload.")
    }
}
