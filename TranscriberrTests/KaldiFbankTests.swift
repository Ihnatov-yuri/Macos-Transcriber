import XCTest
@testable import Transcriberr

/// The Swift fbank front end against WeSpeaker's own (torchaudio
/// kaldi.fbank + CMN), on three 3 s windows of real meeting speech written
/// by scripts/voice-model/convert_simam.py.
final class KaldiFbankTests: XCTestCase {
    private func fixture(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "f32"))
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func testMatchesWeSpeakerFrontEnd() throws {
        let waves = try fixture("waves"), ref = try fixture("fbanks")
        XCTAssertEqual(waves.count, 3 * SimAMEmbedder.samples)
        let per = SimAMEmbedder.frames * KaldiFbank.melBins
        XCTAssertEqual(ref.count, 3 * per)
        for w in 0..<3 {
            let got = KaldiFbank.shared.features(waves[(w * SimAMEmbedder.samples)..<((w + 1) * SimAMEmbedder.samples)])
            XCTAssertEqual(got.count, per)
            let want = ref[(w * per)..<((w + 1) * per)]
            let worst = zip(got, want).map { abs($0 - $1) }.max() ?? .infinity
            XCTAssertLessThan(worst, 0.02, "window \(w): largest difference \(worst)")
        }
    }

    func testFrameCountAndWindow() {
        XCTAssertEqual(KaldiFbank.frameCount(48_000), 298)
        XCTAssertEqual(KaldiFbank.frameCount(399), 0)
        let short = ArraySlice([Float](repeating: 0.1, count: 1000))
        XCTAssertEqual(SimAMEmbedder.window(short).count, SimAMEmbedder.samples)
        let long = ArraySlice([Float](repeating: 0.1, count: 100_000))
        XCTAssertEqual(SimAMEmbedder.window(long).count, SimAMEmbedder.samples)
    }

    /// The installed model on top of the front end gives WeSpeaker's
    /// embeddings. Skipped where the model is not downloaded.
    func testEmbeddingsMatchPyTorch() async throws {
        try XCTSkipUnless(SimAMModel.isInstalled(), "high-accuracy voice model not installed")
        let waves = try fixture("waves"), ref = try fixture("embeddings")
        let clips = (0..<3).map { waves[($0 * SimAMEmbedder.samples)..<(($0 + 1) * SimAMEmbedder.samples)] }
        let got = try await SimAMEmbedder.shared.embed(clips)
        for w in 0..<3 {
            let want = VoiceActivity.normalizedMean([Array(ref[(w * 256)..<((w + 1) * 256)])])
            XCTAssertGreaterThan(VoiceActivity.cosine(got[w], want), 0.995, "window \(w)")
        }
    }
}
