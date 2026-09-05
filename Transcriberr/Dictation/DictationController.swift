import AppKit
import AVFoundation
import Foundation
import Observation

/// Dictation state machine: hotkey → capture → recognize → clean → insert.
///
/// App-lifetime (owned by `AppContainer`) so a session started from the
/// menu bar or the global hotkey never depends on a view being alive. No
/// actor isolation on the type — every mutating method is `@MainActor`
/// individually (same `_SwiftData_SwiftUI` constraint as the other stores).
@Observable
final class DictationController: @unchecked Sendable {

    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case inserting
        /// Transient notice (no mic, nothing heard, copied-only…).
        case message(String)
    }

    /// Where the text goes.
    enum Target: Equatable {
        /// Paste into whatever app has keyboard focus.
        case frontmostApp
        /// Append to the in-app dictation pane.
        case pane
    }

    // MARK: - Observable state

    private(set) var phase: Phase = .idle
    /// Last recognized passage (HUD + pane footer).
    private(set) var lastText = ""
    /// Number of background passes still running in toggle mode.
    private(set) var pendingPasses = 0
    /// In-app editor buffer.
    var paneText = ""
    private(set) var accessibilityTrusted = false
    private(set) var hotkeyArmed = false
    /// Set by `DictationView` while it is on screen: a hotkey press with the
    /// app active then targets the pane instead of pasting into ourselves.
    var paneVisible = false
    private(set) var lastError: String?
    private(set) var sessionCount = 0

    let settings: DictationSettings
    let capture = UtteranceCapture()

    // MARK: - Dependencies

    private let factory: BackendFactory
    private let prompts: PromptStore
    private let repository: RecordingRepository
    private let uiPrefs: UIPrefs
    private let recorder: WavRecorder
    private let meetingRecorder: MeetingRecorder

    // MARK: - Internals

    private var monitor: HotkeyMonitor?
    private var hud: DictationHUD?
    private var target: Target = .frontmostApp
    private var startTask: Task<Void, Never>?
    /// The stop of the previous session (finish or cancel). A new session
    /// awaits it before touching the capture, so a quick restart can never
    /// have its fresh engine torn down by the old session's stop.
    private var teardown: Task<Void, Never>?
    private var flushLoop: Task<Void, Never>?
    private var pipelineTail: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var trustPoll: Task<Void, Never>?
    /// Bumped by cancel(): queued passes from a cancelled session are dropped.
    private var generation = 0
    /// Bumped by begin(): background loops belonging to an older session stop.
    private var sessionID = 0
    private var pressedAt: Date?
    private var comboUsed = false
    private var activationObserver: NSObjectProtocol?

    init(
        settings: DictationSettings,
        factory: BackendFactory,
        prompts: PromptStore,
        repository: RecordingRepository,
        uiPrefs: UIPrefs,
        recorder: WavRecorder,
        meetingRecorder: MeetingRecorder
    ) {
        self.settings = settings
        self.factory = factory
        self.prompts = prompts
        self.repository = repository
        self.uiPrefs = uiPrefs
        self.recorder = recorder
        self.meetingRecorder = meetingRecorder
    }

    // MARK: - Bootstrap

    /// Called once the run loop is up: arms the hotkey (if trusted), re-checks
    /// trust every time the app comes to the front (the user returns from
    /// System Settings), and follows the hotkey preference live.
    @MainActor
    func bootstrap() {
        hud = DictationHUD(controller: self)
        armHotkey()
        watchHotkeySetting()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTrust() }
        }
    }

    @MainActor
    private func watchHotkeySetting() {
        withObservationTracking {
            _ = settings.hotkey
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.armHotkey()
                self.watchHotkeySetting()
            }
        }
    }

    @MainActor
    func refreshTrust() {
        let trusted = HotkeyMonitor.isTrusted()
        if trusted != accessibilityTrusted || (trusted && !hotkeyArmed && settings.hotkey != .off) {
            armHotkey()
        }
    }

    @MainActor
    func armHotkey() {
        monitor?.uninstall()
        monitor = nil
        accessibilityTrusted = HotkeyMonitor.isTrusted()
        guard let code = settings.hotkey.keyCode else {
            hotkeyArmed = false
            return
        }
        guard accessibilityTrusted else {
            hotkeyArmed = false
            AppLog.info("dictation", "hotkey not armed — Accessibility not granted")
            return
        }
        let m = HotkeyMonitor { [weak self] event in
            Task { @MainActor [weak self] in self?.handleHotkey(event) }
        }
        hotkeyArmed = m.install(keyCode: code)
        monitor = m
    }

    /// Shows the system Accessibility prompt, then polls for a minute so the
    /// hotkey arms itself the moment the checkbox is ticked.
    @MainActor
    func requestAccessibility() {
        _ = HotkeyMonitor.isTrusted(prompt: true)
        trustPoll?.cancel()
        trustPoll = Task { @MainActor [weak self] in
            for _ in 0 ..< 60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if HotkeyMonitor.isTrusted() {
                    self.armHotkey()
                    return
                }
            }
        }
    }

    // MARK: - Hotkey handling

    @MainActor
    private func handleHotkey(_ event: HotkeyMonitor.Event) {
        switch event {
        case .pressed:
            pressedAt = Date()
            comboUsed = false
            if settings.mode == .hold, canBegin {
                begin(target: resolveTarget())
            }
        case .otherKeyDown:
            comboUsed = true
            // ⌥-e, ⌘-c … while the key is held: the user wanted the modifier.
            if settings.mode == .hold, phase == .listening { cancel(quiet: true) }
        case .released:
            let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
            pressedAt = nil
            switch settings.mode {
            case .hold:
                guard phase == .listening else { return }
                if held < 0.25 { cancel(quiet: true) } else { finish() }
            case .toggle:
                guard !comboUsed, held < 0.8 else { return }
                toggle(target: resolveTarget())
            }
        }
    }

    private func isMessage(_ p: Phase) -> Bool {
        if case .message = p { return true }
        return false
    }

    @MainActor
    private func resolveTarget() -> Target {
        (NSApp.isActive && paneVisible) ? .pane : .frontmostApp
    }

    // MARK: - Session control

    @MainActor
    func toggle(target: Target) {
        switch phase {
        case .listening:                          finish()
        case .idle, .message, .transcribing, .inserting: begin(target: target)
        }
    }

    /// A new session may start while the previous passage is still being
    /// recognized (the engine is free — capture stopped at finish); only an
    /// active capture blocks.
    private var canBegin: Bool {
        switch phase {
        case .listening: return false
        default:         return true
        }
    }

    /// Menu / keyboard shortcut entry point.
    @MainActor
    func toggleFromMenu() {
        toggle(target: resolveTarget())
    }

    @MainActor
    func begin(target: Target) {
        guard canBegin else { return }
        lastError = nil
        if case .recording = recorder.state {
            showMessage("Stop the recording first"); return
        }
        if case .paused = recorder.state {
            showMessage("Stop the recording first"); return
        }
        if meetingRecorder.isRunning {
            showMessage("Stop the meeting recording first"); return
        }
        messageTask?.cancel()
        self.target = target
        sessionID &+= 1
        let session = sessionID
        phase = .listening
        lastText = ""
        updateHUD()
        playSound("Pop")

        // Warm the engine while the user is still talking.
        let backend = factory.backend(for: settings.engine)
        Task {
            if await !backend.isReady { try? await backend.load(modelPath: nil) }
        }

        let previousTeardown = teardown
        startTask = Task { @MainActor [weak self] in
            await previousTeardown?.value
            guard let self, self.sessionID == session, self.phase == .listening else { return }
            do {
                try await self.capture.start()
            } catch {
                AppLog.error("dictation", "capture failed: \(error.localizedDescription)")
                self.lastError = error.localizedDescription
                self.flushLoop?.cancel()
                self.showMessage(error.localizedDescription)
            }
        }

        if settings.mode == .toggle { startFlushLoop() }
        else { startHoldWatchdog() }
    }

    /// Release / second tap: stop capturing and process the last passage.
    @MainActor
    func finish() {
        guard phase == .listening else { return }
        flushLoop?.cancel()
        flushLoop = nil
        phase = .transcribing
        updateHUD()
        let start = startTask
        let gen = generation
        teardown = Task { @MainActor [weak self] in
            await start?.value
            guard let self else { return }
            let samples = self.capture.stop()
            // A capture failure already replaced the phase with its message.
            guard gen == self.generation, self.phase == .transcribing else { return }
            self.enqueue(samples, final: true)
        }
    }

    @MainActor
    func cancel(quiet: Bool = false) {
        generation &+= 1
        flushLoop?.cancel()
        flushLoop = nil
        let start = startTask
        teardown = Task { @MainActor [weak self] in
            await start?.value
            self?.capture.stop()
        }
        pendingPasses = 0
        if quiet {
            phase = .idle
            updateHUD()
        } else {
            showMessage("Cancelled")
        }
    }

    /// Toggle mode: flush a passage whenever speech is followed by a pause,
    /// so long hands-free dictation lands paragraph by paragraph and a
    /// 10-minute session never becomes one giant chunk.
    @MainActor
    private func startFlushLoop() {
        flushLoop?.cancel()
        let session = sessionID
        flushLoop = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, session == self.sessionID, self.phase == .listening {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard self.capture.isRunning else { continue }
                let silence = self.capture.silenceSeconds
                let buffered = self.capture.bufferedSeconds
                let flushOnPause = self.capture.hasVoiceSinceDrain && silence >= self.settings.pauseFlushSeconds
                // Hard cap: a passage longer than a minute is cut at the next
                // short gap, or at 90 s regardless.
                let flushOnLength = self.capture.hasVoiceSinceDrain
                    && ((buffered >= 60 && silence >= 0.4) || buffered >= 90)
                if flushOnPause || flushOnLength {
                    let samples = self.capture.drain()
                    self.enqueue(samples, final: false)
                }
                if !self.capture.hasVoiceSinceDrain, buffered > 20 {
                    // Nothing but room tone: drop it so silence never
                    // accumulates into a bogus 90 s "utterance".
                    _ = self.capture.drain()
                }
            }
        }
    }

    /// Hold mode safety: a stuck key must not record forever.
    @MainActor
    private func startHoldWatchdog() {
        flushLoop?.cancel()
        let session = sessionID
        flushLoop = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, session == self.sessionID, self.phase == .listening {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if self.capture.elapsedSeconds >= 180 {
                    AppLog.warn("dictation", "hold session hit 180 s — finishing")
                    self.finish()
                    return
                }
            }
        }
    }

    // MARK: - Pipeline

    /// Passes run strictly in order (one shared engine, and the text must
    /// arrive in the order it was spoken).
    @MainActor
    private func enqueue(_ samples: [Float], final: Bool) {
        let gen = generation
        let prior = pipelineTail
        if !final { pendingPasses += 1 }
        pipelineTail = Task { @MainActor [weak self] in
            await prior?.value
            guard let self else { return }
            defer { if !final { self.pendingPasses = max(0, self.pendingPasses - 1) } }
            guard gen == self.generation else { return }
            await self.processUtterance(samples, final: final, generation: gen)
        }
    }

    @MainActor
    private func processUtterance(_ raw: [Float], final: Bool, generation gen: Int) async {
        let seconds = Double(raw.count) / UtteranceCapture.sampleRate
        let samples = UtteranceCapture.applyGain(raw, sensitivity: RecorderSettings.shared.micSensitivity)

        // Empty / silent passes end quietly.
        guard samples.count >= 8_000, Self.hasSpeech(samples) else {
            AppLog.info("dictation", String(format: "skip %.2fs — no speech", seconds))
            if final { showMessage("Nothing heard") }
            return
        }

        let backend = factory.backend(for: settings.engine)
        let text: String
        do {
            if await !backend.isReady {
                try await Self.withTimeout(seconds: 240) { try await backend.load(modelPath: nil) }
            }
            let t0 = Date()
            let recognized = try await Self.withTimeout(seconds: 60) {
                try await backend.transcribeChunk(
                    samples: samples,
                    languages: self.settings.languages,
                    translateTo: nil,
                    diarize: false,
                    previousContext: nil,
                    speakerHints: []
                )
            }
            AppLog.info("dictation", String(
                format: "recognized %.1fs → %d chars in %.2fs", seconds, recognized.count,
                Date().timeIntervalSince(t0)))
            var cleaned = DictationText.process(recognized, options: DictationText.Options(
                destutter: settings.destutter,
                commands: settings.spokenCommands,
                vocabulary: settings.applyVocabulary ? vocabularyTerms() : []
            ))
            if settings.polish, !cleaned.isEmpty {
                cleaned = await polish(cleaned)
            }
            text = cleaned
        } catch {
            AppLog.error("dictation", "recognition failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            showMessage("Recognition failed: \(error.localizedDescription)")
            return
        }
        guard gen == generation else { return }
        guard !text.isEmpty else {
            if final { showMessage("Nothing heard") }
            return
        }

        lastText = text
        sessionCount += 1
        let outcome = deliver(text)

        if settings.keepHistory {
            saveHistory(samples: raw, seconds: seconds, text: text)
        }

        if final {
            playSound("Tink")
            // A new session may already be listening — never clobber it.
            let stillOurs = phase == .transcribing || phase == .inserting
            switch outcome {
            case .pasted, .paneAppended:
                if stillOurs {
                    phase = .idle
                    updateHUD(showResultBriefly: true)
                }
            case .copiedOnly:
                if stillOurs { showMessage("Copied — press ⌘V. Grant Accessibility to auto-insert.") }
            }
        } else if outcome == .copiedOnly {
            // Keep listening, but tell the user once.
            AppLog.warn("dictation", "toggle flush copied only (no Accessibility)")
        }
    }

    private enum DeliveryOutcome: Equatable { case pasted, paneAppended, copiedOnly }

    @MainActor
    private func deliver(_ text: String) -> DeliveryOutcome {
        // The user may have come back to the pane mid-session; never paste
        // into our own window when the pane is what's showing.
        let usePane = target == .pane || (NSApp.isActive && paneVisible)
        if usePane {
            paneText = DictationText.join(existing: paneText, new: text)
            return .paneAppended
        }
        if phase == .transcribing {
            phase = .inserting
            updateHUD()
        }
        let payload = DictationText.forInsertion(text, spacing: settings.spacing)
        switch TextInserter.insert(payload, restoreClipboard: settings.restoreClipboard) {
        case .pasted:
            return .pasted
        case .copiedOnly:
            // Nothing is lost: the pane keeps a copy.
            paneText = DictationText.join(existing: paneText, new: text)
            return .copiedOnly
        }
    }

    // MARK: - Polish (optional Gemma pass)

    @MainActor
    private func polish(_ text: String) async -> String {
        let kind = uiPrefs.textEngine.supportsTextGeneration ? uiPrefs.textEngine : .gemmaLiteRT
        if kind == .gemmaLiteRT,
           !ModelCatalog.entries.contains(where: {
               $0.backend == .gemmaLiteRT
                   && ModelCatalog.cachedRepoDirectory(huggingFaceID: $0.huggingFaceID) != nil
           }) {
            AppLog.warn("dictation", "polish skipped — LiteRT Gemma model not downloaded")
            return text
        }
        let backend = factory.backend(for: kind)
        let vocab = vocabularyTerms()
        var system = settings.polishPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if system.isEmpty { system = DictationSettings.defaultPolishPrompt }
        if !vocab.isEmpty {
            system += "\nVocabulary (authoritative spellings): " + vocab.prefix(60).joined(separator: ", ")
        }
        let systemPrompt = system
        do {
            if await !backend.isReady {
                try await Self.withTimeout(seconds: 120) { try await backend.load(modelPath: nil) }
            }
            let maxTokens = min(1200, text.count / 2 + 120)
            let t0 = Date()
            let out = try await Self.withTimeout(seconds: 45) {
                try await backend.generateText(systemInstruction: systemPrompt, userMessage: text, maxTokens: maxTokens)
            }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.info("dictation", String(format: "polish %d → %d chars in %.1fs",
                                            text.count, trimmed.count, Date().timeIntervalSince(t0)))
            return DictationText.acceptPolished(raw: text, polished: trimmed) ? trimmed : text
        } catch {
            AppLog.warn("dictation", "polish failed (\(error.localizedDescription)) — using raw text")
            return text
        }
    }

    // MARK: - History

    /// Every dictation becomes a normal Recording in the "Dictation" folder:
    /// playable, re-transcribable with another engine, searchable via the KB.
    @MainActor
    private func saveHistory(samples: [Float], seconds: Double, text: String) {
        do {
            try store(samples: samples, seconds: seconds, text: text,
                      versionLabel: settings.engine.displayName + " · dictation")
        } catch {
            AppLog.error("dictation", "history save failed: \(error.localizedDescription)")
        }
    }

    /// "Save to library" from the scratch pad. The entry carries half a
    /// second of silence as its audio so it behaves like every other
    /// recording (player, waveform, export) instead of a special case.
    @MainActor
    func saveScratchPad() {
        let text = paneText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let silence = [Float](repeating: 0, count: Int(UtteranceCapture.sampleRate / 2))
            try store(samples: silence, seconds: 0.5, text: text, versionLabel: "Dictation scratch pad")
            showMessage("Saved to Library → Dictation")
        } catch {
            AppLog.error("dictation", "scratch pad save failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    @MainActor
    private func store(samples: [Float], seconds: Double, text: String, versionLabel: String) throws {
        let url = try Self.writeWav(samples)
        let recording = Recording(
            title: DictationText.title(for: text),
            audioPath: url.path,
            durationSeconds: seconds,
            transcribedWithBackend: settings.engine.rawValue
        )
        recording.runBackend = settings.engine.rawValue
        recording.runLanguages = settings.languages.sorted().joined(separator: ",")
        try repository.save(recording)
        let segment = Segment(startSeconds: 0, endSeconds: seconds, text: text)
        try repository.appendSegments([segment], to: recording)
        let folder = try repository.folders().first {
            $0.name.caseInsensitiveCompare("Dictation") == .orderedSame
        } ?? (try repository.createFolder(named: "Dictation"))
        try repository.move(recording, to: folder)
        try repository.snapshotVersion(
            of: recording, engineId: settings.engine.rawValue, engineLabel: versionLabel)
    }

    private static func writeWav(_ samples: [Float]) throws -> URL {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = f.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(4))
        let url = dir.appendingPathComponent("Dictation_\(stamp)-\(suffix).wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: UtteranceCapture.sampleRate,
                                channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "Dictation", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot allocate WAV buffer"])
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
        return url
    }

    // MARK: - Helpers

    private func vocabularyTerms() -> [String] {
        prompts.vocabulary(for: settings.languages)
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whole-utterance speech gate (mirror of the live captioner's).
    nonisolated static func hasSpeech(_ samples: [Float]) -> Bool {
        var sumSq: Float = 0
        var peak: Float = 0
        for s in samples {
            sumSq += s * s
            let a = s < 0 ? -s : s
            if a > peak { peak = a }
        }
        let rms = (sumSq / Float(max(1, samples.count))).squareRoot()
        return UtteranceCapture.isVoiced(rms: rms, peak: peak)
    }

    @MainActor
    private func showMessage(_ text: String) {
        messageTask?.cancel()
        phase = .message(text)
        updateHUD()
        messageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard let self, !Task.isCancelled, self.isMessage(self.phase) else { return }
            self.phase = .idle
            self.updateHUD()
        }
    }

    @MainActor
    private func updateHUD(showResultBriefly: Bool = false) {
        guard let hud else { return }
        guard settings.showHUD else { hud.hide(); return }
        switch phase {
        case .idle:
            if showResultBriefly, target == .frontmostApp, !lastText.isEmpty {
                hud.show()
                hud.hide(after: 1.6)
            } else {
                hud.hide()
            }
        case .message:
            hud.show()
            hud.hide(after: 2.4)
        case .listening, .transcribing, .inserting:
            // Pane-targeted sessions are visible in the window already.
            if target == .pane && NSApp.isActive { hud.hide() } else { hud.show() }
        }
    }

    @MainActor
    private func playSound(_ name: String) {
        guard settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Wall-clock guard for native calls that don't observe cancellation.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ASRError.chunkTimeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
