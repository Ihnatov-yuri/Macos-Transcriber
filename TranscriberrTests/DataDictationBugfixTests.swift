import XCTest
import SwiftData
@testable import Transcriberr

/// Regressions found in the Data / Dictation review.
@MainActor
final class DataDictationBugfixTests: XCTestCase {
    var container: ModelContainer!
    var repo: RecordingRepository!
    var backupRoot: URL!
    var scratch: URL!

    override func setUp() async throws {
        let schema = Schema(TranscriberrSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        repo = RecordingRepository(context: container.mainContext)
        backupRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ddb-backups-\(UUID().uuidString.prefix(6))")
        setenv("TRANSCRIBERR_BACKUP_ROOT", backupRoot.path, 1)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ddb-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        BackupService.flush()
        unsetenv("TRANSCRIBERR_BACKUP_ROOT")
        try? FileManager.default.removeItem(at: backupRoot)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A second file under the same name inside one export gets a number
    /// instead of replacing the first.
    func testExportWriteNeverOverwrites() throws {
        let url = scratch.appendingPathComponent("Notes.md")
        try RecordingFolderExporter.write("one", to: url)
        try RecordingFolderExporter.write("two", to: url)
        try RecordingFolderExporter.write("three", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: scratch.appendingPathComponent("Notes 2.md"), encoding: .utf8), "two")
        XCTAssertEqual(try String(contentsOf: scratch.appendingPathComponent("Notes 3.md"), encoding: .utf8), "three")
    }

    /// Two presets whose outputs carry the same heading both reach the export.
    func testExportKeepsOutputsWithTheSameTitle() throws {
        let audio = scratch.appendingPathComponent("a.wav")
        try Data("RIFF".utf8).write(to: audio)
        let rec = Recording(title: "Sync", audioPath: audio.path, durationSeconds: 1)
        try repo.save(rec)
        try repo.appendSegments([Segment(startSeconds: 0, endSeconds: 1, text: "hello")], to: rec)
        try repo.replaceOutput(OutputDoc(presetId: "custom-a", title: "Notes", markdown: "first"), for: rec)
        try repo.replaceOutput(OutputDoc(presetId: "custom-b", title: "Notes", markdown: "second"), for: rec)
        let presets = PresetStore(defaults: UserDefaults(suiteName: "ddb-\(UUID().uuidString)")!)
        let out = scratch.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let folder = try RecordingFolderExporter.export(rec, presets: presets, to: out, includeAudio: false)
        let outputs = folder.appendingPathComponent("outputs")
        let names = try FileManager.default.contentsOfDirectory(atPath: outputs.path).filter { $0.hasSuffix(".md") }.sorted()
        XCTAssertEqual(names, ["Notes 2.md", "Notes.md"])
        let bodies = try names.map { try String(contentsOf: outputs.appendingPathComponent($0), encoding: .utf8) }
        XCTAssertTrue(bodies.contains { $0.contains("first") })
        XCTAssertTrue(bodies.contains { $0.contains("second") })
    }
}
