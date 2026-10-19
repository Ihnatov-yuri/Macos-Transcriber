import XCTest
import AVFoundation
@testable import Transcriberr

/// 4.5.2: an engine that could not read a part says so, instead of the part
/// coming back as empty text with no error.
final class RunGapTests: XCTestCase {
    func testGapMessage() {
        XCTAssertNil(RunGapLog.message([:]))
        XCTAssertEqual(RunGapLog.message([.outOfTime: 1]),
                       "1 part of this recording has no text: the engine ran out of time, probably because the Mac was busy. Run it again to fill it in.")
        XCTAssertEqual(RunGapLog.message([.wedged: 2]),
                       "2 parts of this recording have no text: the engine hung on it twice. Run it again to fill them in.")
        RunGapLog.reset()
        RunGapLog.record(.outOfTime); RunGapLog.record(.wedged)
        XCTAssertEqual(RunGapLog.take(), [.outOfTime: 1, .wedged: 1])
        XCTAssertEqual(RunGapLog.take(), [:], "taken once")
    }

    func testBudgetErrorSaysWhatHappened() {
        let e = WhisperBackend.DecodeBudgetExceeded(chunkSeconds: 26, seconds: 101)
        XCTAssertEqual(e.localizedDescription,
                       "Whisper ran out of time on a 26 s part (stopped after 101 s); the Mac was probably busy.")
    }

    // MARK: Super keeps the engine that answered

    private actor FakeEngine: ASRBackend, DetailedTranscribing {
        nonisolated let id: String
        let text: String?
        private(set) var calls = 0
        var isReady: Bool { true }
        init(id: String, text: String?) { self.id = id; self.text = text }
        func load(modelPath: URL?) async throws {}
        func release() async {}
        func recoverWedge(modelPath: URL?) async throws {}
        func generateText(systemInstruction: String, userMessage: String, maxTokens: Int) async throws -> String { "" }
        func transcribeChunk(samples: [Float], languages: Set<String>, translateTo: String?, diarize: Bool,
                             previousContext: String?, speakerHints: [SpeakerHint]) async throws -> String {
            try await transcribeDetailed(samples: samples, languages: languages).text
        }
        func transcribeDetailed(samples: [Float], languages: Set<String>) async throws -> DetailedTranscription {
            calls += 1
            guard let text else { throw WhisperBackend.DecodeBudgetExceeded(chunkSeconds: 26, seconds: 101) }
            let words = text.split(separator: " ").map {
                ScoredWord(surface: String($0), norm: $0.lowercased(), confidence: 0.9)
            }
            return DetailedTranscription(text: text, words: words)
        }
    }

    private var speech: [Float] { (0..<(16_000 * 3)).map { sin(Float($0) * 0.05) * 0.2 } }

    @MainActor
    func testSuperKeepsParakeetWhenWhisperRunsOutOfTimeAndAsksWhisperOnce() async throws {
        let factory = BackendFactory(gemma: GemmaSettingsStore(), prompts: PromptStore(), apiKeys: APIKeyStore())
        let ens = EnsembleBackend(factory: factory)
        let whisper = FakeEngine(id: "whisper", text: nil)
        let parakeet = FakeEngine(id: "parakeet", text: "the plan for the week")
        await ens.useEnginesForTesting(whisper, .whisper, parakeet, .parakeet)

        let text = try await ens.transcribeChunk(samples: speech, languages: ["English"], translateTo: nil,
                                                 diarize: false, previousContext: nil, speakerHints: [])
        XCTAssertEqual(text, "the plan for the week")
        let wCalls = await whisper.calls, pCalls = await parakeet.calls
        XCTAssertEqual(wCalls, 1, "a chunk past its budget is not decoded a second time")
        XCTAssertEqual(pCalls, 1)

        let rich = try await ens.transcribeChunkRich(samples: speech, languages: ["English"])
        XCTAssertEqual(rich.text, "the plan for the week")
        let wCalls2 = await whisper.calls
        XCTAssertEqual(wCalls2, 2)
    }

    // MARK: Decoder

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gap-\(UUID().uuidString.prefix(6)).\(ext)")
    }

    func testSixteenKilohertzMonoFlacDecodes() async throws {
        let url = tempURL("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16]
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        do {
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 32_000)!
            buf.frameLength = 32_000
            for i in 0..<32_000 { buf.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
            try f.write(from: buf)
        } catch {
            throw XCTSkip("this macOS cannot write FLAC: \(error)")
        }
        let samples = try await AudioDecoder().decodeAll(file: url)
        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 400)
    }

    func testUndecodableFileNamesBothReadersReasons() async throws {
        let url = tempURL("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("fLaC but not really".utf8).write(to: url)
        do {
            _ = try await AudioDecoder().decodeAll(file: url)
            XCTFail("garbage decoded")
        } catch let e as AudioDecoder.DecoderError {
            let m = e.localizedDescription
            XCTAssertTrue(m.contains("AVAssetReader:"), m)
            XCTAssertTrue(m.contains("AVAudioFile:"), m)
            XCTAssertTrue(m.contains("["), "domain and code are named: \(m)")
        }
    }
}
