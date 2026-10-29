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

    /// English-only runs take the English pick, Ukrainian runs (alone or
    /// with English) the Ukrainian one; anything else, auto-detect included,
    /// takes the other one.
    func testModelFollowsTheRunsLanguage() {
        let turbo = WhisperModel.englishDefaultID, large = WhisperModel.defaultID, uk = WhisperModel.ukrainianDefaultID
        XCTAssertEqual(WhisperModel.forRun(["English"], setting: large, englishSetting: turbo, ukrainianSetting: uk).id, turbo)
        XCTAssertEqual(WhisperModel.forRun(["english"], setting: large, englishSetting: turbo, ukrainianSetting: uk).id, turbo)
        XCTAssertEqual(WhisperModel.forRun(["Ukrainian"], setting: large, englishSetting: turbo, ukrainianSetting: uk).id, uk)
        XCTAssertEqual(WhisperModel.forRun(["Ukrainian"], setting: large, englishSetting: turbo, ukrainianSetting: large).id, large)
        XCTAssertEqual(WhisperModel.forRun(["English", "Ukrainian"], setting: large, englishSetting: turbo, ukrainianSetting: uk).id, uk)
        XCTAssertEqual(WhisperModel.forRun(["German", "Ukrainian"], setting: large, englishSetting: turbo, ukrainianSetting: uk).id, large)
        XCTAssertEqual(WhisperModel.forRun([], setting: large, englishSetting: turbo, ukrainianSetting: uk).id, large)
        XCTAssertTrue(WhisperModel.all.contains { $0.id == WhisperModel.englishDefaultID })
        XCTAssertTrue(WhisperModel.all.contains { $0.id == WhisperModel.ukrainianDefaultID })
    }

    /// Whisper UK was trained on Ukrainian: picked for another language it
    /// gives way to the default, as an English-only model does.
    func testWhisperUKOnlyServesUkrainianRuns() {
        let uk = WhisperModel.ukrainianDefaultID
        XCTAssertEqual(WhisperModel.forRun(["German"], setting: uk).id, WhisperModel.defaultID)
        XCTAssertEqual(WhisperModel.forRun(["English"], englishSetting: uk).id, WhisperModel.defaultID)
        XCTAssertEqual(WhisperModel.all.filter(\.ukrainianOnly).map(\.id), [WhisperUKModel.id])
        XCTAssertEqual(WhisperModel.model(uk).folder, WhisperUKModel.release.modelDirectory)
    }

    /// The release on Hugging Face must carry every part WhisperKit loads
    /// from the folder, tokenizer included (loading is offline).
    func testWhisperUKReleaseNeedsEveryPartAndTheTokenizer() throws {
        let rel = WhisperUKModel.release
        var entries: [[String: Any]] = []
        for p in rel.requiredFiles {
            var e: [String: Any] = ["type": "file", "path": "\(rel.remoteFolder)/\(p)", "size": 100,
                                    "oid": String(repeating: "a", count: 40)]
            if p.hasSuffix(".bin") { e["lfs"] = ["oid": String(repeating: "b", count: 64), "size": 100] }
            entries.append(e)
        }
        let rev = String(repeating: "c", count: 40)
        XCTAssertNoThrow(try rel.validate(rel.manifest(revision: rev, tree: entries)))
        XCTAssertThrowsError(try rel.validate(rel.manifest(revision: rev, tree: entries.filter {
            ($0["path"] as? String)?.hasSuffix("tokenizer.json") != true
        })))
        XCTAssertTrue(rel.requiredFiles.contains("AudioEncoder.mlmodelc/weights/weight.bin"))
        XCTAssertEqual(rel.modelDirectory.lastPathComponent, "whisper-large-v3-turbo-uk")
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

    /// A version is saved after the run's pin is released; its label is
    /// taken at the start and names the model the run's language picks.
    func testRunLabelNamesTheWhisperModelForTheLanguage() {
        let en = BackendFactory.Kind.whisper.runLabel(languages: ["English"])
        XCTAssertEqual(en, "Whisper \(WhisperModel.forRun(["English"]).name) (local, CoreML)")
        XCTAssertEqual(BackendFactory.Kind.whisper.runLabel(languages: ["Ukrainian"]),
                       "Whisper \(WhisperModel.forRun(["Ukrainian"]).name) (local, CoreML)")
        XCTAssertNil(WhisperModel.inUse)
        XCTAssertEqual(BackendFactory.Kind.parakeet.runLabel(languages: ["English"]),
                       BackendFactory.Kind.parakeet.displayName)
    }

    /// A Whisper run that switched to Whisper UK after the job took its
    /// label is saved under the model it used.
    func testFinishedRunLabelNamesTheModelUsed() {
        let started = BackendFactory.Kind.whisper.runLabel(languages: [])
        WhisperModel.pin(for: [])
        WhisperModel.pin(for: ["Ukrainian"], ukrainianSetting: WhisperUKModel.id)
        let uk = "Whisper \(WhisperModel.model(WhisperUKModel.id).name) (local, CoreML)"
        XCTAssertEqual(BackendFactory.Kind.whisper.finishedRunLabel(started), uk)
        WhisperModel.unpin()
        XCTAssertEqual(BackendFactory.Kind.whisper.finishedRunLabel(started), uk)
        XCTAssertEqual(BackendFactory.Kind.parakeet.finishedRunLabel("Parakeet v3"), "Parakeet v3")
        XCTAssertFalse(uk.contains("Whisper Whisper"))
    }

    /// Only auto-language runs are probed.
    func testOnlyAutoLanguageRunsAreProbed() {
        XCTAssertFalse(WhisperModel.needsLanguageProbe(["Ukrainian"]))
        XCTAssertFalse(WhisperModel.needsLanguageProbe(["English"]))
        XCTAssertFalse(WhisperModel.needsLanguageProbe(["English", "Ukrainian"]))
    }

    /// The probe reads the loudest speech, never silence, at most five
    /// windows of 30 s, from either track.
    func testLanguageProbeTakesTheLoudestWindows() {
        let w = 480_000
        let quiet = [Float](repeating: 0, count: w)
        let soft = [Float](repeating: 0.01, count: w), loud = [Float](repeating: 0.2, count: w)
        let picked = TranscriptionRunner.loudestWindows([quiet + soft + loud, loud + quiet], count: 2)
        XCTAssertEqual(picked.count, 2)
        XCTAssertTrue(picked.allSatisfy { $0.count == w && $0[0] == 0.2 })
        XCTAssertEqual(TranscriptionRunner.loudestWindows([quiet + quiet]).count, 0)
        XCTAssertEqual(TranscriptionRunner.loudestWindows([[Float](repeating: 0.1, count: w / 4)]).count, 0)
        XCTAssertEqual(TranscriptionRunner.loudestWindows([[Float](repeating: 0.1, count: w * 8)]).count, 5)
    }

    func testOnlyDistilIsEnglishOnly() {
        XCTAssertEqual(WhisperModel.all.filter(\.englishOnly).map(\.id), ["distil-whisper_distil-large-v3"])
    }
}
