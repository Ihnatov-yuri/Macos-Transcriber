import XCTest
import SwiftData
@testable import Transcriberr

/// Folder/tag organization: every Library action routes through the
/// repository — exercised here against an in-memory store.
@MainActor
final class FolderTagTests: XCTestCase {
    var container: ModelContainer!
    var repo: RecordingRepository!

    override func setUp() async throws {
        let schema = Schema(TranscriberrSchema.models)
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        repo = RecordingRepository(context: container.mainContext)
    }

    private func makeRecording(_ title: String) throws -> Recording {
        let rec = Recording(title: title, audioPath: "/tmp/\(title).wav")
        try repo.save(rec)
        return rec
    }

    // MARK: - Folders

    func testCreateFolderTrimsAndRejectsDuplicates() throws {
        try repo.createFolder(named: "  Work  ")
        XCTAssertEqual(try repo.folders().map(\.name), ["Work"])
        XCTAssertThrowsError(try repo.createFolder(named: "work"))
        XCTAssertThrowsError(try repo.createFolder(named: "   "))
    }

    func testMoveAndUnfile() throws {
        let rec = try makeRecording("a")
        let folder = try repo.createFolder(named: "Trips")
        try repo.move(rec, to: folder)
        XCTAssertEqual(rec.folder?.name, "Trips")
        XCTAssertEqual(folder.recordings.count, 1)
        try repo.move(rec, to: nil)
        XCTAssertNil(rec.folder)
    }

    func testDeleteFolderLeavesRecordingsAlive() throws {
        let rec = try makeRecording("a")
        let folder = try repo.createFolder(named: "Ideas")
        try repo.move(rec, to: folder)
        try repo.deleteFolder(folder)
        XCTAssertNil(rec.folder)
        XCTAssertEqual(try repo.all().count, 1)
        XCTAssertTrue(try repo.folders().isEmpty)
    }

    func testRenameFolderRejectsCollision() throws {
        let a = try repo.createFolder(named: "A")
        try repo.createFolder(named: "B")
        XCTAssertThrowsError(try repo.renameFolder(a, to: "b"))
        try repo.renameFolder(a, to: "C")
        XCTAssertEqual(a.name, "C")
    }

    // MARK: - Tags

    func testAddTagFindsExistingCaseInsensitively() throws {
        let a = try makeRecording("a")
        let b = try makeRecording("b")
        let t1 = try repo.addTag(named: "Meeting", to: a)
        let t2 = try repo.addTag(named: "  meeting ", to: b)
        XCTAssertEqual(t1.id, t2.id)
        XCTAssertEqual(try repo.tags().count, 1)
        // no-op re-add
        try repo.addTag(named: "MEETING", to: a)
        XCTAssertEqual(a.tags.count, 1)
    }

    func testRemoveTagPrunesOrphans() throws {
        let a = try makeRecording("a")
        let b = try makeRecording("b")
        let tag = try repo.addTag(named: "x", to: a)
        try repo.addTag(named: "x", to: b)
        try repo.removeTag(tag, from: a)
        XCTAssertEqual(try repo.tags().count, 1, "still used by b")
        try repo.removeTag(tag, from: b)
        XCTAssertTrue(try repo.tags().isEmpty, "orphan pruned")
    }

    func testSetTagsDiffs() throws {
        let rec = try makeRecording("a")
        try repo.setTags(["one", "two"], on: rec)
        XCTAssertEqual(Set(rec.tags.map(\.name)), ["one", "two"])
        try repo.setTags(["Two", "three"], on: rec)
        XCTAssertEqual(Set(rec.tags.map(\.name)), ["two", "three"])
        XCTAssertEqual(try repo.tags().count, 2, "'one' pruned")
    }

    func testDeleteRecordingLeavesSharedOrganizersIntact() throws {
        let a = try makeRecording("a")
        let b = try makeRecording("b")
        let folder = try repo.createFolder(named: "F")
        try repo.move(a, to: folder)
        try repo.move(b, to: folder)
        try repo.addTag(named: "t", to: a)
        try repo.addTag(named: "t", to: b)
        try repo.delete(a)
        XCTAssertEqual(try repo.folders().count, 1)
        XCTAssertEqual(try repo.tags().count, 1)
        XCTAssertEqual(folder.recordings.count, 1)
    }
}
