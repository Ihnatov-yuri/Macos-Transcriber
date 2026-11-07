import XCTest
import Synchronization
@testable import Transcriberr

/// Backend fixes that need no model: speaker numbering.
final class BackendRaceTests: XCTestCase {

    // MARK: - Speaker numbering

    func testSpeakerNumberReadsTrailingDigits() {
        // FluidAudio's offline diarizer names clusters "S1", "S2"…
        XCTAssertEqual(SpeakerHint.number(fromKey: "S1"), 1)
        XCTAssertEqual(SpeakerHint.number(fromKey: "S12"), 12)
        XCTAssertEqual(SpeakerHint.number(fromKey: "SPEAKER_03"), 3)
    }

    func testSpeakerNumberFallbackIsStable() {
        let n = SpeakerHint.number(fromKey: "GUEST")
        XCTAssertEqual(n, SpeakerHint.number(fromKey: "GUEST"))
        XCTAssertTrue((10..<100).contains(n))
    }
}

/// The text model's idle release: it waits for the transcription queue,
/// and hands the engine back once the queue lets it.
final class TextIdleReleaseTests: XCTestCase {
    @MainActor
    func testIdleReleaseWaitsForTheQueue() async {
        let factory = BackendFactory(prompts: PromptStore(), apiKeys: APIKeyStore())
        let first = factory.backend(for: .localText) as AnyObject
        let queueBusy = Mutex(true)
        factory.textReleaseAllowed = { !queueBusy.withLock { $0 } }

        await factory.releaseTextIfQuiet()
        XCTAssertTrue(factory.backend(for: .localText) as AnyObject === first, "kept while a job runs")

        queueBusy.withLock { $0 = false }
        await factory.releaseTextIfQuiet()
        XCTAssertFalse(factory.backend(for: .localText) as AnyObject === first, "released once the queue is idle")
    }
}
