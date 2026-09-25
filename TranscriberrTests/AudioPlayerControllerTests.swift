import XCTest
import AVFoundation
@testable import Transcriberr

/// The shared player is loaded with a new URL every time the Detail view
/// switches recordings. Its observable state must describe the NEW item
/// from the very first frame — the old recording's isPlaying / currentTime /
/// duration leaking through produced a pause glyph over a silent player
/// (first tap = no-op), a highlighted segment from the wrong recording, and
/// a wrong "/ total" until the first observer tick.
@MainActor
final class AudioPlayerControllerTests: XCTestCase {
    var tempFiles: [URL] = []

    override func tearDown() {
        for f in tempFiles { try? FileManager.default.removeItem(at: f) }
        tempFiles = []
    }

    private func makeWav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("player_test_\(UUID().uuidString.prefix(6)).wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
        try f.write(from: buf)
        tempFiles.append(url)
        return url
    }

    func testLoadResetsPlaybackStateFromPreviousItem() async throws {
        let first = try makeWav(seconds: 2)
        let second = try makeWav(seconds: 1)
        let player = AudioPlayerController()

        player.load(url: first)
        player.play()
        XCTAssertTrue(player.isPlaying)
        // Let the periodic observer and the duration load land so the
        // "stale state" being tested is actually populated.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertGreaterThan(player.duration, 0, "precondition: first item's duration was read")

        player.load(url: second)
        XCTAssertFalse(player.isPlaying, "a freshly loaded item is not playing")
        XCTAssertEqual(player.currentTime, 0, "position restarts for the new item")
        XCTAssertEqual(player.duration, 0, "the old item's duration must not be reported for the new one")
    }

    func testPlayAfterReachingEndRestartsFromZero() async throws {
        let url = try makeWav(seconds: 0.5)
        let player = AudioPlayerController()
        player.load(url: url)
        player.play()
        // Wait past the end of the clip: AVPlayer stops on its own and the
        // end-of-item notification must clear isPlaying.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(player.isPlaying, "isPlaying must drop when playback reaches the end")
        XCTAssertGreaterThan(player.currentTime, 0.3, "precondition: playback actually advanced")

        player.play()
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0, "play from the end replays from the start")
    }

    /// The streaming extractor must still deliver the full 200-bucket,
    /// normalised waveform the player bar draws.
    func testWaveformLoadsFullBucketCount() async throws {
        let url = try makeWav(seconds: 3)
        let player = AudioPlayerController()
        player.load(url: url)
        for _ in 0..<50 where player.waveform.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(player.waveform.count, 200)
        XCTAssertEqual(player.waveform.max() ?? 0, 1, accuracy: 1e-6, "peaks are normalised to 1")
    }

    /// A cancelled extraction (another file loaded) gives up instead of
    /// decoding the rest of the file.
    func testCancelledPeakExtractionReturnsEmpty() async throws {
        let url = try makeWav(seconds: 2)
        let task = Task.detached { () -> [Float] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await WaveformLoader.extractPeaks(from: url, buckets: 200)
        }
        let peaks = await task.value
        XCTAssertTrue(peaks.isEmpty)
    }
}
