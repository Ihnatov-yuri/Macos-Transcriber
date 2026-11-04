import XCTest
import AVFoundation
import SwiftData
@testable import Transcriberr

/// Pure-logic checks for the fixes of the remaining review findings.
@MainActor
final class RemainingFixTests: XCTestCase {
    var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rft-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Record screen: sleep/wake observers

    func testObserverBagRemovesItsObserversWhenReleased() {
        let center = NotificationCenter()
        let name = Notification.Name("RemainingFixTests.ping")
        let counter = RFTCounter()
        var bag: NotificationObserverBag? = NotificationObserverBag(center: center)
        bag?.add(center.addObserver(forName: name, object: nil, queue: nil) { _ in counter.bump() })
        XCTAssertEqual(bag?.count, 1)
        center.post(name: name, object: nil)
        XCTAssertEqual(counter.value, 1)
        bag = nil
        center.post(name: name, object: nil)
        XCTAssertEqual(counter.value, 1, "a released bag leaves no observer behind")
    }

    func testObserverBagRemoveAll() {
        let center = NotificationCenter()
        let name = Notification.Name("RemainingFixTests.ping2")
        let counter = RFTCounter()
        let bag = NotificationObserverBag(center: center)
        bag.add(center.addObserver(forName: name, object: nil, queue: nil) { _ in counter.bump() })
        bag.removeAll()
        center.post(name: name, object: nil)
        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(bag.count, 0)
    }

    // MARK: - Settings: snippets keep their identity

    func testSnippetIdentityIsStableAndNeverStored() throws {
        let a = Snippet(name: "name-me", body: "")
        let b = Snippet(name: "name-me", body: "")
        XCTAssertNotEqual(a.uid, b.uid, "two new rows are told apart")
        XCTAssertEqual(a, b, "equality is the content, as before")
        var renamed = a
        renamed.name = "team"
        XCTAssertEqual(renamed.uid, a.uid, "renaming keeps the row")

        let data = try JSONEncoder().encode([a])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(json[0].keys), ["name", "body"])
        let back = try JSONDecoder().decode([Snippet].self, from: Data(#"[{"name":"sig","body":"Best"}]"#.utf8))
        XCTAssertEqual(back, [Snippet(name: "sig", body: "Best")])
    }

    // MARK: - Detail: search marks match like the Library

    func testSearchHighlightIsWidthInsensitive() {
        let text = "Ｄａｔａ sovereignty"
        let found = SearchHighlight.ranges(of: "data", in: text).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(found, ["Ｄａｔａ"])
        XCTAssertTrue(SearchHighlight.options.contains(.widthInsensitive))
    }

    // MARK: - Audio

    func testRecorderDropsBuffersOfTheOldRate() throws {
        func buffer(_ rate: Double) throws -> AVAudioPCMBuffer {
            let f = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                channels: 1, interleaved: false))
            return try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 16))
        }
        let mixed = [try buffer(48_000), try buffer(44_100), try buffer(48_000)]
        XCTAssertEqual(WavRecorder.buffers(mixed, matchingRate: 48_000).count, 2)
        XCTAssertEqual(WavRecorder.buffers(mixed, matchingRate: 44_100).count, 1)
        XCTAssertTrue(WavRecorder.buffers(mixed, matchingRate: 16_000).isEmpty)
    }

    func testMeetingRateChange() {
        XCTAssertFalse(MeetingRecorder.rateChanged(capture: 48_000, now: 48_000))
        XCTAssertTrue(MeetingRecorder.rateChanged(capture: 48_000, now: 44_100))
        XCTAssertFalse(MeetingRecorder.rateChanged(capture: 48_000, now: nil), "unreadable is not a change")
        XCTAssertFalse(MeetingRecorder.rateChanged(capture: 0, now: 44_100), "nothing captured yet")
    }

    /// A rate change rebuilds the converters instead of ending the meeting;
    /// the frame counter is re-expressed at the new rate so elapsed time
    /// (frames / rate) does not jump.
    func testMeetingFrameCountCarriesAcrossARateChange() {
        XCTAssertEqual(MeetingRecorder.convertFrameCount(480_000, from: 48_000, to: 44_100), 441_000)
        XCTAssertEqual(MeetingRecorder.convertFrameCount(441_000, from: 44_100, to: 96_000), 960_000)
        XCTAssertEqual(MeetingRecorder.convertFrameCount(0, from: 48_000, to: 44_100), 0)
        XCTAssertEqual(MeetingRecorder.convertFrameCount(1_000, from: 0, to: 44_100), 1_000, "unknown rate keeps the count")
        let before = 123_457.0 / 48_000
        let after = Double(MeetingRecorder.convertFrameCount(123_457, from: 48_000, to: 44_100)) / 44_100
        XCTAssertEqual(before, after, accuracy: 1.0 / 44_100, "same elapsed time on both sides of the change")
    }

    func testMeetingConverterBuildsForCommonRates() throws {
        for rate in [44_100.0, 48_000, 96_000] {
            let conv = try XCTUnwrap(MeetingRecorder.makeConverter(nativeRate: rate))
            XCTAssertEqual(conv.inputFormat.sampleRate, rate)
            XCTAssertEqual(conv.outputFormat.sampleRate, 16_000)
            XCTAssertEqual(conv.outputFormat.channelCount, 1)
        }
        XCTAssertNil(MeetingRecorder.makeConverter(nativeRate: 0))
    }

    func testDriverInstallVerifiesARootOwnedCopyBeforeReplacing() {
        let script = VirtualMicrophone.installScript(source: "/Applications/My App's.app/Contents/Resources/TranscriberrMic.driver",
                                                     dest: "/Library/Audio/Plug-Ins/HAL/TranscriberrMic.driver", team: nil, leaf: nil)
        XCTAssertTrue(script.contains("/bin/chmod -R u-s,g-s,go-w"), "setuid/setgid bits are cleared")
        XCTAssertTrue(script.hasPrefix("T=$(/usr/bin/mktemp -d /private/var/tmp/"))
        XCTAssertTrue(script.contains("'/Applications/My App'\\''s.app/Contents/Resources/TranscriberrMic.driver'"),
                      "the source stays shell-quoted")
        func at(_ s: String) -> String.Index? { script.range(of: s)?.lowerBound }
        let ditto = at("/usr/bin/ditto"), chown = at("/usr/sbin/chown -R root:wheel"),
            verify = at("/usr/bin/codesign --verify --strict -R '=identifier \"nl.ihnatov.Transcriberr.MicDriver\"'"),
            remove = at("/bin/rm -rf '/Library"), move = at("/bin/mv"), restart = at("killall coreaudiod")
        XCTAssertNotNil(ditto); XCTAssertNotNil(chown); XCTAssertNotNil(verify)
        XCTAssertNotNil(remove); XCTAssertNotNil(move); XCTAssertNotNil(restart)
        if let ditto, let chown, let verify, let remove, let move, let restart {
            XCTAssertTrue(ditto < chown && chown < verify && verify < remove && remove < move && move < restart,
                          "copy, own, verify, then replace, then restart")
        }
        // The double quotes survive the AppleScript string.
        XCTAssertTrue(VirtualMicrophone.appleScriptEscaped(script).contains("\\\"$T\\\""))
    }

    // MARK: - ASR

    func testRefinementLeavesTheNeighbourChunksSegmentsInTheRecap() {
        // Chunk 1 is 27…55 s, with a 1 s recap of chunk 0 (which ends at 28 s).
        let chunk = AudioDecoder.Chunk(samples: [], startSeconds: 27, endSeconds: 55)
        var neighbourTail = RawSegment(startSeconds: 27.2, endSeconds: 28, text: "end of chunk 0")
        neighbourTail.chunkIndex = 0
        var own = RawSegment(startSeconds: 27, endSeconds: 40, text: "chunk 1")
        own.chunkIndex = 1
        XCTAssertFalse(TranscriptionRunner.refinementRemoves(neighbourTail, chunkIndex: 1, chunk: chunk,
                                                             splitTracks: false, isMicChunk: false))
        XCTAssertTrue(TranscriptionRunner.refinementRemoves(own, chunkIndex: 1, chunk: chunk,
                                                            splitTracks: false, isMicChunk: false))
        // Untagged: the time-window, same-track rule as before.
        let untagged = RawSegment(startSeconds: 30, endSeconds: 35, text: "x", speakerKey: "ME")
        XCTAssertTrue(TranscriptionRunner.refinementRemoves(untagged, chunkIndex: 1, chunk: chunk,
                                                            splitTracks: true, isMicChunk: true))
        XCTAssertFalse(TranscriptionRunner.refinementRemoves(untagged, chunkIndex: 1, chunk: chunk,
                                                             splitTracks: true, isMicChunk: false))
        let outside = RawSegment(startSeconds: 50, endSeconds: 60, text: "y")
        XCTAssertFalse(TranscriptionRunner.refinementRemoves(outside, chunkIndex: 1, chunk: chunk,
                                                             splitTracks: false, isMicChunk: false))
    }

    func testHalfFinishedUpdateLosesFilesNotInTheNewRelease() throws {
        let dir = scratch.appendingPathComponent("update-download", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("model.mlmodelc"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("model.mlmodelc/weight.bin"))
        try Data("c".utf8).write(to: dir.appendingPathComponent("model.mlmodelc/old.bin"))
        try Data("d".utf8).write(to: dir.appendingPathComponent("stale.json"))
        let m = HFModelRelease.Manifest(revision: String(repeating: "a", count: 40), files: [
            HFModelRelease.File(path: "config.json", size: 1, gitBlob: String(repeating: "0", count: 40)),
            HFModelRelease.File(path: "model.mlmodelc/weight.bin", size: 1, sha256: String(repeating: "0", count: 64)),
        ])
        XCTAssertEqual(HFModelRelease.removeFiles(in: dir, notListedIn: m), ["model.mlmodelc/old.bin", "stale.json"])
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("config.json").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("model.mlmodelc/weight.bin").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("stale.json").path))
        XCTAssertEqual(HFModelRelease.removeFiles(in: scratch.appendingPathComponent("missing"), notListedIn: m), [])
    }

    func testLiveDeadlineReturnsTheResultAndStillTimesOut() async throws {
        let v = try await LiveTranscriber.withDeadline(30) { 42 }
        XCTAssertEqual(v, 42)
        do {
            _ = try await LiveTranscriber.withDeadline(0.05) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            XCTFail("expected a timeout")
        } catch is LiveTranscriber.ReadTimeout {
        }
    }

    // MARK: - Dictation

    func testPendingPassesArePerSession() {
        var c = PendingPassCounter()
        c.add(session: 1)
        c.add(session: 1)
        c.add(session: 2)
        XCTAssertEqual(c.total, 3)
        c.cancel(session: 2)
        XCTAssertEqual(c.total, 2, "cancelling session 2 leaves session 1's passes counted")
        c.finish(session: 2)
        XCTAssertEqual(c.total, 2, "a cancelled session's pass ending is not counted twice")
        c.finish(session: 1)
        c.finish(session: 1)
        c.finish(session: 1)
        XCTAssertEqual(c.total, 0)
    }

    func testCaretWindowStartsOnAWholeCharacter() {
        // "a" + 😀 (two UTF-16 units) + "b": offset 2 is inside the emoji.
        XCTAssertEqual(FocusedTextContext.alignedTail(of: "a😀b", from: 2), "b")
        XCTAssertEqual(FocusedTextContext.alignedTail(of: "a😀b", from: 1), "😀b")
        XCTAssertEqual(FocusedTextContext.alignedTail(of: "a😀b", from: 0), "a😀b")
        // e + combining acute: cut after the e, the accent goes with it.
        XCTAssertEqual(FocusedTextContext.alignedTail(of: "e\u{301}x", from: 1), "x")
        XCTAssertEqual(FocusedTextContext.alignedTail(of: "abc", from: 3), "")
    }

    // MARK: - Updater

    func testDeclaredDownloadSize() {
        XCTAssertTrue(UpdateInstaller.declaredSizeAllowed(-1), "no Content-Length: checked while streaming")
        XCTAssertTrue(UpdateInstaller.declaredSizeAllowed(200_000_000))
        XCTAssertFalse(UpdateInstaller.declaredSizeAllowed(0))
        XCTAssertFalse(UpdateInstaller.declaredSizeAllowed(Int64(UpdateInstaller.maxZipBytes)))
    }

    // MARK: - Repository

    func testHealCountsOnlyRowsActuallyRepointed() throws {
        let container = try ModelContainer(for: Schema(TranscriberrSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repo = RecordingRepository(context: container.mainContext)
        let backups = scratch.appendingPathComponent("backups")
        setenv("TRANSCRIBERR_BACKUP_ROOT", backups.path, 1)
        defer {
            BackupService.flush()
            unsetenv("TRANSCRIBERR_BACKUP_ROOT")
        }
        let wav = scratch.appendingPathComponent("a.wav")
        try Data("x".utf8).write(to: scratch.appendingPathComponent("a.m4a"))
        let rec = Recording(title: "A", audioPath: wav.path, durationSeconds: 1, transcribedWithBackend: "x")
        try repo.save(rec)
        XCTAssertEqual(repo.healMissingAudioPaths(), 1)
        XCTAssertEqual(rec.audioPath, scratch.appendingPathComponent("a.m4a").path)
        XCTAssertEqual(repo.healMissingAudioPaths(), 0, "nothing left to heal")
    }

    /// A team-signed app pins the driver to its own team; ad-hoc builds can
    /// only check the identifier; a malformed team never reaches the shell.
    func testDriverRequirementPinsTheTeam() {
        XCTAssertEqual(VirtualMicrophone.driverRequirement(team: nil),
                       "identifier \"nl.ihnatov.Transcriberr.MicDriver\"")
        XCTAssertEqual(VirtualMicrophone.driverRequirement(team: "AB12CD34EF"),
                       "anchor apple generic and certificate leaf[subject.OU] = \"AB12CD34EF\" and identifier \"nl.ihnatov.Transcriberr.MicDriver\"")
        XCTAssertEqual(VirtualMicrophone.driverRequirement(team: "X\" or true"),
                       "identifier \"nl.ihnatov.Transcriberr.MicDriver\"")
    }
}

/// Counts notifications delivered on any thread.
nonisolated private final class RFTCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }

}
