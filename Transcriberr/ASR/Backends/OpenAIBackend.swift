import Foundation
import AVFoundation

/// OpenAI API backend.
///   - ASR via `/v1/audio/transcriptions` (Whisper-1, multipart upload).
///   - Text post-processing via `/v1/chat/completions` (gpt-4o by default).
actor OpenAIBackend: ASRBackend {
    nonisolated let id = "openai"
    private(set) var isReady = false

    private let asrModel: String
    private let textModel: String
    private var apiKey: String?

    init(asrModel: String = "whisper-1", textModel: String = "gpt-4o") {
        self.asrModel = asrModel
        self.textModel = textModel
    }

    func load(modelPath: URL?) async throws {
        let store = APIKeyStore()
        apiKey = store.value(for: .openAI)
        isReady = (apiKey?.isEmpty == false)
        if !isReady {
            throw ASRError.modelLoadFailed(reason: "OpenAI API key not set (Settings → API Keys)")
        }
    }

    func release() async { isReady = false; apiKey = nil }

    // MARK: - Audio (Whisper-1)

    func transcribeChunk(
        samples: [Float],
        languages: Set<String>,
        translateTo: String?,
        diarize: Bool,
        previousContext: String?,
        speakerHints: [SpeakerHint]
    ) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw ASRError.modelLoadFailed(reason: "OpenAI API key missing")
        }

        // Write the chunk to a temp WAV — same approach we use for Gemma.
        let wav = try writeTempWav(samples: samples, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: wav) }

        let endpoint = translateTo == "English"
            ? "https://api.openai.com/v1/audio/translations"
            : "https://api.openai.com/v1/audio/transcriptions"

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func part(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        part("model", asrModel)
        part("response_format", "text")
        if let lang = languages.first, languages.count == 1 {
            part("language", iso639(lang))
        }
        if let ctx = previousContext, !ctx.isEmpty {
            part("prompt", String(ctx.suffix(220)))
        }

        // file
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: wav))
        body.appendString("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, data: data)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Text (Chat Completions)

    func generateText(
        systemInstruction: String,
        userMessage: String,
        maxTokens: Int
    ) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw ASRError.modelLoadFailed(reason: "OpenAI API key missing")
        }

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": textModel,
            "max_tokens": maxTokens,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": systemInstruction],
                ["role": "user", "content": userMessage]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let choices = json?["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let content = msg["content"] as? String {
            return content
        }
        throw ASRError.backendUnavailable(reason: "OpenAI returned unexpected payload.")
    }

    // MARK: - Helpers

    private func ensureOK(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw ASRError.backendUnavailable(reason: "Non-HTTP response from OpenAI.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ASRError.backendUnavailable(
                reason: "OpenAI HTTP \(http.statusCode): \(body.prefix(300))"
            )
        }
    }

    private func iso639(_ name: String) -> String {
        switch name.lowercased() {
        case "english", "en":     return "en"
        case "arabic", "ar":      return "ar"
        case "ukrainian", "uk":   return "uk"
        case "dutch", "nl":       return "nl"
        default:                  return name.lowercased()
        }
    }

    private func writeTempWav(samples: [Float], sampleRate: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriberr-openai-\(UUID().uuidString).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { throw ASRError.backendUnavailable(reason: "WAV buffer alloc failed") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
        try file.write(from: buffer)
        return url
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
