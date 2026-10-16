import SwiftUI

/// "Your voice": a one-time ~30 s reading that teaches meetings to find the
/// user on the mic by voice (see `Voiceprint` / `VoiceActivity`). Captured
/// raw, without Apple's voice processing, because meetings record the mic
/// raw too: the print should sound like what it will be compared with.
struct VoiceprintSection: View {
    @State private var voiceprint = VoiceprintStore.load()
    /// Made when a reading starts: a @State initial value is evaluated on
    /// every init of the view, and this one builds an audio engine.
    @State private var capture: UtteranceCapture?
    @State private var phase: Phase = .idle
    @State private var error: String?
    @State private var ticker: Task<Void, Never>?

    enum Phase: Equatable { case idle, recording, learning }

    static let targetSeconds = 30.0
    static let minimumSeconds = 15.0

    /// Plain, varied sentences: every vowel and most consonants, spoken at
    /// a natural pace. Any language works; the voice is what is learned.
    static let passage = """
    When the meeting starts, I usually say hello, ask how everyone is doing, and then we look at the plan for the week. \
    Some of it is quick: a date, a number, a decision. Some of it takes longer, because we have to think it through together. \
    Afterwards I like to read back what we agreed, so nobody has to guess who said what.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("Your voice")
                .font(AppFont.text(13, weight: .bold))
            Text(status)
                .font(AppFont.text(11))
                .foregroundStyle(AppColor.ink2)
                .frame(maxWidth: 520, alignment: .leading)

            if phase != .idle || voiceprint == nil {
                Text(Self.passage)
                    .font(AppFont.text(13))
                    .foregroundStyle(phase == .recording ? AppColor.ink : AppColor.ink3)
                    .lineSpacing(3)
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(AppMetric.m)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.55)))
            }

            if phase == .recording {
                ProgressView(value: min(elapsed, Self.targetSeconds), total: Self.targetSeconds)
                    .frame(maxWidth: 520)
                    .tint(AppColor.accent)
            }

            HStack(spacing: AppMetric.s) {
                switch phase {
                case .idle:
                    TapButton(action: startRecording) {
                        LitButtonChrome(voiceprint == nil ? .primary : .secondary, compact: true) {
                            Text(voiceprint == nil ? "Record my voice" : "Record again")
                        }
                    }
                    if voiceprint != nil {
                        TapButton(action: forget) {
                            LitButtonChrome(.ghost, compact: true) { Text("Forget my voice") }
                        }
                    }
                case .recording:
                    TapButton(action: finishRecording) {
                        LitButtonChrome(.accent, compact: true) {
                            Text(elapsed >= Self.minimumSeconds ? "Done" : "Keep reading… \(Int(Self.minimumSeconds - elapsed)) s")
                        }
                    }
                    .disabled(elapsed < Self.minimumSeconds)
                    TapButton(action: cancelRecording) {
                        LitButtonChrome(.ghost, compact: true) { Text("Cancel") }
                    }
                case .learning:
                    ProgressView().controlSize(.small)
                    Text("Learning your voice…").font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                }
            }

            if let error {
                Text(error)
                    .font(AppFont.text(11))
                    .foregroundStyle(AppColor.accentOnLight)
                    .frame(maxWidth: 520, alignment: .leading)
            }
        }
        .onDisappear { if phase == .recording { cancelRecording() } }
        .onReceive(NotificationCenter.default.publisher(for: VoiceprintStore.didChange)) { _ in
            voiceprint = VoiceprintStore.load()
        }
    }

    private var elapsed: Double { capture?.elapsedSeconds ?? 0 }

    private var status: String {
        switch phase {
        case .recording:
            return "Read the passage aloud at your normal meeting volume, in whatever language you use. It stops by itself after \(Int(Self.targetSeconds)) seconds."
        case .learning:
            return "Learning your voice…"
        case .idle:
            if let print = voiceprint {
                let date = print.created.formatted(date: .abbreviated, time: .omitted)
                let quality = print.selfSimilarity < 0.6
                    ? " The reading sounded mixed, as if someone else or a lot of noise was in it; recording again in a quiet room will make it sharper."
                    : ""
                return "Learned from \(Int(print.seconds.rounded())) s of your voice on \(date). Meetings find you on the mic by your voice. What the speakers play is never taken for you, your words survive when you talk over someone, and your voice coming back in the call audio is recognised as yours.\(quality)"
            }
            if VoiceprintStore.isUnreadable {
                return "Your saved voice print can no longer be read (it is damaged or was made by an older model), so meetings use the loudness timeline. Record it again below."
            }
            return "Read a short passage aloud once, about 30 seconds, with the microphone you use for meetings. Meetings then find you by your voice instead of by loudness. Without it they fall back to the loudness timeline. The recording stays on this Mac."
        }
    }

    private func startRecording() {
        error = nil
        Task { @MainActor in
            do {
                let capture = self.capture ?? UtteranceCapture()
                self.capture = capture
                capture.voiceProcessing = false
                try await capture.start()
                phase = .recording
                ticker = Task { @MainActor in
                    while !Task.isCancelled, phase == .recording {
                        if elapsed >= Self.targetSeconds { finishRecording(); break }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            } catch {
                self.error = error.localizedDescription
                phase = .idle
            }
        }
    }

    private func finishRecording() {
        guard phase == .recording, let capture, elapsed >= Self.minimumSeconds else { return }
        ticker?.cancel()
        let samples = capture.stop()
        phase = .learning
        Task { @MainActor in
            do {
                let p = try await VoiceEmbedder.shared.enroll(samples)
                try VoiceprintStore.save(p, audio: samples)
                AppLog.info("voice", "voice print enrolled: \(p.embeddings.count) windows, \(Int(p.seconds)) s, self-similarity \(String(format: "%.2f", p.selfSimilarity))")
                voiceprint = p
            } catch {
                self.error = error.localizedDescription
                AppLog.warn("voice", "enrollment failed: \(error.localizedDescription)")
            }
            phase = .idle
        }
    }

    private func cancelRecording() {
        ticker?.cancel()
        _ = capture?.stop()
        phase = .idle
    }

    private func forget() {
        VoiceprintStore.delete()
        voiceprint = nil
        AppLog.info("voice", "voice print deleted")
    }
}
