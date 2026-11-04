import Foundation
import Uzu

/// uzu behind a dynamic framework of its own. uzu ships as a static Rust
/// library, and so does FluidAudio's text normalisation
/// (libtext_processing_rs): each carries its own copy of Rust's standard
/// library, and linked into one binary their `_rust_eh_personality`
/// symbols collide. In separate images they never meet.
///
/// The surface is what the app's `UzuTextBackend` needs: load a model
/// folder, answer one system + user turn, report the cost.
public final class UzuChat: @unchecked Sendable {
    public struct Reply: Sendable {
        public let text: String
        public let promptTokens: Int
        public let generatedTokens: Int
        public let prefillTokensPerSecond: Double
        public let decodeTokensPerSecond: Double
        public let seconds: Double
    }

    public enum Failure: Error, LocalizedError {
        case noModel(String)
        case noReply
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .noModel(let path): "uzu found no model at \(path)"
            case .noReply: "uzu returned no reply"
            case .failed(let why): "uzu: \(why)"
            }
        }
    }

    private let engine: Engine
    private let session: ChatSession

    /// Loads the model in `directory` (a pinned Hugging Face folder) by
    /// path, so uzu does not fetch its catalog from Mirai's server.
    /// `contextLength` is prompt plus answer.
    public init(directory: URL, contextLength: Int) async throws {
        engine = try await Engine.create(config: EngineConfig.create())
        guard let model = try await engine.modelByPath(path: directory.path) else {
            throw Failure.noModel(directory.path)
        }
        session = try await engine.chat(model: model, config: ChatConfig.create()
            .withContextLength(contextLength: .custom(length: Int64(contextLength))))
    }

    /// One fresh conversation (callers send the whole context every time),
    /// thinking off, temperature 0.4 / top-k 40 / top-p 0.95. Not
    /// reentrant: the caller runs one at a time.
    ///
    /// Streamed, so that cancelling the calling task (a caller's timeout)
    /// stops the decode: the plain `reply` runs to its token limit after
    /// Swift has given up on it, and holds the model all that time.
    public func reply(system: String, user: String, maxTokens: Int) async throws -> Reply {
        try await session.reset()
        let messages = [
            ChatMessage.system().withReasoningEffort(reasoningEffort: .disabled).withText(text: system),
            ChatMessage.user().withText(text: user),
        ]
        let config = ChatReplyConfig.create()
            .withTokenLimit(tokenLimit: UInt32(max(1, maxTokens)))
            .withSamplingPolicy(samplingPolicy: .custom(method: .stochastic(
                temperature: 0.4, topK: 40, topP: 0.95, minP: nil, repetitionPenalty: nil, suffixRepetitionLength: nil)))
        let stream = await session.replyWithStream(input: messages, config: config)
        let token = stream.cancelToken()
        var last: ChatReply?
        try await withTaskCancellationHandler {
            while let chunk = await stream.next() {
                switch chunk {
                case .replies(let replies): last = replies.last ?? last
                case .error(let error): throw Failure.failed("\(error)")
                case .toolResults: break
                }
            }
        } onCancel: {
            token.cancel()
        }
        try Task.checkCancellation()
        guard let last else { throw Failure.noReply }
        let s = last.stats
        return Reply(
            text: last.message.text() ?? "",
            promptTokens: Int(s.tokensCountInput ?? 0), generatedTokens: Int(s.tokensCountOutput ?? 0),
            prefillTokensPerSecond: s.prefillTokensPerSecond ?? 0, decodeTokensPerSecond: s.generateTokensPerSecond ?? 0,
            seconds: s.duration)
    }
}
