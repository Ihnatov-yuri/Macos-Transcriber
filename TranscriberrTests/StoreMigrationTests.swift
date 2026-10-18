import SwiftData
import XCTest
@testable import Transcriberr

/// Opens a COPY of a real store, made by an older build, with this build's
/// schema, read-write as the app does at launch. Every release that adds a
/// field to a model must keep the user's library. Skipped unless
/// TRANSCRIBERR_MIGRATION_STORE points at such a copy (never the live store).
final class StoreMigrationTests: XCTestCase {
    /// The CLI/MCP server opens the store read-only, so it cannot migrate
    /// it: on an older store it fails with "launch Transcriberr.app once"
    /// (the MCP server retries on every call), and once the app has opened
    /// the store it reads it. Runs on a fresh copy.
    @MainActor
    func testReadOnlyOpenWorksOnceTheAppHasMigrated() throws {
        guard let path = ProcessInfo.processInfo.environment["TRANSCRIBERR_MIGRATION_STORE"] else {
            throw XCTSkip("set TRANSCRIBERR_MIGRATION_STORE to a copy of a real store")
        }
        let src = URL(fileURLWithPath: path)
        XCTAssertFalse(src.path.contains("Application Support"), "point this at a copy, not the live store")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ro-\(UUID().uuidString.prefix(6)).store")
        try FileManager.default.copyItem(at: src, to: copy)
        defer { for x in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: copy.path + x) } }

        let schema = Schema(TranscriberrSchema.models)
        // As the app opens it at launch.
        do {
            let app = try ModelContainer(for: schema, configurations: ModelConfiguration("Transcriberr", schema: schema, url: copy))
            let recordings = try ModelContext(app).fetchCount(FetchDescriptor<Recording>())
            XCTAssertGreaterThan(recordings, 0)
        }
        let kb = try KBService.openReadOnly(at: copy)
        XCTAssertGreaterThan(try kb.stats().recordings, 0)
    }

    @MainActor
    func testOlderStoreOpensWithNewFields() throws {
        guard let path = ProcessInfo.processInfo.environment["TRANSCRIBERR_MIGRATION_STORE"] else {
            throw XCTSkip("set TRANSCRIBERR_MIGRATION_STORE to a copy of a real store")
        }
        let url = URL(fileURLWithPath: path)
        XCTAssertFalse(url.path.contains("Application Support"), "point this at a copy, not the live store")
        let schema = Schema(TranscriberrSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration("Transcriberr", schema: schema, url: url))
        let context = ModelContext(container)
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        let segments = try context.fetchCount(FetchDescriptor<Segment>())
        print("migration: \(recordings.count) recordings, \(segments) segments")
        XCTAssertGreaterThan(recordings.count, 0)
        XCTAssertGreaterThan(segments, 0)
        // The new fields read as empty on old rows, and can be written.
        let r = try XCTUnwrap(recordings.first)
        XCTAssertNil(r.disputesJSON)
        XCTAssertNil(r.meetingContextJSON)
        r.disputesJSON = DisputeIndex.encode([WordDispute(chosen: "a", alternative: "b", before: "", after: "", start: 0, end: 1)])
        try context.save()
        XCTAssertEqual(DisputeIndex.decode(r.disputesJSON).count, 1)
    }
}
