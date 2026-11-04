import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Text-only backend on MLX (Apple's array framework, Metal GPU) for the
/// Gemma 4 models in `ModelCatalog`, loaded from their pinned,
/// checksum-checked download (config.json, safetensors, tokenizer files).
/// Thinking stays off; one generation at a time.
actor MLXTextBackend: ASRBackend, LocalTextBackend {
    nonisolated let id = "mlx-text"
    private(set) var isReady = false
    private let directory: URL
    private let name: String
    private let onUse: (@Sendable () -> Void)?
    private var container: ModelContainer?
    private let queue = GenerationQueue()

    private(set) var lastStats: LocalTextStats?

    /// MLX's reusable-buffer cache (process-wide; MLX runs nothing else here).
    static let bufferCacheBytes = 512 << 20

    init(entry: ModelEntry, onUse: (@Sendable () -> Void)? = nil) {
        self.directory = ModelCatalog.localDirectory(entry)
        self.name = entry.name
        self.onUse = onUse
    }

    var isBusy: Bool { get async { await queue.isBusy } }

    func load(modelPath: URL?) async throws {
        if container != nil { isReady = true; return }
        // Every caller shows this text: say what to do, not which file failed.
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(ModelCatalog.completeMarker).path) else {
            throw ASRError.modelLoadFailed(reason: "\(name) is not downloaded — Settings → Models")
        }
        // MLX keeps freed GPU buffers for reuse, by default as many as the
        // GPU's working set allows: a 13k-token Summary on the 26B left the
        // process at 23.5 GB, 6 GB above the weights and KV cache it needs.
        Memory.cacheLimit = Self.bufferCacheBytes
        do {
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TokenizersLoader())
        } catch {
            throw ASRError.modelLoadFailed(reason: "MLX model at \(directory.path): \(error)")
        }
        isReady = true
    }

    func release() async {
        container = nil
        isReady = false
        Memory.clearCache()
    }

    func recoverWedge(modelPath: URL?) async throws {
        await release()
        try await load(modelPath: modelPath)
    }

    func transcribeChunk(
        samples: [Float],
        languages: Set<String>,
        translateTo: String?,
        diarize: Bool,
        previousContext: String?,
        speakerHints: [SpeakerHint]
    ) async throws -> String {
        throw ASRError.backendUnavailable(reason: "MLX text model is text-only")
    }

    func generateText(
        systemInstruction: String,
        userMessage: String,
        maxTokens: Int
    ) async throws -> String {
        try await queue.enter()
        defer {
            Task { await queue.leave() }
            onUse?()
        }
        if container == nil { try await load(modelPath: nil) }
        guard let container else { throw ASRError.backendUnavailable(reason: "MLX model not loaded") }

        let input = UserInput(
            chat: [.system(systemInstruction), .user(userMessage)],
            additionalContext: ["enable_thinking": false])
        let prepared = try await container.prepare(input: input)
        // The A/B's sampling (temperature 0.4, top-k 40, top-p 0.95).
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.4, topP: 0.95, topK: 40)
        var text = ""
        for await event in try await container.generate(input: prepared, parameters: parameters) {
            switch event {
            case .chunk(let piece):
                text += piece
            case .info(let info):
                lastStats = LocalTextStats(
                    promptTokens: info.promptTokenCount, generatedTokens: info.generationTokenCount,
                    prefillTokensPerSecond: info.promptTokensPerSecond, decodeTokensPerSecond: info.tokensPerSecond,
                    seconds: info.promptTime + info.generateTime)
            case .toolCall, .rejectedToolCall:
                break
            }
        }
        // A timeout cancels this task; the stream then ends early and the
        // half answer must not pass for a whole one.
        try Task.checkCancellation()
        return Self.stripThinking(text)
    }

    /// A template that opens `<think>` in the prompt leaves only the closing
    /// tag. LaTeX symbols become characters here too, so dictation polish,
    /// briefs and titles never paste "$\rightarrow$" anywhere.
    nonisolated static func stripThinking(_ text: String) -> String {
        var text = text
        if let close = text.range(of: "</think>", options: .backwards) {
            text = String(text[close.upperBound...])
        }
        return ModelText.replacingLaTeXSymbols(text.replacingOccurrences(of: "<think>", with: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// swift-transformers' tokenizer behind mlx-swift-lm's protocol (what the
/// package's `#huggingFaceTokenizerLoader` macro expands to, without the
/// macro's swift-syntax build).
private struct TokenizersLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
