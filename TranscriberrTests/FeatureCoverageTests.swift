import XCTest
import SwiftData
import AppKit
@testable import Transcriberr

/// Features that had no unit test before docs/feature-coverage.md was
/// drawn up: the knowledge-base renderers the CLI `kb` commands and the MCP
/// server print, the per-chunk quality signal that triggers a second pass,
/// the `.txt` / `.speakers.json` sidecars, preset snippets, the domain
/// vocabulary packs, the Gemma model catalog and the bundled fonts.
@MainActor
final class FeatureCoverageTests: XCTestCase {

    // MARK: - Knowledge base rendering (kb …, MCP tools)

    private func summary(meeting: KBMeeting? = nil) -> KBRecordingSummary {
        KBRecordingSummary(
            id: "0123456789ABCDEF", title: "Standup", createdAt: "2026-01-05T10:00:00Z",
            durationSeconds: 3725, language: "en", folder: "Work", tags: ["a", "b"],
            segmentCount: 2, outputPresets: ["minutes", "summary"], meeting: meeting)
    }

    private func transcript(offset: Int = 0, total: Int = 5, truncated: Bool = true) -> KBTranscript {
        KBTranscript(
            recording: summary(),
            segments: [
                KBSegment(start: 5, end: 7, text: "I was I was like, um, sure",
                          speaker: "SPEAKER_00", speakerName: "Kees"),
                KBSegment(start: 65, end: 70, text: "Done", speaker: nil, speakerName: nil),
            ],
            totalSegments: total, offset: offset, truncated: truncated)
    }

    func testKBTimestampsNeverTrap() {
        XCTAssertEqual(KBRender.timestamp(0), "00:00")
        XCTAssertEqual(KBRender.timestamp(65), "01:05")
        XCTAssertEqual(KBRender.timestamp(3725), "1:02:05")
        XCTAssertEqual(KBRender.timestamp(-3), "00:00")
        XCTAssertEqual(KBRender.timestamp(.nan), "00:00")
        XCTAssertEqual(KBRender.timestamp(.infinity), "00:00")
    }

    func testKBHeaderLineNamesEverythingAListRowShows() {
        XCTAssertEqual(KBRender.headerLine(summary()),
                       "`01234567` · 2026-01-05T10:00:00Z · 1:02:05 · EN · ▸ Work · #a #b · outputs: minutes, summary")
        let meeting = KBMeeting(title: "Daily standup", start: "s", end: "e", attendees: ["Kees", "Anna"])
        XCTAssertTrue(KBRender.headerLine(summary(meeting: meeting)).hasSuffix(" · meeting: Daily standup"))
        XCTAssertEqual(KBRender.meetingLine(meeting), "Meeting: **Daily standup** (s → e) · with Kees, Anna")
    }

    func testKBPlainTextAndPaginationFooter() {
        XCTAssertEqual(KBRender.plainText(transcript()),
                       "Kees: I was I was like, um, sure\nDone\n\n(segments 0–1 of 5 — call again with offset: 2)")
        let md = KBRender.markdown(transcript())
        XCTAssertTrue(md.hasPrefix("## Standup\n"))
        XCTAssertTrue(md.contains("[00:05] Kees: I was I was like, um, sure"))
        XCTAssertTrue(md.contains("[01:05] Done"))
        XCTAssertTrue(KBRender.markdown(transcript(total: 2, truncated: false)).hasSuffix("(2 segments, complete)"))
        // The last page: no "call again", and plain text carries no footer.
        let last = transcript(offset: 3, total: 5, truncated: false)
        XCTAssertTrue(KBRender.markdown(last).hasSuffix("(segments 3–4 of 5)"))
        XCTAssertFalse(KBRender.plainText(last).contains("segments"))
    }

    func testKBTranscriptStyleCleanAndVerbatim() {
        XCTAssertEqual(TranscriptStyle(rawValue: "clean"), .clean)
        XCTAssertEqual(TranscriptStyle(rawValue: "verbatim"), .verbatim)
        let t = transcript()
        XCTAssertEqual(t.styled(.clean).segments[0].text, "I was like, sure")
        XCTAssertEqual(t.styled(.verbatim).segments[0].text, "I was I was like, um, sure")
        XCTAssertEqual(t.styled(.clean).segments[0].speakerName, "Kees")
        XCTAssertEqual(t.styled(.clean).totalSegments, 5)
    }

    func testKBEmptyStatesAndListings() {
        XCTAssertEqual(KBRender.markdownList([]), "No recordings match.")
        XCTAssertEqual(KBRender.markdown([KBOutput]()),
                       "No generated outputs stored. Use kb_get_transcript for the raw transcript.")
        XCTAssertEqual(KBRender.markdown([KBSearchHit](), query: "budget"), "No matches for \"budget\".")
        XCTAssertEqual(KBRender.markdown(folders: [], tags: []), "## Folders\n(none)\n\n## Tags\n(none)")
        XCTAssertEqual(KBRender.markdown(folders: [KBFolderInfo(name: "Work", count: 2)],
                                         tags: [KBTagInfo(name: "q1", count: 1)]),
                       "## Folders\n- Work (2)\n\n## Tags\n- #q1 (1)")
        let hit = KBSearchHit(recording: summary(), matches: transcript().segments, titleMatched: true)
        let hits = KBRender.markdown([hit], query: "sure")
        XCTAssertTrue(hits.hasPrefix("### Standup\n"))
        XCTAssertTrue(hits.contains(" · title match"))
        XCTAssertTrue(hits.contains("- [00:05] Kees: I was I was like, um, sure"))
        let outputs = KBRender.markdown([
            KBOutput(presetId: "summary", title: "Summary", createdAt: "c1", markdown: "- one"),
            KBOutput(presetId: "minutes", title: "Minutes", createdAt: "c2", markdown: "- two"),
        ])
        XCTAssertEqual(outputs, "## Summary (summary, c1)\n\n- one\n\n---\n\n## Minutes (minutes, c2)\n\n- two")
    }

    func testKBStatsMarkdown() {
        let stats = KBStats(recordings: 3, totalDurationSeconds: 3725, languages: ["en": 2, "uk": 1],
                            folders: 1, tags: 2, outputs: 4, oldest: "o", newest: "n",
                            storePath: "/x.store", storeSizeBytes: 2048)
        XCTAssertEqual(KBRender.markdown(stats),
                       "## Knowledge base\n- Recordings: 3\n- Total audio: 1:02:05\n"
                       + "- Folders: 1 · Tags: 2 · Generated outputs: 4\n"
                       + "- Languages: en (2), uk (1)\n- Range: o → n\n- Store: /x.store (2 KB)")
    }

    // MARK: - Chunk quality signal (second pass in TranscriptionRunner)

    func testChunkConfidenceCleanTextIsNotFlagged() {
        let c = ChunkConfidence.assess(rawText: "Good morning everyone, let's start the meeting.",
                                       audioDurationSeconds: 3)
        XCTAssertEqual(c.score, 0)
        XCTAssertTrue(c.reasons.isEmpty)
        XCTAssertFalse(c.isLow)
    }

    func testChunkConfidenceFlagsEmptyOutputForLongAudio() {
        let c = ChunkConfidence.assess(rawText: "   ", audioDurationSeconds: 10)
        XCTAssertEqual(c.score, 0.6, accuracy: 1e-9)
        XCTAssertEqual(c.reasons, ["too-short(0c/10s)"])
        XCTAssertTrue(c.isLow)
    }

    func testChunkConfidenceSparseOutputAloneIsNotLow() {
        let c = ChunkConfidence.assess(rawText: "Okay we will see.", audioDurationSeconds: 20)
        XCTAssertEqual(c.score, 0.3, accuracy: 1e-9)
        XCTAssertEqual(c.reasons, ["sparse(17c/20s)"])
        XCTAssertFalse(c.isLow)
    }

    func testChunkConfidenceFlagsLoopsAndRefusals() {
        let loop = ChunkConfidence.assess(rawText: "I said hello there hello there hello there hello there",
                                          audioDurationSeconds: 4)
        XCTAssertTrue(loop.isLow)
        XCTAssertTrue(loop.reasons.contains { $0.hasPrefix("loop(") }, "\(loop.reasons)")

        let refusal = ChunkConfidence.assess(rawText: "Sorry, I cannot help with this audio clip.",
                                             audioDurationSeconds: 3)
        XCTAssertTrue(refusal.isLow)
        XCTAssertTrue(refusal.reasons.contains { $0.hasPrefix("hallucinated(") }, "\(refusal.reasons)")

        let both = ChunkConfidence.assess(rawText: "as an ai as an ai as an ai as an ai model",
                                          audioDurationSeconds: 3)
        XCTAssertEqual(both.score, 1.0, "the score is clamped")
    }

    func testChunkConfidenceUnterminatedSentenceIsAMildSignal() {
        let c = ChunkConfidence.assess(rawText: "We were talking about the budget and then",
                                       audioDurationSeconds: 4)
        XCTAssertEqual(c.reasons, ["no-terminal-punct"])
        XCTAssertEqual(c.score, 0.15, accuracy: 1e-9)
        XCTAssertFalse(c.isLow)
    }

    // MARK: - Sidecars (.txt / .speakers.json)

    func testTxtAndSpeakerSidecarsNextToTheAudio() throws {
        let backups = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-backups-\(UUID().uuidString.prefix(6))")
        setenv("TRANSCRIBERR_BACKUP_ROOT", backups.path, 1)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-\(UUID().uuidString.prefix(6))")
        let out = scratch.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer {
            BackupService.flush()
            unsetenv("TRANSCRIBERR_BACKUP_ROOT")
            try? FileManager.default.removeItem(at: backups)
            try? FileManager.default.removeItem(at: scratch)
        }
        let container = try ModelContainer(for: Schema(TranscriberrSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repo = RecordingRepository(context: container.mainContext)

        let audio = scratch.appendingPathComponent("meet.wav")
        try Data("RIFF".utf8).write(to: audio)
        let rec = Recording(title: "Meet", audioPath: audio.path, durationSeconds: 10)
        try repo.save(rec)
        try repo.appendSegments([
            Segment(startSeconds: 5, endSeconds: 8, text: "Second line", speaker: "SPEAKER_01"),
            Segment(startSeconds: 0, endSeconds: 5, text: "First line", speaker: "SPEAKER_00", speakerName: "Kees"),
            Segment(startSeconds: 8, endSeconds: 9, text: "Third", speaker: "SPEAKER_00", speakerName: "Kees"),
            Segment(startSeconds: 9, endSeconds: 10, text: "No speaker"),
        ], to: rec)

        try TranscriptExporter.export(recording: rec, to: out)

        let txt = try String(contentsOf: out.appendingPathComponent("meet.txt"), encoding: .utf8)
        XCTAssertEqual(txt, "Kees: First line\nSPEAKER_01: Second line\nKees: Third\nNo speaker")
        let speakers = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: out.appendingPathComponent("meet.speakers.json")))
        XCTAssertEqual(speakers, ["SPEAKER_00": "Kees"], "one name per speaker, unnamed speakers left out")
        let srt = try String(contentsOf: out.appendingPathComponent("meet.srt"), encoding: .utf8)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:05,000\nFirst line\n\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("meet.json").path))

        // Nobody named: no speakers sidecar at all.
        let plain = Recording(title: "Plain", audioPath: scratch.appendingPathComponent("plain.wav").path)
        try repo.save(plain)
        try repo.appendSegments([Segment(startSeconds: 0, endSeconds: 1, text: "hello", speaker: "SPEAKER_00")], to: plain)
        try TranscriptExporter.export(recording: plain, to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("plain.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("plain.speakers.json").path))
    }

    // MARK: - Snippets in preset templates

    func testSnippetsAreSubstitutedAndPersisted() {
        // SnippetStore reads and writes UserDefaults.standard, which in the
        // test host is the app's own domain: put the user's snippets back.
        let key = "snippets.v1"
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let store = SnippetStore()
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertEqual(store.substitute("{snippet:sig}"), "{snippet:sig}")
        store.snippets = [Snippet(name: "sig", body: "Best, Yuri"), Snippet(name: "team", body: "Platform")]
        XCTAssertEqual(store.substitute("Hi {snippet:team}. {snippet:sig} {snippet:unknown}"),
                       "Hi Platform. Best, Yuri {snippet:unknown}", "unknown names are left intact")
        XCTAssertEqual(SnippetStore().snippets, store.snippets, "snippets survive a relaunch")
    }

    // MARK: - Domain vocabulary packs (Settings › Style & vocabulary)

    func testDomainVocabularyPacksLoadFromTheAppBundle() {
        for pack in DomainVocabulary.Pack.allCases {
            let terms = DomainVocabulary.terms(pack: pack, languages: [])
            XCTAssertFalse(terms.isEmpty, "\(pack.rawValue): no terms (vocab.json missing from the app bundle?)")
            XCTAssertEqual(terms, terms.sorted())
            XCTAssertEqual(Set(terms).count, terms.count)
            XCTAssertFalse(pack.displayName.isEmpty)
        }
        XCTAssertTrue(DomainVocabulary.terms(pack: .it, languages: []).contains("Kubernetes"))
        let ukIT = DomainVocabulary.terms(pack: .it, languages: ["Ukrainian"])
        XCTAssertEqual(ukIT.filter { $0 == "Kubernetes" }.count, 1, "a term in two languages is offered once")
        let ukBuild = DomainVocabulary.terms(pack: .construction, languages: ["Ukrainian"])
        XCTAssertTrue(ukBuild.contains("арматура"))
        XCTAssertTrue(ukBuild.contains("rebar"), "English is always included")
        XCTAssertFalse(DomainVocabulary.terms(pack: .construction, languages: []).contains("арматура"))
    }

    // MARK: - Gemma model catalog (Settings › Models)

    func testModelCatalogEntriesArePinnedAndVerifiable() throws {
        let entries = ModelCatalog.entries
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        for e in entries {
            XCTAssertGreaterThan(e.sizeBytes, 0, e.id)
            XCTAssertFalse(e.name.isEmpty, e.id)
            guard let url = e.directURL else { continue }
            XCTAssertEqual(url.scheme, "https", e.id)
            XCTAssertEqual(url.host, "huggingface.co", e.id)
            if let hf = e.huggingFaceID {
                XCTAssertTrue(url.path.hasPrefix("/\(hf)/resolve/"), "\(e.id): \(url.path)")
            }
            if e.backend == .gemmaLiteRT { XCTAssertEqual(url.pathExtension, "litertlm", e.id) }
            let sha = try XCTUnwrap(e.sha256, "\(e.id): a direct download must carry its hash")
            XCTAssertEqual(sha.count, 64, e.id)
            XCTAssertTrue(sha.allSatisfy { "0123456789abcdef".contains($0) }, e.id)
        }
    }

    func testGemmaBundleResolutionPrefersTheGenericFile() throws {
        let explicit = URL(fileURLWithPath: "/nonexistent/gemma.litertlm")
        XCTAssertEqual(GemmaLiteRTBackend.resolveModelFile(from: explicit), explicit)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fc-gemma-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["gemma-4-E2B-it_qualcomm_sm8750.litertlm", "gemma-4-E2B-it.litertlm", "README.md"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(GemmaLiteRTBackend.resolveModelFile(from: dir)?.lastPathComponent, "gemma-4-E2B-it.litertlm")
    }

    // MARK: - Bundled typefaces

    /// `Theme` silently falls back to the system font when these are not
    /// registered, so a broken font lookup never shows up anywhere else.
    func testBundledFontsAreRegistered() {
        FontLoader.registerBundledFonts()
        for name in ["ArchivoRoman-SemiBold", "ArchivoRoman-Bold", "SchibstedGrotesk-Regular", "SchibstedGrotesk-Bold"] {
            XCTAssertNotNil(NSFont(name: name, size: 12),
                            "\(name) is not registered: FontLoader looks in Contents/Resources/Fonts/")
        }
    }
}
