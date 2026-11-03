import XCTest
import AVFoundation
@testable import Transcriberr

/// Regression tests for fixes in Transcriberr/Audio. Everything lives in the
/// temporary directory; no audio device is opened.
final class AudioBugfixTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriberr-audiofix-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The AVAudioFile fallback must mix a stereo file down, like the
    /// AVAssetReader path: a 2 → 1 converter without `downmix` keeps only
    /// the left channel, so a voice on the right decoded as silence.
    func testAudioFileFallbackMixesStereoDown() throws {
        let url = dir.appendingPathComponent("right-only.wav")
        let fmt = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                              channels: 2, interleaved: false))
        let frames = 16_000
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)))
            buf.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                buf.floatChannelData![0][i] = 0                          // left: silent
                buf.floatChannelData![1][i] = sin(Float(i) / 10) * 0.5   // right: the voice
            }
            try file.write(from: buf)
        }   // file closed here

        let mono = try AudioDecoder.decodeViaAudioFile(url)
        XCTAssertGreaterThan(mono.count, frames / 2)
        let peak = mono.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "the right channel must reach the mono decode")
    }
}
