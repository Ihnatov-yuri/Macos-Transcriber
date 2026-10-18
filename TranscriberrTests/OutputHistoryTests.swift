import XCTest
import SwiftData
@testable import Transcriberr

/// 4.5.0: Generate keeps the output it replaces; any earlier one can be made
/// current again. Presets keep their earlier prompts. A recording exports to
/// a folder with a manifest.
@MainActor
final class OutputHistoryTests: XCTestCase {
    var container: ModelContainer!
    var repo: RecordingRepository!
    var backupRoot: URL!
    var scratch: URL!

    override func setUp() async throws {
        let schema = Schema(TranscriberrSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        repo = RecordingRepository(context: container.mainContext)
        backupRoot = FileManager.default.temporaryDirectory.appendingPathComponent("oh-backups-\(UUID().uuidString.prefix(6))")
        setenv("TRANSCRIBERR_BACKUP_ROOT", backupRoot.path, 1)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("oh-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        BackupService.flush()
        unsetenv("TRANSCRIBERR_BACKUP_ROOT")
        try? FileManager.default.removeItem(at: backupRoot)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func recording() throws -> Recording {
        let audio = scratch.appendingPathComponent("a.wav")
        try Data("RIFF".utf8).write(to: audio)
        let rec = Recording(title: "Weekly / sync", audioPath: audio.path, durationSeconds: 1)
        try repo.save(rec)
        try repo.appendSegments([Segment(startSeconds: 0, endSeconds: 1, text: "hello", speaker: "S1", speakerName: "Kate")], to: rec)
        return rec
    }

    private let prov = RecordingRepository.OutputProvenance(engineLabel: "Gemma", systemPrompt: "sys", userPrompt: "user")

    func testGenerateKeepsEarlierOutputs() throws {
        let rec = try recording()
        try repo.replaceOutput(OutputDoc(presetId: "summary", title: "Summary", markdown: "one", createdAtMillis: 1), for: rec, provenance: prov)
        try repo.replaceOutput(OutputDoc(presetId: "summary", title: "Summary", markdown: "two", createdAtMillis: 2), for: rec, provenance: prov)
        try repo.replaceOutput(OutputDoc(presetId: "minutes", title: "Minutes", markdown: "m", createdAtMillis: 3), for: rec)
        let history = repo.outputVersions(presetId: "summary", in: rec)
        XCTAssertEqual(history.map(\.markdown), ["two", "one"])
        XCTAssertEqual(history.first?.engineLabel, "Gemma")
        XCTAssertEqual(history.first?.userPrompt, "user")
        XCTAssertEqual(rec.outputs.first { $0.presetId == "summary" }?.markdown, "two")
    }

    func testOutputFromBeforeHistoryIsKeptOnFirstRegenerate() throws {
        let rec = try recording()
        // As 4.4 stored it: an OutputDoc and no version.
        let legacy = OutputDoc(presetId: "summary", title: "Summary", markdown: "legacy", createdAtMillis: 5)
        legacy.recording = rec
        container.mainContext.insert(legacy)
        rec.outputs.append(legacy)
        try container.mainContext.save()

        try repo.replaceOutput(OutputDoc(presetId: "summary", title: "Summary", markdown: "new"), for: rec, provenance: prov)
        let old = try XCTUnwrap(repo.outputVersions(presetId: "summary", in: rec).first { $0.markdown == "legacy" })
        XCTAssertEqual(old.createdAtMillis, 5)
        XCTAssertNil(old.engineLabel)
    }

    func testRestoreSwapsBackAndAddsNoCopies() throws {
        let rec = try recording()
        try repo.replaceOutput(OutputDoc(presetId: "summary", title: "Summary", markdown: "one"), for: rec, provenance: prov)
        try repo.replaceOutput(OutputDoc(presetId: "summary", title: "Summary", markdown: "two"), for: rec, provenance: prov)
        let one = try XCTUnwrap(repo.outputVersions(presetId: "summary", in: rec).first { $0.markdown == "one" })
        try repo.restoreOutput(one, to: rec)
        XCTAssertEqual(rec.outputs.filter { $0.presetId == "summary" }.map(\.markdown), ["one"])
        XCTAssertEqual(repo.outputVersions(presetId: "summary", in: rec).count, 2)
    }

    func testCurrentOutputCannotBeDeletedFromHistory() throws {
        let rec = try recording()
        try repo.replaceOutput(OutputDoc(presetId: "summary", title: "Summary", markdown: "one"), for: rec, provenance: prov)
        try repo.replaceOutput(OutputDoc(presetId: "summary", title: "Summary", markdown: "two"), for: rec, provenance: prov)
        let versions = repo.outputVersions(presetId: "summary", in: rec)
        try repo.deleteOutputVersion(versions.first { $0.markdown == "two" }!, from: rec)
        XCTAssertEqual(repo.outputVersions(presetId: "summary", in: rec).count, 2)
        try repo.deleteOutputVersion(versions.first { $0.markdown == "one" }!, from: rec)
        XCTAssertEqual(repo.outputVersions(presetId: "summary", in: rec).map(\.markdown), ["two"])
    }

    func testDeletingTheRecordingDeletesItsHistory() throws {
        let rec = try recording()
        try repo.replaceOutput(OutputDoc(presetId: "summary", title: "Summary", markdown: "one"), for: rec, provenance: prov)
        try repo.delete(rec)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<OutputVersion>()), 0)
    }

    // MARK: Prompt history

    func testPresetHistoryKeepsPromptsByValue() {
        let defaults = UserDefaults(suiteName: "oh-\(UUID().uuidString)")!
        let store = PresetStore(defaults: defaults)
        XCTAssertNotNil(store.checkpoint("summary", reason: .run))
        XCTAssertNil(store.checkpoint("summary", reason: .run), "same prompts, no new revision")
        let original = store.preset("summary")!.userTemplate
        store.presets[0].userTemplate = "Psychoanalyse: {transcript}"
        store.checkpoint("summary", reason: .saved)
        XCTAssertEqual(store.revisions(for: "summary").map(\.reason), [.saved, .run])

        store.restore(store.revisions(for: "summary").last!)
        XCTAssertEqual(store.preset("summary")?.userTemplate, original)
        XCTAssertEqual(store.revisions(for: "summary").count, 2, "the edited prompts were already saved")

        let reopened = PresetStore(defaults: defaults)
        XCTAssertEqual(reopened.revisions(for: "summary").count, 2)
    }

    func testPresetHistoryIsCapped() {
        let store = PresetStore(defaults: UserDefaults(suiteName: "oh-\(UUID().uuidString)")!)
        for i in 0..<(PresetStore.historyLimit + 5) {
            store.presets[0].userTemplate = "v\(i)"
            store.checkpoint("summary", reason: .saved)
        }
        let revs = store.revisions(for: "summary")
        XCTAssertEqual(revs.count, PresetStore.historyLimit)
        XCTAssertEqual(revs.first?.preset.userTemplate, "v\(PresetStore.historyLimit + 4)")
    }

    func testDeletedPresetCanBeBroughtBack() {
        let store = PresetStore(defaults: UserDefaults(suiteName: "oh-\(UUID().uuidString)")!)
        let id = store.add(name: "Psychoanalysis")
        store.delete(id)
        XCTAssertNil(store.preset(id))
        let rev = try! XCTUnwrap(store.deletedWithHistory.first { $0.presetId == id })
        store.restore(rev)
        XCTAssertEqual(store.preset(id)?.name, "Psychoanalysis")
        XCTAssertTrue(store.deletedWithHistory.filter { $0.presetId == id }.isEmpty)
    }

    // MARK: Export

    func testExportWritesEverythingWithAManifest() throws {
        let rec = try recording()
        try repo.snapshotVersion(of: rec, engineId: "parakeet", engineLabel: "Parakeet")
        try repo.replaceOutput(OutputDoc(presetId: "summary", title: "Summary", markdown: "one"), for: rec, provenance: prov)
        try repo.replaceOutput(OutputDoc(presetId: "summary", title: "Summary", markdown: "two"), for: rec, provenance: prov)
        let presets = PresetStore(defaults: UserDefaults(suiteName: "oh-\(UUID().uuidString)")!)
        let out = scratch.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let folder = try RecordingFolderExporter.export(rec, presets: presets, to: out, includeAudio: true)
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("Weekly - sync ("), folder.lastPathComponent)
        let manifest = try JSONDecoder.iso.decode(RecordingFolderExporter.Manifest.self,
            from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        let paths = manifest.files.map(\.path)
        XCTAssertTrue(paths.contains("audio/a.wav"))
        XCTAssertTrue(paths.contains("outputs/Summary.md"))
        XCTAssertTrue(paths.contains("presets/Summary.md"))
        XCTAssertTrue(paths.contains("prompts used/Summary.md") || paths.contains("outputs/prompts used/Summary.md"))
        XCTAssertEqual(paths.filter { $0.hasPrefix("outputs/history/") }.count, 1)
        XCTAssertEqual(paths.filter { $0.hasPrefix("versions/") }.count, 1)
        XCTAssertTrue(paths.contains { $0.hasPrefix("transcript/") && $0.hasSuffix(".txt") })
        let txt = manifest.files.first { $0.path == "outputs/Summary.md" }!
        let data = try Data(contentsOf: folder.appendingPathComponent(txt.path))
        XCTAssertEqual(txt.bytes, data.count)
        XCTAssertEqual(try RecordingFolderExporter.files(in: folder).first { $0.path == txt.path }?.sha256, txt.sha256)

        let second = try RecordingFolderExporter.export(rec, presets: presets, to: out, includeAudio: false)
        XCTAssertNotEqual(second, folder, "an existing export is never overwritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("audio").path))
    }

    func testSafeFileNames() {
        XCTAssertEqual(RecordingFolderExporter.safe("a/b:c"), "a-b-c")
        XCTAssertEqual(RecordingFolderExporter.safe("..hidden"), "hidden")
        XCTAssertEqual(RecordingFolderExporter.safe("   "), "Untitled")
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
