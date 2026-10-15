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

    func testOnlyDistilIsEnglishOnly() {
        XCTAssertEqual(WhisperModel.all.filter(\.englishOnly).map(\.id), ["distil-whisper_distil-large-v3"])
    }
}
