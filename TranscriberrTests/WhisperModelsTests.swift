import XCTest
@testable import Transcriberr

final class WhisperModelsTests: XCTestCase {
    /// WhisperKit downloads the folders matching `*<id>/*`: an id that ends
    /// another id would fetch both, or fail as ambiguous.
    func testEveryModelIdMatchesOneRepoFolder() {
        let ids = WhisperModel.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for a in ids {
            for b in ids where a != b {
                XCTAssertFalse(b.hasSuffix(a), "\(a) would also match \(b)")
            }
        }
    }

    func testDefaultIsLargeV3AndUnknownFallsBack() {
        XCTAssertEqual(WhisperModel.all.first?.id, WhisperModel.defaultID)
        XCTAssertEqual(WhisperModel.model("openai_whisper-nonexistent").id, WhisperModel.defaultID)
        let saved = UserDefaults.standard.string(forKey: WhisperModel.settingsKey)
        defer { UserDefaults.standard.set(saved, forKey: WhisperModel.settingsKey) }
        UserDefaults.standard.set("openai_whisper-small", forKey: WhisperModel.settingsKey)
        XCTAssertEqual(WhisperModel.selected.name, "small")
        UserDefaults.standard.removeObject(forKey: WhisperModel.settingsKey)
        XCTAssertEqual(WhisperModel.selected.id, WhisperModel.defaultID)
    }

    /// English-only runs take the English pick; anything else, auto-detect
    /// and mixed included, takes the other one.
    func testModelFollowsTheRunsLanguage() {
        let turbo = WhisperModel.englishDefaultID, large = WhisperModel.defaultID
        XCTAssertEqual(WhisperModel.forRun(["English"], setting: large, englishSetting: turbo).id, turbo)
        XCTAssertEqual(WhisperModel.forRun(["english"], setting: large, englishSetting: turbo).id, turbo)
        XCTAssertEqual(WhisperModel.forRun(["Ukrainian"], setting: large, englishSetting: turbo).id, large)
        XCTAssertEqual(WhisperModel.forRun(["English", "Ukrainian"], setting: large, englishSetting: turbo).id, large)
        XCTAssertEqual(WhisperModel.forRun([], setting: large, englishSetting: turbo).id, large)
        XCTAssertTrue(WhisperModel.all.contains { $0.id == WhisperModel.englishDefaultID })
    }

    func testMigrationMovesASmallerPickToEnglish() {
        let d = UserDefaults(suiteName: "WhisperModelsTests.migration")!
        defer { d.removePersistentDomain(forName: "WhisperModelsTests.migration") }
        // Old single pick of turbo: it serves English now, others get large-v3.
        d.set("openai_whisper-large-v3-v20240930_turbo", forKey: WhisperModel.settingsKey)
        WhisperModel.migrateSettings(d)
        XCTAssertEqual(d.string(forKey: WhisperModel.englishSettingsKey), "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(d.string(forKey: WhisperModel.settingsKey), WhisperModel.defaultID)
        // Runs once: a later pick for other languages stays.
        d.set("openai_whisper-medium", forKey: WhisperModel.settingsKey)
        WhisperModel.migrateSettings(d)
        XCTAssertEqual(d.string(forKey: WhisperModel.settingsKey), "openai_whisper-medium")
        // Fresh install or large-v3 kept: English gets the fast default.
        d.removePersistentDomain(forName: "WhisperModelsTests.migration")
        WhisperModel.migrateSettings(d)
        XCTAssertEqual(d.string(forKey: WhisperModel.englishSettingsKey), WhisperModel.englishDefaultID)
        XCTAssertNil(d.string(forKey: WhisperModel.settingsKey))
    }

    func testOnlyDistilIsEnglishOnly() {
        XCTAssertEqual(WhisperModel.all.filter(\.englishOnly).map(\.id), ["distil-whisper_distil-large-v3"])
    }
}
