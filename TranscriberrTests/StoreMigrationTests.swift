import SwiftData
import XCTest
@testable import Transcriberr

/// Opens a COPY of a real store, made by an older build, with this build's
/// schema, read-write as the app does at launch. Every release that adds a
/// field to a model must keep the user's library. Skipped unless
/// TRANSCRIBERR_MIGRATION_STORE points at such a copy (never the live store).
final class StoreMigrationTests: XCTestCase {
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
