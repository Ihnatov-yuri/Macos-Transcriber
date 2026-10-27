import XCTest
@testable import Transcriberr

/// The Transcriberr Microphone's plumbing that runs without the driver: the
/// ring between the voice unit and the feed device, the rate converter, and
/// the install script's quoting. No audio device is opened here.
final class VirtualMicrophoneTests: XCTestCase {

    private func write(_ ring: FeedRing, _ n: Int, _ v: Float) {
        let a = [Float](repeating: v, count: n)
        a.withUnsafeBufferPointer { ring.write($0) }
    }

    private func read(_ ring: FeedRing, _ n: Int) -> [Float] {
        var out = [Float](repeating: -1, count: n)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: n) }
        return out
    }

    func testSilenceUntilTheCushionIsThere() {
        let ring = FeedRing()
        write(ring, 300, 0.5)
        write(ring, 300, 0.5)
        XCTAssertEqual(read(ring, 256), [Float](repeating: 0, count: 256),
                       "10 ms cushion + this read not there yet: silence, nothing consumed")
        XCTAssertEqual(ring.buffered, 600)
        write(ring, 300, 0.5)
        XCTAssertEqual(read(ring, 256), [Float](repeating: 0.5, count: 256))
    }

    func testOrderIsKept() {
        let ring = FeedRing()
        let ramp = (0..<1000).map(Float.init)
        for i in stride(from: 0, to: 1000, by: 200) { Array(ramp[i..<(i + 200)]).withUnsafeBufferPointer { ring.write($0) } }
        XCTAssertEqual(read(ring, 256), Array(ramp[0..<256]))
        XCTAssertEqual(read(ring, 256), Array(ramp[256..<512]))
    }

    /// The feed must never replay old audio: an empty ring reads silence,
    /// and waits for a fresh cushion before playing again.
    func testUnderrunPadsWithSilenceAndReprimes() {
        let ring = FeedRing()
        for _ in 0..<4 { write(ring, 200, 0.25) }
        XCTAssertEqual(read(ring, 256), [Float](repeating: 0.25, count: 256))
        let out = read(ring, 800)
        XCTAssertEqual(Array(out[0..<544]), [Float](repeating: 0.25, count: 544))
        XCTAssertEqual(Array(out[544...]), [Float](repeating: 0, count: 256))
        XCTAssertEqual(ring.underruns, 1)
        write(ring, 100, 0.75)
        XCTAssertEqual(read(ring, 50), [Float](repeating: 0, count: 50), "re-priming: a short backlog stays put")
    }

    /// Engine deliveries of 480 against feed reads of 256 for a minute: no
    /// hole once primed, and the backlog (the call's extra delay) stays
    /// under the ceiling.
    func testSteadyStateHasNoHolesAndBoundedDelay() {
        let ring = FeedRing()
        var produced = 0, consumed = 0, holes = 0
        var playing = false
        for _ in 0..<(48_000 * 60 / 16) {          // 16-sample ticks
            produced += 16; consumed += 16
            if produced >= 480 { write(ring, 480, 1); produced -= 480 }
            if consumed >= 256 {
                let out = read(ring, 256)
                consumed -= 256
                if playing, out.contains(0) { holes += 1 }
                if out.contains(1) { playing = true }
            }
            XCTAssertLessThanOrEqual(ring.buffered, 480 + 4 * 480)
        }
        XCTAssertEqual(ring.underruns, 0)
        XCTAssertEqual(holes, 0)
    }

    func testDriftIsTrimmedToTheCushion() {
        let ring = FeedRing()
        for _ in 0..<20 { write(ring, 480, 1) }     // producer ran ahead
        XCTAssertLessThanOrEqual(ring.buffered, 480 * 5)
        XCTAssertGreaterThanOrEqual(ring.buffered, 480)
        XCTAssertGreaterThan(ring.dropped, 0)
    }

    func testResetEmptiesIt() {
        let ring = FeedRing()
        write(ring, 2000, 0.5)
        ring.reset()
        XCTAssertEqual(ring.buffered, 0)
        XCTAssertEqual(read(ring, 256), [Float](repeating: 0, count: 256))
    }

    // MARK: - Rate conversion

    private func resample(_ blocks: [[Float]], from: Double, to: Double) -> [Float] {
        var r = LinearResampler()
        var out: [Float] = []
        for b in blocks { b.withUnsafeBufferPointer { r.process($0, from: from, to: to, into: &out) } }
        return out
    }

    func testResamplerKeepsTheRate() {
        let block = [Float](repeating: 0.5, count: 441)
        let out = resample(Array(repeating: block, count: 100), from: 44_100, to: 48_000)
        XCTAssertEqual(Double(out.count), 48_000, accuracy: 2, "one second in, one second out")
        XCTAssertTrue(out.allSatisfy { abs($0 - 0.5) < 1e-6 }, "a constant stays constant across block edges")
    }

    func testResamplerIsContinuousAcrossBlocks() {
        // A ramp cut into odd blocks comes out as a ramp: no jump at a seam.
        let ramp = (0..<1600).map { Float($0) / 1600 }
        let blocks = stride(from: 0, to: 1600, by: 160).map { Array(ramp[$0..<min($0 + 160, 1600)]) }
        let out = resample(blocks, from: 16_000, to: 48_000)
        for i in 1..<out.count { XCTAssertGreaterThanOrEqual(out[i], out[i - 1] - 1e-6) }
        XCTAssertEqual(Double(out.count), 4800, accuracy: 3)
    }

    // MARK: - Install script

    func testShellAndAppleScriptQuoting() {
        XCTAssertEqual(VirtualMicrophone.shellQuoted("/Applications/My App's.app"), "'/Applications/My App'\\''s.app'")
        XCTAssertEqual(VirtualMicrophone.appleScriptEscaped("a \"b\" \\c"), "a \\\"b\\\" \\\\c")
    }
}
