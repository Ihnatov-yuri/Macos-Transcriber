import AppKit

/// The app's own run of `MeetingMoveCheck`, for a machine where the shell
/// lacks the System Audio Recording permission the app holds. Launched as
///
///   open -n <Transcriberr.app> --env TRANSCRIBERR_SELFTEST=meetingmove \
///        --env TRANSCRIBERR_SELFTEST_OUT=<file> --env CFFIXED_USER_HOME=<sandbox>
///
/// it records a meeting whose mic is lost halfway, shows the pop-out notes
/// the Record screen would, writes the outcome (PASS/FAIL lines) to the
/// out file and quits. Test-host mode keeps the library, hotkeys and log
/// apart (see `AppContainer.selfTest`).
@MainActor
enum MeetingSelfTest {
    static func start() {
        let env = ProcessInfo.processInfo.environment
        let out = env["TRANSCRIBERR_SELFTEST_OUT"].map { URL(fileURLWithPath: $0) }
        func finish(_ lines: [String], code: Int32) -> Never {
            if let out {
                do { try lines.joined(separator: "\n").appending("\n").write(to: out, atomically: true, encoding: .utf8) }
                catch { AppLog.error("selftest", "cannot write \(out.path): \(error.localizedDescription)") }
            }
            AppLog.info("selftest", "exit \(code)")
            exit(code)
        }
        guard AppContainer.selfTest == "meetingmove" else {
            finish(["FAIL: unknown self-test \(AppContainer.selfTest ?? "")"], code: 2)
        }
        let seconds = env["TRANSCRIBERR_SELFTEST_SECONDS"].flatMap(Double.init) ?? 12
        // A permission prompt or a stuck device must not leave the app
        // running on an in-memory store with nobody watching.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((seconds + 60) * 1_000_000_000))
            finish(["TIMEOUT: no outcome after \(Int(seconds + 60)) s"], code: 3)
        }
        Task { @MainActor in
            // Let the app finish launching (windows, run loop) first.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let outcome = await MeetingMoveCheck.run(seconds: seconds) { note in
                RecordingNoticeHUD.shared.show(
                    title: String(localized: "Meeting recording", comment: "Pop-out note title: something happened to the meeting being recorded"),
                    text: note)
            }
            // Leave the last note up long enough to be seen.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            finish(outcome.lines, code: outcome.ok ? 0 : 1)
        }
    }
}
