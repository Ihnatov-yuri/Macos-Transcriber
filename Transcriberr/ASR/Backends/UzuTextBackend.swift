import Foundation
import UzuRuntime

/// Text-only backend on uzu (Mirai's Metal runtime) for Qwen3.5 9B: about
/// twice MLX's decode speed on copy-edits, thanks to the speculator that
/// ships in the model folder. uzu itself lives in the UzuRuntime framework
/// (see `UzuChat` for why).
///
/// The model loads by path from its pinned, checksum-checked download
/// (`ModelCatalog.qwen9B`), so uzu never fetches its catalog from Mirai's
/// server. Thinking stays off; one generation at a time.
actor UzuTextBackend: ASRBackend, LocalTextBackend {
    nonisolated let id = "uzu-text"
    private(set) var isReady = false
    private let directory: URL
    private let name: String
    private let onUse: (@Sendable () -> Void)?
    private var chat: UzuChat?
    private let queue = GenerationQueue()

    private(set) var lastStats: LocalTextStats?

    /// Prompt plus answer. Whole-transcript calls (a Ukrainian Summary of an
    /// hour is ~14k tokens in) fit with room for the answer.
    static let contextLength = 32768

    init(entry: ModelEntry, onUse: (@Sendable () -> Void)? = nil) {
        self.directory = ModelCatalog.localDirectory(entry)
        self.name = entry.name
        self.onUse = onUse
    }

    var isBusy: Bool { get async { await queue.isBusy } }

    func load(modelPath: URL?) async throws {
        if chat != nil { isReady = true; return }
        // Every caller shows this text: say what to do, not which file failed.
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(ModelCatalog.completeMarker).path) else {
            throw ASRError.modelLoadFailed(reason: "\(name) is not downloaded — Settings → Models")
        }
        do {
            chat = try await UzuChat(directory: directory, contextLength: Self.contextLength)
        } catch {
            throw ASRError.modelLoadFailed(reason: "uzu model at \(directory.path): \(error.localizedDescription)")
        }
        isReady = true
    }

    func release() async {
        chat = nil
        isReady = false
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
        throw ASRError.backendUnavailable(reason: "Qwen (uzu) is text-only")
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
        if chat == nil { try await load(modelPath: nil) }
        guard let chat else { throw ASRError.backendUnavailable(reason: "uzu model not loaded") }
        // Every call is a fresh conversation: callers send the whole context.
        let reply = try await chat.reply(system: systemInstruction, user: userMessage, maxTokens: maxTokens)
        lastStats = LocalTextStats(
            promptTokens: reply.promptTokens, generatedTokens: reply.generatedTokens,
            prefillTokensPerSecond: reply.prefillTokensPerSecond, decodeTokensPerSecond: reply.decodeTokensPerSecond,
            seconds: reply.seconds)
        return MLXTextBackend.stripThinking(reply.text)
    }
}
