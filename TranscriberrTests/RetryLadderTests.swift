import XCTest
@testable import Transcriberr

/// The chunk retry ladder: what each kind of failure costs a run. A hang
/// is simulated by an attempt that sleeps past a short timeout.
final class RetryLadderTests: XCTestCase {
    private actor Calls {
        var attempts = 0, recoveries = 0, fallbacks = 0
        func attempt() -> Int { attempts += 1; return attempts }
        func recovered() { recoveries += 1 }
        func fellBack() { fallbacks += 1 }
    }

    private let timeout: TimeInterval = 0.2
    private static func hang() async throws { try await Task.sleep(nanoseconds: 2_000_000_000) }
    private static let budget = WhisperBackend.DecodeBudgetExceeded(chunkSeconds: 26, seconds: 101)

    private func continuation() -> AsyncThrowingStream<ASREvent, Error>.Continuation {
        AsyncThrowingStream<ASREvent, Error>.makeStream().continuation
    }

    override func setUp() { RunGapLog.reset() }

    @MainActor
    func testHangRebuildsTheEngineAndRetries() async throws {
        let calls = Calls()
        let text = try await TranscriptionRunner.withRetryLadder(
            timeout: timeout, empty: "", continuation: continuation(),
            recover: { await calls.recovered() }, fallback: nil
        ) {
            if await calls.attempt() == 1 { try await Self.hang() }
            return "words"
        }
        XCTAssertEqual(text, "words")
        let recoveries = await calls.recoveries
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(RunGapLog.take(), [:])
    }

    @MainActor
    func testTwiceHungPartIsSkippedWithAGap() async throws {
        let calls = Calls()
        let text = try await TranscriptionRunner.withRetryLadder(
            timeout: timeout, empty: "", continuation: continuation(),
            recover: { await calls.recovered() }, fallback: nil
        ) {
            _ = await calls.attempt()
            try await Self.hang()
            return "never"
        }
        XCTAssertEqual(text, "")
        let recoveries = await calls.recoveries
        XCTAssertEqual(recoveries, 2, "rebuilt after each hang, for the parts behind it")
        XCTAssertEqual(RunGapLog.take(), [.wedged: 1])
    }

    @MainActor
    func testTwiceHungPartGoesToTheFallback() async throws {
        let calls = Calls()
        let text = try await TranscriptionRunner.withRetryLadder(
            timeout: timeout, empty: "", continuation: continuation(),
            recover: { await calls.recovered() },
            fallback: { await calls.fellBack(); return "solo" }
        ) {
            try await Self.hang()
            return "never"
        }
        XCTAssertEqual(text, "solo")
        let fallbacks = await calls.fallbacks
        XCTAssertEqual(fallbacks, 1)
        XCTAssertEqual(RunGapLog.take(), [:], "the fallback read it: no gap")
    }

    @MainActor
    func testOutOfTimeTwiceLeavesThePartEmptyWithoutARebuild() async throws {
        let calls = Calls()
        let text = try await TranscriptionRunner.withRetryLadder(
            timeout: timeout, empty: "", continuation: continuation(),
            recover: { await calls.recovered() }, fallback: nil
        ) {
            _ = await calls.attempt()
            throw Self.budget
        }
        XCTAssertEqual(text, "")
        let (attempts, recoveries) = (await calls.attempts, await calls.recoveries)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(recoveries, 0, "a busy Mac is not a stuck engine")
        XCTAssertEqual(RunGapLog.take(), [.outOfTime: 1])
    }

    /// The case one hand-copied path missed: it ended the whole run.
    @MainActor
    func testOutOfTimeOnTheRetryAfterAHangLeavesThePartEmpty() async throws {
        let calls = Calls()
        let text = try await TranscriptionRunner.withRetryLadder(
            timeout: timeout, empty: "", continuation: continuation(),
            recover: { await calls.recovered() }, fallback: nil
        ) {
            if await calls.attempt() == 1 { try await Self.hang() }
            throw Self.budget
        }
        XCTAssertEqual(text, "")
        XCTAssertEqual(RunGapLog.take(), [.outOfTime: 1])
    }

    @MainActor
    func testOtherErrorsEndTheRun() async {
        do {
            _ = try await TranscriptionRunner.withRetryLadder(
                timeout: timeout, empty: "", continuation: continuation(),
                recover: {}, fallback: nil
            ) { throw URLError(.cannotDecodeContentData) }
            XCTFail("an engine error is not a hang")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotDecodeContentData)
        }
    }

    // Super, both engines failed on a chunk: cancellation and an exhausted
    // decode budget go back to the ladder; anything else retries in place.
    @MainActor
    func testBothEnginesFailingHandsCancelAndBudgetToTheLadder() {
        struct Other: Error {}
        XCTAssertTrue(EnsembleBackend.ladderError(CancellationError(), Other()) is CancellationError)
        XCTAssertTrue(EnsembleBackend.ladderError(Other(), CancellationError()) is CancellationError)
        XCTAssertEqual(EnsembleBackend.ladderError(Self.budget, Other()) as? WhisperBackend.DecodeBudgetExceeded, Self.budget)
        XCTAssertEqual(EnsembleBackend.ladderError(Other(), Self.budget) as? WhisperBackend.DecodeBudgetExceeded, Self.budget)
        XCTAssertNil(EnsembleBackend.ladderError(Other(), Other()))
    }
}
