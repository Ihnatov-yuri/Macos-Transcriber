import Foundation
import AVFoundation
import Observation

/// Mirror of `audio/AudioPlayerController.kt` and Android's PlayerBar.
/// AVPlayer-backed playback with position tracking for transcript highlight + scrub.
/// `@MainActor` removed — same `_SwiftData_SwiftUI` interaction as
/// `AppContainer` / `WavRecorder`.
@Observable
final class AudioPlayerController: @unchecked Sendable {
    private var player: AVPlayer?
    private var timeObserver: Any?

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false

    /// Lazy-build peak amplitude buckets for the waveform scrubber (200 buckets).
    private(set) var waveform: [Float] = []

    func load(url: URL) {
        teardown()
        waveform = []
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        // AVPlayer fires the callback on the queue we pass (.main), but the
        // closure signature is `@Sendable` so we can't mutate main-isolated
        // state inline. Hop into MainActor with the captured time.
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] t in
            let secs = t.seconds
            Task { @MainActor [weak self] in self?.currentTime = secs }
        }
        player = p
        Task { @MainActor in
            let asset = item.asset
            let dur = try? await asset.load(.duration)
            if let dur, dur.isValid, dur.seconds.isFinite {
                self.duration = dur.seconds
            }
        }
        // Background waveform extraction. The array updates SwiftUI once the
        // peaks are ready — until then the player bar shows the plain track.
        Task.detached(priority: .utility) { [weak self] in
            let peaks = await WaveformLoader.extractPeaks(from: url, buckets: 200)
            await MainActor.run { self?.waveform = peaks }
        }
    }

    func play() { player?.play(); isPlaying = true }
    func pause() { player?.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func teardown() {
        if let p = player, let obs = timeObserver { p.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    // No deinit cleanup: AVPlayer is fine to drop without removing observers
    // (the player object is what owns them). `teardown()` handles in-session
    // cleanup explicitly.
}
