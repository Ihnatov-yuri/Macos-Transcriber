import XCTest
@testable import Transcriberr

/// Presets the user adds, renames, reorders and deletes (4.5.0), and the
/// presets saved by 4.4 and earlier, which have no `kind`.
final class PresetStoreTests: XCTestCase {
    var suiteName: String!
    var defaults: UserDefaults!

    override func setUp() {
        suiteName = "PresetStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFreshStoreHasBuiltinsInShippedOrder() {
        let store = PresetStore(defaults: defaults)
        XCTAssertEqual(store.presets.map(\.id), ["summary", "minutes", "context_rewrite", "clean", "translate_polish"])
        XCTAssertTrue(store.presets.allSatisfy(\.isBuiltin))
    }

    func testBuiltinKinds() {
        let store = PresetStore(defaults: defaults)
        let rewrites = store.presets.filter { $0.kind == .rewrite }.map(\.id)
        XCTAssertEqual(Set(rewrites), ["clean", "context_rewrite", "translate_polish"])
        XCTAssertEqual(Set(rewrites), PresetStore.Builtin.rewriteIds)
    }

    func testPre45PresetsDecodeWithKindFromId() throws {
        // Exactly the shape 4.4 wrote: no `kind` key.
        let json = """
        [{"id":"clean","name":"Clean","outputTitle":"Clean","systemTemplate":"s","userTemplate":"u"},
         {"id":"summary","name":"Summary","outputTitle":"Summary","systemTemplate":"s","userTemplate":"u"},
         {"id":"mine","name":"Mine","outputTitle":"Mine","systemTemplate":"s","userTemplate":"u"}]
        """
        let decoded = try JSONDecoder().decode([PostProcessingPreset].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.map(\.kind), [.rewrite, .analysis, .analysis])
    }

    func testUpgradedStoreKeepsUserAddedPresets() throws {
        defaults.set(true, forKey: "presets.upgraded.v4")
        let mine = PostProcessingPreset(id: "mine", name: "Mine", outputTitle: "Mine",
                                        systemTemplate: "s", userTemplate: "u")
        defaults.set(try JSONEncoder().encode(PresetStore.Builtin.all + [mine]), forKey: "presets.v1")
        let store = PresetStore(defaults: defaults)
        XCTAssertEqual(store.presets.last?.id, "mine")
        XCTAssertFalse(store.presets.last!.isBuiltin)
    }

    func testAddPersistsWithUniqueNameAndCustomId() {
        let store = PresetStore(defaults: defaults)
        let a = store.add(name: "Psychoanalysis")
        let b = store.add(name: "Psychoanalysis")
        XCTAssertTrue(a.hasPrefix("custom-"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(store.preset(b)?.name, "Psychoanalysis 2")
        XCTAssertEqual(store.preset(a)?.kind, .analysis)
        XCTAssertTrue(store.preset(a)!.placesTranscript)

        let reopened = PresetStore(defaults: defaults)
        XCTAssertEqual(reopened.presets.suffix(2).map(\.id), [a, b])
    }

    func testDuplicateLandsAfterOriginalAndLeavesItAlone() {
        let store = PresetStore(defaults: defaults)
        let copy = store.duplicate("clean")!
        let ids = store.presets.map(\.id)
        XCTAssertEqual(ids[ids.firstIndex(of: "clean")! + 1], copy)
        XCTAssertEqual(store.preset(copy)?.name, "Clean copy")
        XCTAssertEqual(store.preset(copy)?.kind, .rewrite)
        XCTAssertEqual(store.preset(copy)?.userTemplate, store.preset("clean")?.userTemplate)
        XCTAssertEqual(store.preset("clean"), PresetStore.Builtin.clean)
    }

    func testMoveStopsAtTheEnds() {
        let store = PresetStore(defaults: defaults)
        store.move("summary", by: -1)
        XCTAssertEqual(store.presets.first?.id, "summary")
        store.move("summary", by: 1)
        XCTAssertEqual(store.presets.map(\.id).prefix(2), ["minutes", "summary"])
        store.move("translate_polish", by: 1)
        XCTAssertEqual(store.presets.last?.id, "translate_polish")
    }

    func testRestoreBuiltinsBringsBackDeletedAndKeepsUserAdded() {
        let store = PresetStore(defaults: defaults)
        let mine = store.add(name: "Mine")
        store.delete("minutes")
        store.presets[0].name = "My summary"
        store.move("clean", by: -1)
        XCTAssertNil(store.preset("minutes"))

        store.restoreBuiltins()
        XCTAssertEqual(store.presets.map(\.id), PresetStore.Builtin.all.map(\.id) + [mine])
        XCTAssertEqual(store.preset("summary")?.name, "Summary")
    }

    func testResetBuiltinKeepsItsPlace() {
        let store = PresetStore(defaults: defaults)
        store.move("clean", by: -1)
        let idx = store.presets.firstIndex { $0.id == "clean" }
        store.presets[idx!].userTemplate = "edited"
        store.resetBuiltin("clean")
        XCTAssertEqual(store.presets.firstIndex { $0.id == "clean" }, idx)
        XCTAssertEqual(store.preset("clean"), PresetStore.Builtin.clean)
    }

    func testTemplateWithoutPlaceholderGetsTheTranscriptAppended() {
        var p = PresetStore.Builtin.summary
        p.userTemplate = "Psychoanalyse the speakers.\n"
        XCTAssertFalse(p.placesTranscript)
        XCTAssertEqual(p.templateWithTranscript,
                       "Psychoanalyse the speakers.\n\nTRANSCRIPT:\n{transcript_with_speakers}")
        p.userTemplate = "Text only: {transcript}"
        XCTAssertTrue(p.placesTranscript)
        XCTAssertEqual(p.templateWithTranscript, p.userTemplate)
    }
}
