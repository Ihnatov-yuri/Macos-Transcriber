import Foundation

/// The JSON body each cloud API is sent, built in one place per provider.
/// What a model accepts changes per model, and a parameter it does not take
/// is an HTTP 400, not a warning: Claude Opus 4.7 and later reject sampling
/// parameters, Gemini 2.5 counts thinking against `maxOutputTokens`, and
/// OpenAI reasoning models take neither `temperature` nor `max_tokens`.
/// `CloudRequestTests` pins each rule.
nonisolated enum CloudRequests {
    enum Models {
        static let anthropic = "claude-opus-4-7"
        static let openAIText = "gpt-4o"
        static let openAIAudio = "whisper-1"
        static let gemini = "gemini-2.5-pro"
    }

    // MARK: - Anthropic

    /// No `temperature`, `top_p` or `top_k`: current Claude models answer
    /// any of them with HTTP 400.
    static func anthropicText(model: String, system: String, user: String, maxTokens: Int) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
    }

    // MARK: - OpenAI

    /// o-series and GPT-5 models reason before they answer.
    static func isOpenAIReasoningModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return ["o1", "o3", "o4", "gpt-5"].contains { m.hasPrefix($0) }
    }

    /// Reasoning models reject `temperature` and `max_tokens` and take
    /// `max_completion_tokens`, which also covers their reasoning.
    static func openAIText(model: String, system: String, user: String, maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if isOpenAIReasoningModel(model) {
            body["max_completion_tokens"] = maxTokens
        } else {
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.3
        }
        return body
    }

    // MARK: - Gemini

    /// 2.5 Pro cannot turn thinking off (its minimum budget is 128); Flash
    /// and Flash-Lite take 0.
    static func geminiThinkingBudget(for model: String) -> Int {
        model.contains("flash") ? 0 : 128
    }

    /// Thinking tokens count against `maxOutputTokens`: a 32-token title
    /// would be spent thinking and come back MAX_TOKENS. Thinking is held to
    /// the model's floor and that floor is added on top.
    static func geminiText(model: String, system: String, user: String, maxTokens: Int) -> [String: Any] {
        let thinking = geminiThinkingBudget(for: model)
        return [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": maxTokens + thinking,
                "thinkingConfig": ["thinkingBudget": thinking],
            ],
        ]
    }

    /// Transcription needs no reasoning: thinking at the model's floor, with
    /// room left for a dense 30 s chunk.
    static func geminiAudio(model: String, wavBase64: String, prompt: String) -> [String: Any] {
        [
            "contents": [[
                "role": "user",
                "parts": [
                    ["inline_data": ["mime_type": "audio/wav", "data": wavBase64]],
                    ["text": prompt],
                ],
            ]],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 4096,
                "thinkingConfig": ["thinkingBudget": geminiThinkingBudget(for: model)],
            ],
        ]
    }
}
