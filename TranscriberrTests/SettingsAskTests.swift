import XCTest
@testable import Transcriberr

/// "Ask to change a setting" (SettingsAsk.swift): the typed accessors, the
/// model's JSON, validation against the catalog, apply and undo. The model
/// is stubbed; nothing here loads a text model.
final class SettingsAskTests: XCTestCase {

    /// UIPrefs, DictationSettings and RecorderSettings write the standard
    /// defaults, which in the test host are the app's own: every test puts
    /// that domain back as it found it.
    private var savedDomain: [String: Any]?
    private var suiteName = ""
    private var suite: UserDefaults!
    private var stores: SettingsStores!

    override func setUp() {
        super.setUp()
        if let id = Bundle.main.bundleIdentifier { savedDomain = UserDefaults.standard.persistentDomain(forName: id) }
        suiteName = "SettingsAskTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        stores = SettingsStores(ui: UIPrefs(), dictation: DictationSettings(),
                                prompts: PromptStore(defaults: suite),
                                updates: UpdateChecker(currentVersion: "1.0", defaults: suite, askOnLaunch: false),
                                defaults: suite)
        snapshot = SettingAccessors.all.map { ($0.key, $0.get(stores)) }
    }

    private var snapshot: [(String, String)] = []

    override func tearDown() {
        // The shared RecorderSettings keeps values in memory: put those back
        // through the accessors, then the stored domain exactly.
        for (key, value) in snapshot { SettingAccessors.accessor(key)?.set(stores, value) }
        if let id = Bundle.main.bundleIdentifier {
            if let savedDomain { UserDefaults.standard.setPersistentDomain(savedDomain, forName: id) }
            else { UserDefaults.standard.removePersistentDomain(forName: id) }
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func change(_ key: String) -> SettingAccessor { SettingAccessors.accessor(key)! }

    // MARK: - Accessors

    func testEveryAccessorRoundTrips() {
        for a in SettingAccessors.all {
            let original = a.get(stores)
            let values: [String]
            switch a.kind(stores) {
            case .toggle: values = ["on", "off"]
            case .choice(let options): values = options.map(\.value)
            case .number(let range, let step, _):
                values = [range.lowerBound, range.upperBound, (range.lowerBound + range.upperBound) / 2]
                    .map { SettingKind.format(($0 / step).rounded() * step, step: step) }
            case .text: values = ["Test Person", ""]
            }
            XCTAssertFalse(values.isEmpty, "\(a.key) offers no values")
            for v in values {
                a.set(stores, v)
                XCTAssertEqual(a.get(stores), v, "\(a.key) didn't keep \(v)")
            }
            a.set(stores, original)
            XCTAssertEqual(a.get(stores), original, "\(a.key) didn't go back to \(original)")
        }
    }

    func testCurrentValueIsAlwaysAnAllowedOne() {
        for a in SettingAccessors.all {
            let kind = a.kind(stores)
            XCTAssertEqual(kind.normalize(a.get(stores)), a.get(stores), "\(a.key)'s current value isn't one it allows")
        }
    }

    func testAccessorKeysAreUniqueAndNamedAfterTheirSetting() {
        let keys = SettingAccessors.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "two accessors share a key")
        for a in SettingAccessors.all {
            let base = String(a.key.split(separator: ".").first!)
            XCTAssertEqual(base, a.setting.rawValue, "\(a.key) is filed under \(a.setting)")
            XCTAssertFalse(a.label.isEmpty)
        }
    }

    func testEverySettingIsEitherAskableOrExcluded() {
        let askable = Set(SettingAccessors.all.map(\.setting))
        for id in SettingID.allCases {
            let excluded = SettingAccessors.exclusion(id) != nil
            XCTAssertNotEqual(askable.contains(id), excluded,
                              "\(id) must be askable or excluded, not \(excluded ? "both" : "neither")")
        }
    }

    func testSensitiveAndDestructiveSettingsAreExcluded() {
        let never: [SettingID] = [.apiKeys, .virtualMicrophone, .voiceprint, .people, .presets, .snippets,
                                  .transcribePrompt, .translatePrompt, .dictationPrompt, .vocabulary,
                                  .vocabularyByLanguage, .learnedTerms, .learnedChoices, .domainPacks,
                                  .dictationAppRules, .whisperDownloads, .textModelComparison, .dictationAccessibility,
                                  // privacy: what leaves the Mac, who reads the library
                                  .textEngine, .assistants]
        for id in never {
            XCTAssertNotNil(SettingAccessors.exclusion(id), "\(id) should be excluded")
            XCTAssertFalse(SettingAccessors.all.contains { $0.setting == id }, "\(id) has an accessor")
        }
    }

    // MARK: - Parsing

    func testParsesAPlainArray() throws {
        let pairs = try SettingsAsk.parse(#"[{"id": "echoFilter", "value": "off"}, {"id": "tone", "value": "formal"}]"#)
        XCTAssertEqual(pairs.map(\.id), ["echoFilter", "tone"])
        XCTAssertEqual(pairs.map { $0.value as? String }, ["off", "formal"])
    }

    func testParsesAFencedAnswerWithProseAround() throws {
        let answer = """
        Sure, here it is:
        ```json
        [{"id": "defaultEngine", "value": "parakeet-uk"}]
        ```
        """
        XCTAssertEqual(try SettingsAsk.parse(answer).map(\.id), ["defaultEngine"])
    }

    func testParsesAWrapperObjectAndASingleObject() throws {
        XCTAssertEqual(try SettingsAsk.parse(#"{"changes": [{"id": "updates", "value": true}]}"#).map(\.id), ["updates"])
        XCTAssertEqual(try SettingsAsk.parse(#"{"id": "updates", "value": false}"#).map(\.id), ["updates"])
    }

    func testEmptyArrayIsNoChanges() throws {
        XCTAssertTrue(try SettingsAsk.parse("[]").isEmpty)
    }

    func testItemsWithoutIdOrValueAreSkipped() throws {
        let pairs = try SettingsAsk.parse(#"[{"id": "echoFilter"}, {"value": "on"}, 3, {"id": "tone", "value": "casual"}]"#)
        XCTAssertEqual(pairs.map(\.id), ["tone"])
    }

    func testProseIsNotJSON() {
        XCTAssertThrowsError(try SettingsAsk.parse("I turned off the echo filter for you.")) {
            XCTAssertEqual($0 as? SettingsAskError, .notJSON)
        }
        XCTAssertThrowsError(try SettingsAsk.parse("[not json]"))
    }

    // MARK: - Values

    func testToggleValuesInTheWordsAModelUses() {
        let k = SettingKind.toggle
        for raw: Any in [true, "on", "ON", "true", "yes", "Enabled", 1] { XCTAssertEqual(k.normalize(raw), "on", "\(raw)") }
        for raw: Any in [false, "off", "False", "no", "disabled", 0] { XCTAssertEqual(k.normalize(raw), "off", "\(raw)") }
        for raw: Any in ["maybe", 2, ["on"]] { XCTAssertNil(k.normalize(raw), "\(raw)") }
    }

    func testChoiceTakesValueOrNameButNothingElse() {
        let k = SettingKind.choice([SettingOption(value: "30", name: "Smooth"), SettingOption(value: "2", name: "Fine")])
        XCTAssertEqual(k.normalize("30"), "30")
        XCTAssertEqual(k.normalize("smooth"), "30")
        XCTAssertEqual(k.normalize(2), "2")
        XCTAssertEqual(k.normalize("2.0"), "2")
        XCTAssertNil(k.normalize("Coarse"))
        XCTAssertNil(k.normalize(true))
    }

    func testNumberMustBeInRangeAndSnapsToTheStep() {
        let k = SettingKind.number(0.8 ... 4.0, step: 0.1, unit: "s")
        XCTAssertEqual(k.normalize(1.53), "1.5")
        XCTAssertEqual(k.normalize("2"), "2.0")
        XCTAssertEqual(k.normalize(1), "1.0", "a JSON 1 is a number here, not true")
        XCTAssertNil(k.normalize(9))
        XCTAssertNil(k.normalize(0.2))
        XCTAssertNil(k.normalize(true))
        XCTAssertNil(k.normalize("fast"))
    }

    func testTextIsOneShortLine() {
        let k = SettingKind.text(maxLength: 10)
        XCTAssertEqual(k.normalize("  Yuri  "), "Yuri")
        XCTAssertNil(k.normalize(String(repeating: "x", count: 11)))
        XCTAssertNil(k.normalize("two\nlines"))
        XCTAssertNil(k.normalize(5))
    }

    // MARK: - Validation

    func testValidChangeShowsFromAndTo() {
        let echo = change("echoFilter")
        echo.set(stores, "on")
        let result = SettingsAsk.validate([("echoFilter", "off")], stores: stores)
        XCTAssertEqual(result.changes.count, 1)
        XCTAssertEqual(result.changes.first?.summary, "Echo filter in meetings: On \u{2192} Off")
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testUnknownIdIsDroppedAndSaid() {
        let result = SettingsAsk.validate([("warpDrive", "on")], stores: stores)
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.dropped.count, 1)
        XCTAssertTrue(result.dropped[0].contains("warpDrive"))
    }

    func testExcludedSettingIsRejectedWithItsReason() {
        let result = SettingsAsk.validate([("apiKeys", "sk-123"), ("virtualMicrophone", "on"),
                                           ("transcribePrompt", "say hi"), ("vocabulary.all", "x")], stores: stores)
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.dropped.count, 4)
        XCTAssertTrue(result.dropped[0].hasPrefix("API keys can't be changed by a request"))
        XCTAssertTrue(result.dropped.allSatisfy { $0.contains("can't be changed by a request") })
    }

    func testValueTheSettingDoesntTakeIsDropped() {
        let result = SettingsAsk.validate([("defaultEngine", BackendFactory.Kind.localText.rawValue), ("tone", "angry")], stores: stores)
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.dropped.count, 2)
        XCTAssertTrue(result.dropped[0].hasPrefix(SettingID.defaultEngine.label))
    }

    func testAlreadySetIsUnchangedNotAChange() {
        change("tone").set(stores, "formal")
        let result = SettingsAsk.validate([("tone", "Formal")], stores: stores)
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(result.unchanged, ["Tone is already Formal."])
    }

    func testLaterEntryForTheSameSettingWins() {
        change("tone").set(stores, "neutral")
        let result = SettingsAsk.validate([("tone", "formal"), ("tone", "casual")], stores: stores)
        XCTAssertEqual(result.changes.map(\.to), ["casual"])
    }

    func testParakeetUKForUkrainian() {
        change("defaultEngine").set(stores, BackendFactory.Kind.parakeet.rawValue)
        let result = SettingsAsk.validate([("defaultEngine", "parakeet-uk")], stores: stores)
        XCTAssertEqual(result.changes.first?.to, BackendFactory.Kind.parakeetUK.rawValue)
        XCTAssertEqual(result.changes.first?.toName, BackendFactory.Kind.parakeetUK.displayName)
    }

    // MARK: - Apply and undo

    func testApplyThenUndo() {
        change("echoFilter").set(stores, "on")
        change("tone").set(stores, "neutral")
        let result = SettingsAsk.validate([("echoFilter", false), ("tone", "technical")], stores: stores)
        let snap = SettingsAsk.apply(result.changes, stores: stores)
        XCTAssertEqual(change("echoFilter").get(stores), "off")
        XCTAssertEqual(stores.recorder.meetingEchoFilter, false)
        XCTAssertEqual(stores.prompts.tone, .technical)
        SettingsAsk.undo(snap, stores: stores)
        XCTAssertEqual(stores.recorder.meetingEchoFilter, true)
        XCTAssertEqual(stores.prompts.tone, .neutral)
    }

    func testNothingChangesWithoutApply() {
        change("echoFilter").set(stores, "on")
        _ = SettingsAsk.validate([("echoFilter", "off")], stores: stores)
        XCTAssertEqual(change("echoFilter").get(stores), "on")
    }

    func testMergeEnginesSwapAndUndoPutsBothBack() throws {
        let a = change("mergeEngines.a"), b = change("mergeEngines.b")
        guard case .choice(let options) = a.kind(stores), options.count >= 2 else { throw XCTSkip("fewer than two merge engines") }
        a.set(stores, options[0].value)
        b.set(stores, options[1].value)
        let result = SettingsAsk.validate([("mergeEngines.a", options[1].value)], stores: stores)
        let snap = SettingsAsk.apply(result.changes, stores: stores)
        XCTAssertEqual(a.get(stores), options[1].value)
        XCTAssertEqual(b.get(stores), options[0].value, "picking B's engine for A swaps them")
        SettingsAsk.undo(snap, stores: stores)
        XCTAssertEqual(a.get(stores), options[0].value)
        XCTAssertEqual(b.get(stores), options[1].value)
    }

    func testApplySkipsAValueThatIsNoLongerAllowed() {
        change("tone").set(stores, "neutral")
        let bogus = SettingChange(key: "tone", label: "Tone", from: "neutral", to: "shouty", fromName: "Neutral", toName: "Shouty")
        SettingsAsk.apply([bogus], stores: stores)
        XCTAssertEqual(stores.prompts.tone, .neutral)
    }

    // MARK: - The model call

    private struct StubModel: SettingsAskModel {
        var reply: String = "[]"
        var error: Error?
        let seen = Seen()
        final class Seen { var system = ""; var user = "" }

        func answer(system: String, user: String, maxTokens: Int) async throws -> String {
            seen.system = system
            seen.user = user
            if let error { throw error }
            return reply
        }
    }

    func testAskSendsTheCatalogAndChecksTheAnswer() async throws {
        change("echoFilter").set(stores, "on")
        let model = StubModel(reply: "```json\n[{\"id\": \"echoFilter\", \"value\": \"off\"}, {\"id\": \"apiKeys\", \"value\": \"x\"}]\n```")
        let result = try await SettingsAsk.ask("turn off the echo filter", stores: stores, model: model)
        XCTAssertEqual(result.changes.map(\.summary), ["Echo filter in meetings: On \u{2192} Off"])
        XCTAssertEqual(result.dropped.count, 1)
        XCTAssertEqual(change("echoFilter").get(stores), "on", "asking changes nothing")

        XCTAssertTrue(model.seen.user.contains("REQUEST: turn off the echo filter"))
        XCTAssertTrue(model.seen.user.contains("echoFilter | Echo filter in meetings | on | on | off"))
        XCTAssertFalse(model.seen.user.contains("apiKeys"), "excluded settings never reach the model")
        XCTAssertFalse(model.seen.user.contains("transcribePrompt"))
        XCTAssertTrue(model.seen.system.contains("JSON"))
    }

    func testCatalogStaysCompact() {
        let catalog = SettingsAsk.catalog(stores)
        XCTAssertEqual(catalog.split(separator: "\n").count, SettingAccessors.all.count)
        // A small on-device model reads it on every request.
        XCTAssertLessThan(catalog.count, 16_000)
    }

    func testModelFailureIsReported() async {
        struct Boom: LocalizedError { var errorDescription: String? { "not downloaded" } }
        do {
            _ = try await SettingsAsk.ask("x", stores: stores, model: StubModel(error: Boom()))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SettingsAskError, .model("not downloaded"))
        }
    }

    func testProseAnswerIsReported() async {
        do {
            _ = try await SettingsAsk.ask("x", stores: stores, model: StubModel(reply: "Done! I changed it."))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SettingsAskError, .notJSON)
        }
    }
}
