import Foundation
import Observation

/// Mac port of `asr/TranscriptionJobManager.kt`.
///
/// One job at a time (Gemma 4 engine is process-wide). Subsequent enqueues
/// queue and drain in order. Failures stop the current job but don't drop
/// the queue.
@Observable
final class TranscriptionJobManager: @unchecked Sendable {
    struct Status: Sendable, Identifiable {
        let id: UUID                 // recording.id
        var stage: String
        var fraction: Double
        var failed: Bool
        var failureReason: String?
    }

    private(set) var statuses: [UUID: Status] = [:]

    private let runner: TranscriptionRunner
    private let repository: RecordingRepository
    private var queue: [(Recording, TranscriptionRunner.Params)] = []
    private var currentJob: Task<Void, Never>?

    /// Optional auto-titler. We keep it as a weak indirection so AppContainer
    /// can wire it up after construction without a retain cycle.
    var autoTitler: ((Recording, [Segment], TranscriptionRunner.Params) async -> Void)?

    init(runner: TranscriptionRunner, repository: RecordingRepository) {
        self.runner = runner
        self.repository = repository
    }

    private func shouldAutoTitle(_ title: String) -> Bool {
        title.hasPrefix("Recording ") || title.hasPrefix("Recording_") ||
        title.range(of: #"^[A-Za-z0-9 _\-\.]+$"#, options: .regularExpression) != nil
            && !title.contains(" with ") && !title.contains(":") && title.count < 80
    }

    /// Meeting recordings carry a mic-dominance sidecar (<wav>.me.json) —
    /// ground truth for which diarized speaker is the user. Assign the
    /// configured name (Settings → Engines → My name) to the speaker whose
    /// turns overlap the mic timeline most, unless that speaker was already
    /// named by inference or by hand.
    @MainActor
    private func applySelfNameIfMeeting(_ recording: Recording) {
        let myName = (UserDefaults.standard.string(forKey: "ui.myName") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !myName.isEmpty else { return }
        let wav = URL(fileURLWithPath: recording.audioPath)
        let sidecar = wav.deletingPathExtension().appendingPathExtension("me.json")
        guard let data = try? Data(contentsOf: sidecar),
              let intervals = try? JSONDecoder().decode([[Double]].self, from: data),
              !intervals.isEmpty else { return }

        var overlap: [String: Double] = [:]
        var total: [String: Double] = [:]
        for seg in recording.segments {
            guard let key = seg.speaker else { continue }
            total[key, default: 0] += max(0, seg.endSeconds - seg.startSeconds)
            for iv in intervals where iv.count == 2 {
                overlap[key, default: 0] += max(0, min(seg.endSeconds, iv[1]) - max(seg.startSeconds, iv[0]))
            }
        }
        guard let best = overlap.max(by: { $0.value < $1.value }),
              best.value >= 3,
              best.value >= 0.3 * (total[best.key] ?? .greatestFiniteMagnitude)
        else {
            AppLog.info("job", "meeting self-name: no speaker matches the mic timeline confidently")
            return
        }
        let alreadyNamed = recording.segments.contains {
            $0.speaker == best.key && ($0.speakerName?.isEmpty == false)
        }
        guard !alreadyNamed else { return }
        try? repository.setSpeakerName(myName, for: best.key, in: recording)
        AppLog.info("job", "meeting self-name: \(best.key) → \(myName) (\(Int(best.value))s mic overlap)")
    }

    @MainActor
    private func autoTitle(recording: Recording, segments: [Segment], params: TranscriptionRunner.Params) async {
        await autoTitler?(recording, segments, params)
    }

    func enqueue(_ recording: Recording, params: TranscriptionRunner.Params) {
        statuses[recording.id] = Status(
            id: recording.id, stage: "Queued…", fraction: 0, failed: false, failureReason: nil
        )
        queue.append((recording, params))
        drain()
    }

    func cancel(_ recordingId: UUID) {
        queue.removeAll { $0.0.id == recordingId }
        if statuses[recordingId]?.fraction ?? 0 > 0 {
            currentJob?.cancel()
        }
        statuses.removeValue(forKey: recordingId)
    }

    private func drain() {
        guard currentJob == nil, !queue.isEmpty else { return }
        let (recording, params) = queue.removeFirst()
        currentJob = Task { @MainActor [weak self] in
            defer {
                self?.currentJob = nil
                self?.drain()
            }
            await self?.runOne(recording: recording, params: params)
        }
    }

    // @MainActor is load-bearing: the repository now writes the MAIN
    // ModelContext, and this method previously hopped to a background
    // executor (nonisolated async) — concurrent main-context access crashed
    // SwiftData with dynamicCastFailure mid-run.
    @MainActor
    private func runOne(recording: Recording, params: TranscriptionRunner.Params) async {
        // Rescue snapshot: if the current transcript was never versioned
        // (e.g. produced by an older build), preserve it before wiping —
        // deduped inside snapshotVersion, so post-run snapshots don't double.
        if !recording.segments.isEmpty {
            let prevId = recording.transcribedWithBackend ?? "unknown"
            let prevLabel = BackendFactory.Kind(rawValue: prevId)?.displayName ?? "Earlier run (\(prevId))"
            try? repository.snapshotVersion(of: recording, engineId: prevId, engineLabel: prevLabel)
        }
        recording.transcribedWithBackend = params.backend.rawValue
        recording.translateToEnglish = (params.translateTo == "English")
        AppLog.info("job", "starting recording=\(recording.id.uuidString) backend=\(params.backend.rawValue)")

        var wipedOldTranscript = false
        let stream = runner.run(params)
        var allSegments: [Segment] = []
        do {
            for try await event in stream {
                switch event {
                case .stage(let text, let fraction):
                    statuses[recording.id] = Status(
                        id: recording.id,
                        stage: text,
                        fraction: fraction >= 0 ? fraction : (statuses[recording.id]?.fraction ?? 0),
                        failed: false,
                        failureReason: nil
                    )
                case .partialText:
                    continue
                case .segments(_, let raws):
                    // LAZY WIPE: the old transcript survives until the new
                    // run actually produces output. An interrupted run that
                    // never got this far leaves the previous transcript
                    // completely untouched (no heal needed).
                    if !wipedOldTranscript {
                        try? repository.clearSegments(of: recording)
                        wipedOldTranscript = true
                    }
                    // Live append: turn raws into Segments and persist now.
                    let segs = raws.map { raw in
                        Segment(
                            startSeconds: raw.startSeconds,
                            endSeconds: raw.endSeconds,
                            text: raw.text,
                            speaker: raw.speakerKey,
                            speakerName: raw.speakerName
                        )
                    }
                    do {
                        try repository.appendSegments(segs, to: recording)
                        allSegments.append(contentsOf: segs)
                    } catch {
                        // Non-fatal: keep going so a single save hiccup doesn't kill the run.
                    }
                case .replaceSegments(let start, let end, let raws):
                    // Second-pass refinement: swap out segments in this window.
                    let segs = raws.map { raw in
                        Segment(
                            startSeconds: raw.startSeconds,
                            endSeconds: raw.endSeconds,
                            text: raw.text,
                            speaker: raw.speakerKey,
                            speakerName: raw.speakerName
                        )
                    }
                    do {
                        try repository.replaceSegmentsInRange(start, end, with: segs, for: recording)
                        allSegments.removeAll { $0.startSeconds >= start && $0.endSeconds <= end }
                        allSegments.append(contentsOf: segs)
                    } catch {
                        AppLog.warn("job", "replace failed: \(error.localizedDescription)")
                    }
                case .done(let finalRaws):
                    // The finalize step runs AFTER per-chunk segments were
                    // persisted: it assigns speakers, coalesces chunk slices
                    // into per-speaker turns, and infers speaker names. Its
                    // payload is the authoritative transcript — replace the
                    // live-appended rows with it whenever it differs.
                    let differs = finalRaws.count != allSegments.count
                        || finalRaws.contains { $0.speakerKey != nil || $0.speakerName != nil }
                    if !finalRaws.isEmpty && differs {
                        let segs = finalRaws.map { raw in
                            Segment(
                                startSeconds: raw.startSeconds,
                                endSeconds: raw.endSeconds,
                                text: raw.text,
                                speaker: raw.speakerKey,
                                speakerName: raw.speakerName
                            )
                        }
                        do {
                            try repository.clearSegments(of: recording)
                            try repository.appendSegments(segs, to: recording)
                            allSegments = segs
                            AppLog.info("job", "reconciled to \(segs.count) finalized segments (speakers/turns/names)")
                        } catch {
                            AppLog.warn("job", "final reconcile failed: \(error.localizedDescription)")
                        }
                    }
                    applySelfNameIfMeeting(recording)
                    // Every completed run becomes an immutable version tagged
                    // with its engine, so runs from different engines can be
                    // compared (Detail → VERSIONS) and restored.
                    do {
                        try repository.snapshotVersion(
                            of: recording,
                            engineId: params.backend.rawValue,
                            engineLabel: params.backend.displayName
                        )
                    } catch {
                        AppLog.warn("job", "version snapshot failed: \(error.localizedDescription)")
                    }
                    try? TranscriptExporter.export(recording: recording)
                    statuses[recording.id] = Status(
                        id: recording.id, stage: "Done.", fraction: 1.0, failed: false, failureReason: nil
                    )
                    // Auto-title: only if the title still looks like a default.
                    if !allSegments.isEmpty, shouldAutoTitle(recording.title) {
                        Task { @MainActor [weak self] in
                            await self?.autoTitle(recording: recording, segments: allSegments, params: params)
                        }
                    }
                case .failed(let reason):
                    AppLog.error("job", "stream emitted .failed: \(reason)")
                    statuses[recording.id] = Status(
                        id: recording.id, stage: "Failed: \(reason)",
                        fraction: 1.0, failed: true, failureReason: reason
                    )
                }
            }
        } catch is CancellationError {
            AppLog.warn("job", "cancelled")
            statuses[recording.id] = Status(
                id: recording.id, stage: "Cancelled.", fraction: 1.0, failed: true, failureReason: "cancelled"
            )
        } catch {
            AppLog.error("job", "threw: \(error.localizedDescription)")
            statuses[recording.id] = Status(
                id: recording.id, stage: "Failed: \(error.localizedDescription)",
                fraction: 1.0, failed: true, failureReason: error.localizedDescription
            )
        }
    }
}
