import XCTest
@testable import Transcriberr

/// Settings search and the Normal / Advanced split (SettingsCatalog.swift).
final class SettingsCatalogTests: XCTestCase {

    private func normal(_ query: String = "") -> SettingsFilter { SettingsFilter(level: .normal, query: query) }
    private func advanced(_ query: String = "") -> SettingsFilter { SettingsFilter(level: .advanced, query: query) }

    func testEverySettingHasALabelHelpAndUniqueLabel() {
        for id in SettingID.allCases {
            XCTAssertFalse(id.label.isEmpty, "\(id) has no label")
            XCTAssertFalse(id.help.isEmpty, "\(id) has no help")
        }
        let labels = SettingID.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "two settings share a label")
    }

    func testEverySectionHasSettings() {
        for section in SettingsSection.allCases {
            XCTAssertFalse(section.items.isEmpty, "\(section.title) has no settings")
        }
    }

    func testSectionKeysStayStable() {
        // Fold state is saved by these keys, and the text-model prompt
        // scrolls to "C".
        XCTAssertEqual(SettingsSection.allCases.map(\.rawValue), ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K"])
        XCTAssertEqual(SettingsSection.models.rawValue, "C")
    }

    func testEverySettingInAFormSectionHasAHeightEstimate() {
        for id in SettingID.allCases where id.section.fullFormHeight != nil {
            XCTAssertGreaterThan(id.formRowsHeight, 0, "\(id) has no Form height estimate")
        }
    }

    func testNormalShowsTheEverydaySettings() {
        let f = normal()
        for id: SettingID in [.microphone, .defaultEngine, .textModelPicks, .presets,
                              .dictationHotkey, .dictationRecognition, .updates] {
            XCTAssertTrue(f.shows(id), "Normal hides \(id)")
        }
    }

    func testNormalHidesTheExpertSettings() {
        let f = normal()
        for id: SettingID in [.mergeEngines, .superMaxQuality, .textModelRulings, .transcribePrompt,
                              .voiceprint, .learnedTerms, .apiKeys, .assistants, .dictationPrompt, .echoFilter] {
            XCTAssertFalse(f.shows(id), "Normal shows \(id)")
        }
        XCTAssertFalse(f.showsSection(SettingsSection.apiKeys))
        XCTAssertFalse(f.showsSection(SettingsSection.assistants))
        XCTAssertFalse(f.showsSection(SettingsSection.prompts))
        XCTAssertTrue(f.showsSection(SettingsSection.models), "the text-model prompt scrolls to Models")
    }

    func testAdvancedShowsEverything() {
        let f = advanced()
        XCTAssertTrue(SettingID.allCases.allSatisfy(f.shows))
        XCTAssertEqual(f.visibleSections, SettingsSection.allCases)
        XCTAssertFalse(f.isNarrowed)
    }

    func testTheDefaultFilterShowsEverything() {
        // The macOS Settings scene renders the tabs without a filter.
        XCTAssertTrue(SettingID.allCases.allSatisfy(SettingsFilter.everything.shows))
    }

    func testSearchMatchesLabels() {
        let f = normal("microphone")
        XCTAssertTrue(f.shows(.microphone))
        XCTAssertFalse(f.shows(.presets))
    }

    func testSearchMatchesHelpText() {
        // Only in the help: "...Off with headphones."
        XCTAssertTrue(normal("headphones").shows(.echoFilter))
        // Only in the help of the calendar toggle.
        XCTAssertTrue(normal("attendees").shows(.calendarContext))
    }

    func testSearchIgnoresCaseAndDiacritics() {
        XCTAssertTrue(normal("WHISPER").shows(.whisperModels))
        XCTAssertTrue(normal("mícrophone").shows(.microphone))
    }

    func testEveryWordMustMatch() {
        XCTAssertTrue(normal("echo teams").shows(.echoFilter))
        XCTAssertFalse(normal("echo zzqx").shows(.echoFilter))
    }

    func testSearchCoversAdvancedFromNormalAndSaysSo() {
        let f = normal("api key")
        XCTAssertTrue(f.shows(.apiKeys))
        XCTAssertEqual(f.advancedMatches(in: .apiKeys), [.apiKeys])
        // In Advanced nothing needs pointing out.
        XCTAssertTrue(advanced("api key").advancedMatches(in: .apiKeys).isEmpty)
        // Without a query there are no "matches".
        XCTAssertTrue(normal().advancedMatches(in: .engines).isEmpty)
    }

    func testNormalMatchesAreNotFlaggedAdvanced() {
        let f = normal("default engine")
        XCTAssertTrue(f.shows(.defaultEngine))
        XCTAssertFalse(f.advancedMatches(in: .engines).contains(.defaultEngine))
    }

    func testNoMatchHidesEverySection() {
        let f = normal("qqzzxxnothing")
        XCTAssertTrue(f.isSearching)
        XCTAssertTrue(f.visibleSections.isEmpty)
    }

    func testBlankQueryIsNotASearch() {
        let f = normal("   ")
        XCTAssertFalse(f.isSearching)
        XCTAssertFalse(f.shows(.apiKeys))
    }

    func testSectionTitleFindsItsSettings() {
        let f = normal("dictation")
        XCTAssertEqual(f.visible(in: .dictation), SettingsSection.dictation.items)
    }

    func testFormHeightShrinksWhenNarrowed() {
        XCTAssertEqual(advanced().formHeight(for: .dictation), 760)
        let normalHeight = normal().formHeight(for: .dictation)
        XCTAssertLessThan(normalHeight, 760)
        XCTAssertGreaterThan(normalHeight, 200)
        XCTAssertLessThan(normal("hotkey").formHeight(for: .dictation), normalHeight)
        XCTAssertEqual(normal().formHeight(for: .audio), 0, "Audio input is not a Form")
    }

    func testDisplayLettersFollowVisibleOrder() {
        XCTAssertEqual((0..<3).map(SettingsScreen.letter), ["A", "B", "C"])
    }
}
