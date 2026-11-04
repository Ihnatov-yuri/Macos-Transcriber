import XCTest
@testable import Transcriberr

/// Pure-logic checks for the security sweep's fixes.
final class SecuritySweepTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
    }

    override func tearDown() async throws {
        try await super.tearDown()
    }

    // MARK: - Links in model-written Markdown

    func testWebLinksInOutputsOpen() throws {
        XCTAssertTrue(SafeLink.isOpenable(try XCTUnwrap(URL(string: "https://example.com/a?b=c"))))
        XCTAssertTrue(SafeLink.isOpenable(try XCTUnwrap(URL(string: "http://example.com"))))
        XCTAssertTrue(SafeLink.isOpenable(try XCTUnwrap(URL(string: "HTTPS://Example.com"))))
        XCTAssertTrue(SafeLink.isOpenable(try XCTUnwrap(URL(string: "mailto:someone@example.com"))))
    }

    func testOtherSchemesInOutputsAreInert() throws {
        for s in ["file:///Applications/Calculator.app", "file:///etc/passwd",
                  "transcriberr://dictate/start", "x-apple.systempreferences:com.apple.preference.security",
                  "javascript:alert(1)", "vnc://10.0.0.1", "smb://server/share", "ssh://host",
                  "https:relative", "http:///etc/hosts", "data:text/html,hi"] {
            let url = try XCTUnwrap(URL(string: s), s)
            XCTAssertFalse(SafeLink.isOpenable(url), s)
        }
    }

    // MARK: - Passwords and cloud engines

    func testPasswordFieldNeverGoesToACloudEngine() {
        var secure = DictationContext()
        secure.isSecure = true
        let normal = DictationContext()
        for cloud in [BackendFactory.Kind.openAI, .gemini, .anthropic] {
            XCTAssertTrue(DictationController.mustRefuseSecure(secure, engine: cloud), cloud.rawValue)
            XCTAssertFalse(DictationController.mustRefuseSecure(normal, engine: cloud), cloud.rawValue)
        }
        for local in [BackendFactory.Kind.parakeet, .parakeetV2, .parakeetUK, .whisper] {
            XCTAssertFalse(DictationController.mustRefuseSecure(secure, engine: local), local.rawValue)
        }
    }

    // MARK: - Cloud HTTP session

    func testCloudSessionKeepsNothingOnDisk() {
        let cfg = CloudHTTP.session.configuration
        XCTAssertNil(cfg.urlCache)
        XCTAssertNil(cfg.httpCookieStorage)
        XCTAssertNil(cfg.urlCredentialStorage)
        XCTAssertFalse(cfg.httpShouldSetCookies)
        XCTAssertEqual(cfg.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(cfg.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    // MARK: - Model download size cap

    func testPinnedModelDownloadCapIsItsSizePlusSlack() {
        let size: Int64 = 2_588_147_712
        let cap = ModelDownloader.downloadCap(sizeBytes: size, pinned: true)
        XCTAssertEqual(cap, size + size / 20)
        XCTAssertLessThan(cap, size * 2)
        // Small files still get a megabyte of slack.
        XCTAssertEqual(ModelDownloader.downloadCap(sizeBytes: 1_000, pinned: true), 1_000 + (1 << 20))
    }

    func testUnpinnedModelDownloadCapIsTwiceWithAFloor() {
        XCTAssertEqual(ModelDownloader.downloadCap(sizeBytes: 1_000_000_000, pinned: false), 2_000_000_000)
        XCTAssertEqual(ModelDownloader.downloadCap(sizeBytes: 10, pinned: false), 64 << 20)
        XCTAssertEqual(ModelDownloader.downloadCap(sizeBytes: 0, pinned: true), 64 << 20)
        XCTAssertEqual(ModelDownloader.downloadCap(sizeBytes: -5, pinned: false), 64 << 20)
        XCTAssertEqual(ModelDownloader.downloadCap(sizeBytes: Int64.max - 1, pinned: false), Int64.max)
        XCTAssertEqual(ModelDownloader.downloadCap(sizeBytes: Int64.max - 1, pinned: true), Int64.max)
    }

    // MARK: - Hugging Face release listing

    private let rev = String(repeating: "9e3b5cdc", count: 5)

    private func parakeetTree(extra: [[String: Any]] = []) -> [[String: Any]] {
        var paths = ["config.json", "parakeet_vocab.json", "parakeet_v3_vocab.json"]
        for part in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            paths += ["weights/weight.bin", "model.mil", "coremldata.bin", "metadata.json"].map { "\(part).mlmodelc/\($0)" }
        }
        var entries: [[String: Any]] = []
        for p in paths {
            var e: [String: Any] = ["type": "file", "path": "coreml/int8/parakeet-tdt-0.6b-v3/\(p)", "size": 100,
                                    "oid": String(repeating: "a", count: 40)]
            if p.hasSuffix(".bin") { e["lfs"] = ["oid": String(repeating: "b", count: 64), "size": 100] }
            entries.append(e)
        }
        return entries + extra
    }

    func testReleaseWithANegativeFileSizeIsRefused() throws {
        XCTAssertNoThrow(try ParakeetUKModel.validate(ParakeetUKModel.manifest(revision: rev, tree: parakeetTree())))
        // -3 GB on one entry offset a 3 GB one: the total passed the cap.
        let negative: [String: Any] = ["type": "file", "path": "coreml/int8/parakeet-tdt-0.6b-v3/neg.bin",
                                       "size": -3_000_000_000, "oid": "x",
                                       "lfs": ["oid": String(repeating: "c", count: 64)]]
        let huge: [String: Any] = ["type": "file", "path": "coreml/int8/parakeet-tdt-0.6b-v3/huge.bin",
                                   "size": 3_000_000_000, "oid": "x",
                                   "lfs": ["oid": String(repeating: "d", count: 64)]]
        let m = try ParakeetUKModel.manifest(revision: rev, tree: parakeetTree(extra: [negative, huge]))
        XCTAssertThrowsError(try ParakeetUKModel.validate(m))
    }

    /// restore-backups only restores audio inside the library folder.
    func testBackupAudioMustBeInsideTheLibrary() {
        let lib = URL(fileURLWithPath: "/Users/x/Documents/Transcriberr/Recordings", isDirectory: true)
        XCTAssertTrue(BackupService.isInsideLibrary(lib.path + "/meeting_1.m4a", library: lib))
        XCTAssertFalse(BackupService.isInsideLibrary(lib.path + "/../../Secret.wav", library: lib))
        XCTAssertFalse(BackupService.isInsideLibrary("/Users/x/Music/song.wav", library: lib))
        XCTAssertFalse(BackupService.isInsideLibrary(lib.path + "-evil/a.wav", library: lib))
        XCTAssertFalse(BackupService.isInsideLibrary("", library: lib))
    }

    /// A self-signed build pins the driver to its own leaf certificate.
    func testDriverRequirementPinsTheLeafWithoutATeam() {
        let sha = String(repeating: "ab", count: 20)
        XCTAssertEqual(VirtualMicrophone.driverRequirement(team: nil, leaf: sha),
                       "certificate leaf = H\"\(sha)\" and identifier \"nl.ihnatov.Transcriberr.MicDriver\"")
        XCTAssertEqual(VirtualMicrophone.driverRequirement(team: nil, leaf: "not-a-hash"),
                       "identifier \"nl.ihnatov.Transcriberr.MicDriver\"")
        XCTAssertTrue(VirtualMicrophone.driverRequirement(team: "AB12CD34EF", leaf: sha).hasPrefix("anchor apple generic"))
    }
}
