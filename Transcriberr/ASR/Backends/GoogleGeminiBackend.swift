import Foundation
import AVFoundation

/// Google Gemini API backend — the closest cloud equivalent to the Android
/// Gemma 4 audio path: one model handles audio in + text out.
actor GoogleGeminiBackend: ASRBackend {
    nonisolated let id = "gemini"
    private(set) var isReady = false

    private let model: String
    private var apiKey: String?

    init(model: String = "gemini-2.5-pro") {
        self.model = model
    }

    func load(modelPath: URL?) async throws {
        let store = APIKeyStore()
        apiKey = store.value(for: .gemini)
        isReady = (apiKey?.isEmpty == false)
        if !isReady {
            throw ASRError.modelLoadFailed(reason: "Google API key not set (Settings → API Keys)")
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
        guard let key = apiKey, !key.isEmpty else {
            throw ASRError.modelLoadFailed(reason: "Gemini API key missing")
        }
        // Same floor as the local engines: a tap-length scrap is silence,
        // not an error to show.
        guard samples.count >= 8_000 else { return "" }   // < 0.5 s @ 16 kHz

        // WAV-encode the chunk and inline-Base64 it. For chunks > 20 MB we'd
        // need the Files API — at 16k mono Float32, 30 s is ~7.6 MB so we're
        // safely under.
        let pcmData = try wavData(samples: samples, sampleRate: 16_000)
        let b64 = pcmData.base64EncodedString()

        // `languages` is a Set: `.first` named an arbitrary one of several
        // hints, and speech in the others came back translated or garbled.
        let names = languages.sorted()
        let action = translateTo == nil
            ? (names.count == 1
                ? "Transcribe the speech in this audio in \(names[0]) into \(names[0]) text. Output only the transcript."
                : names.isEmpty
                    ? "Transcribe the speech in this audio in the language it is spoken in. Do not translate. Output only the transcript."
                    : "Transcribe the speech in this audio. It may be in any of: \(names.joined(separator: ", ")). Keep each utterance in the language it was spoken in — do not translate. Output only the transcript.")
            : "Translate the speech in this audio into idiomatic \(translateTo!). Output only the translation."
        var prompt = action
        if let ctx = previousContext, !ctx.isEmpty {
            prompt = "Previous context: \(ctx)\n\n" + prompt
        }
        if diarize {
            prompt += "\nPrefix each utterance with \"Speaker N:\" using a stable integer per voice."
        }

        let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Header, not `?key=`: a query string ends up in URLError user info,
        // proxy logs and diagnostics.
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["inline_data": ["mime_type": "audio/wav", "data": b64]],
                    ["text": prompt]
                ]
            ]],
            // 2.5 models think by default, and thinking tokens count against
            // maxOutputTokens: at 1024 a chunk could spend them all thinking
            // and come back MAX_TOKENS with no text. Transcription needs
            // no reasoning, so thinking is held to the model's floor, with
            // room left for a dense 30 s chunk.
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 4096,
                "thinkingConfig": ["thinkingBudget": Self.minimalThinkingBudget(for: model)]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, data: data)

        // A 200 with no text part is a REFUSAL, not an empty chunk —
        // finishReason SAFETY or MAX_TOKENS returns exactly this. Swallowing
        // it as "" made the runner record a chunk that produced no text and
        // the run still report success, so the audio vanished silently.
        guard let text = parseFirstText(from: data) else {
            throw ASRError.backendUnavailable(
                reason: "Gemini returned no text for this chunk (blocked or truncated response).")
        }
        return text
    }

    func generateText(
        systemInstruction: String,
        userMessage: String,
        maxTokens: Int
    ) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw ASRError.modelLoadFailed(reason: "Gemini API key missing")
        }
        let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Header, not `?key=`: a query string ends up in URLError user info,
        // proxy logs and diagnostics.
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "system_instruction": ["parts": [["text": systemInstruction]]],
            "contents": [[
                "role": "user",
                "parts": [["text": userMessage]]
            ]],
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": maxTokens
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp, data: data)
        return parseFirstText(from: data) ?? ""
    }

    // MARK: - Helpers

    /// 2.5 Pro cannot turn thinking off (its minimum budget is 128); Flash
    /// and Flash-Lite take 0.
    nonisolated static func minimalThinkingBudget(for model: String) -> Int {
        model.contains("flash") ? 0 : 128
    }

    private func ensureOK(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw ASRError.backendUnavailable(reason: "Non-HTTP response from Gemini.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ASRError.backendUnavailable(
                reason: "Gemini HTTP \(http.statusCode): \(body.prefix(300))"
            )
        }
    }

    private func parseFirstText(from data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let candidates = json?["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    /// Build a minimal RIFF/WAV blob in memory for 16-bit-converted PCM.
    /// Gemini accepts raw audio/wav so we wrap our Float32 samples as Int16.
    private func wavData(samples: [Float], sampleRate: Int) throws -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var pcm = Data()
        pcm.reserveCapacity(samples.count * 2)
        for s in samples {
            let clipped = max(-1.0, min(1.0, s))
            var i16 = Int16(clipped * Float(Int16.max))
            withUnsafeBytes(of: &i16) { pcm.append(contentsOf: $0) }
        }

        var out = Data()
        func add(_ s: String) { out.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        add("RIFF"); u32(UInt32(36 + pcm.count)); add("WAVE")
        add("fmt "); u32(16); u16(1); u16(channels); u32(UInt32(sampleRate))
        u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        add("data"); u32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }
}
