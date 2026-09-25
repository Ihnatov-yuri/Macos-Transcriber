import XCTest
@testable import Transcriberr

/// The update check must stay anonymous and must only ever point at this
/// repository's release page.
final class UpdateCheckerTests: XCTestCase {

    func testVersionOrdering() {
        XCTAssertTrue(UpdateChecker.isNewer("3.13.2", than: "3.13.1"))
        XCTAssertTrue(UpdateChecker.isNewer("3.14", than: "3.13.9"))
        XCTAssertTrue(UpdateChecker.isNewer("4.0.0", than: "3.99.99"))
        XCTAssertTrue(UpdateChecker.isNewer("3.10.0", than: "3.9.0"))   // numeric, not lexical
        XCTAssertFalse(UpdateChecker.isNewer("3.13.1", than: "3.13.1"))
        XCTAssertFalse(UpdateChecker.isNewer("3.13", than: "3.13.0"))
        XCTAssertFalse(UpdateChecker.isNewer("3.12.9", than: "3.13.0"))
    }

    func testTagNormalisation() {
        XCTAssertEqual(UpdateChecker.normalizedVersion("v3.13.1"), "3.13.1")
        XCTAssertEqual(UpdateChecker.normalizedVersion("3.14"), "3.14")
        XCTAssertNil(UpdateChecker.normalizedVersion("v3.14.0-beta"))
        XCTAssertNil(UpdateChecker.normalizedVersion("v3..1"))
        XCTAssertNil(UpdateChecker.normalizedVersion("../../evil"))
        XCTAssertNil(UpdateChecker.normalizedVersion("v٣.1"))            // non-ASCII digits
    }

    func testParseBuildsLinkFromTagOnly() throws {
        let json = #"{"tag_name":"v3.14.0","name":"v3.14.0: faster","html_url":"https://evil.example/x","draft":false,"prerelease":false}"#
        let r = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8)))
        XCTAssertEqual(r.version, "3.14.0")
        XCTAssertEqual(r.title, "v3.14.0: faster")
        XCTAssertEqual(r.pageURL.absoluteString,
                       "https://github.com/Ihnatov-yuri/Macos-Transcriber/releases/tag/v3.14.0")
    }

    func testParseRejectsPrereleaseAndJunk() {
        XCTAssertNil(UpdateChecker.parse(Data(#"{"tag_name":"v9.0.0","prerelease":true}"#.utf8)))
        XCTAssertNil(UpdateChecker.parse(Data(#"{"tag_name":"latest"}"#.utf8)))
        XCTAssertNil(UpdateChecker.parse(Data("not json".utf8)))
    }

    private func freshDefaults() -> UserDefaults {
        let name = "UpdateCheckerTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    /// Opt-in: nothing is checked until the user says yes.
    func testOffUntilAnswered() {
        let d = freshDefaults()
        let u = UpdateChecker(currentVersion: "3.13.1", defaults: d, askOnLaunch: true)
        XCTAssertFalse(u.autoCheck)
        XCTAssertTrue(u.needsConsent)

        u.answerConsent(false)
        XCTAssertFalse(u.autoCheck)
        XCTAssertFalse(u.needsConsent)
        // Asked once: the next launch doesn't ask again.
        XCTAssertFalse(UpdateChecker(currentVersion: "3.13.1", defaults: d, askOnLaunch: true).needsConsent)
    }

    func testSettingsSwitchCountsAsAnAnswer() {
        let d = freshDefaults()
        let u = UpdateChecker(currentVersion: "3.13.1", defaults: d, askOnLaunch: true)
        u.autoCheck = true
        XCTAssertFalse(u.needsConsent)
        let next = UpdateChecker(currentVersion: "3.13.1", defaults: d, askOnLaunch: true)
        XCTAssertTrue(next.autoCheck)
        XCTAssertFalse(next.needsConsent)
    }

    /// Same bytes from every Mac: no version, locale, identifier or query.
    func testRequestCarriesNothingAboutTheUser() {
        let req = UpdateChecker.request
        XCTAssertEqual(req.url?.absoluteString,
                       "https://api.github.com/repos/Ihnatov-yuri/Macos-Transcriber/releases/latest")
        XCTAssertNil(req.url?.query)
        XCTAssertFalse(req.httpShouldHandleCookies)
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "Transcriberr")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept-Language"), "en")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3."
        for (_, value) in req.allHTTPHeaderFields ?? [:] {
            XCTAssertFalse(value.contains(version))
        }
    }
}

/// Ship gate: every release carries its notes into the About panel.
final class ReleaseNotesTests: XCTestCase {

    func testCurrentVersionHasReleaseNotes() throws {
        let version = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        let text = try XCTUnwrap(ReleaseNotes.bundled(), "ReleaseNotes.md is missing from the app bundle")
        XCTAssertFalse(ReleaseNotes.entries(for: version, in: text).isEmpty,
                       "Add a \"## \(version)\" section to Transcriberr/Resources/ReleaseNotes.md before shipping")
    }

    func testParserReadsOnlyItsOwnSection() {
        let text = """
        # header
        ## 3.14.0
        - First line
          wrapped on.
        - Second

        ## 3.13.1
        - Older
        """
        XCTAssertEqual(ReleaseNotes.entries(for: "3.14.0", in: text), ["First line wrapped on.", "Second"])
        XCTAssertEqual(ReleaseNotes.entries(for: "3.13.1", in: text), ["Older"])
        XCTAssertEqual(ReleaseNotes.entries(for: "3.13", in: text), [])
    }
}

/// The install path trusts nothing it can't verify.
final class UpdateInstallerTests: XCTestCase {

    // Made by scripts/update-signing.swift with a throwaway key, so these
    // also prove the release script and the app sign the same message.
    private let testPublicKey = "37DPQPVEqH1petShIWgN52rSlp+ExRwFrmUO1pg4nfc="
    private let payload = Data("Transcriberr test payload\n".utf8)
    private let payloadSHA = "7fdc1d0af4def78ba9c1285966f005c469550890bcb29528c13b62c56a851c13"
    private let signature = Data(base64Encoded: "S1n98cfYmMK9jwnUfeegp4OfCsIvIVGo02ShNp2OdI/dC30cl5qx20ngpZr56NubsJBAaXI2bCW51aC5Pml1CA==")!

    func testScriptSignatureVerifies() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try UpdateSignature.sha256Hex(of: file), payloadSHA)
        XCTAssertTrue(UpdateSignature.isValid(signature: signature, version: "9.9.9",
                                              sha256Hex: payloadSHA, publicKey: testPublicKey))
    }

    func testSignatureRejectsAnyChange() {
        // Another version (replaying a genuine zip as a newer one).
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, version: "9.9.10",
                                               sha256Hex: payloadSHA, publicKey: testPublicKey))
        // Other bytes.
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, version: "9.9.9",
                                               sha256Hex: String(payloadSHA.reversed()), publicKey: testPublicKey))
        // The real release key didn't make it.
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, version: "9.9.9", sha256Hex: payloadSHA))
        // A tampered signature.
        var bad = signature
        bad[0] ^= 1
        XCTAssertFalse(UpdateSignature.isValid(signature: bad, version: "9.9.9",
                                               sha256Hex: payloadSHA, publicKey: testPublicKey))
    }

    func testReleaseKeyIsWellFormed() throws {
        let raw = try XCTUnwrap(Data(base64Encoded: UpdateSignature.publicKey))
        XCTAssertEqual(raw.count, 32)
    }

    func testInstallableNeedsZipAndSignature() throws {
        let both = #"{"tag_name":"v3.14.3","assets":[{"name":"Transcriberr-v3.14.3-macOS-arm64.zip"},{"name":"Transcriberr-v3.14.3-macOS-arm64.zip.sig"}]}"#
        let zipOnly = #"{"tag_name":"v3.14.3","assets":[{"name":"Transcriberr-v3.14.3-macOS-arm64.zip"}]}"#
        let r = try XCTUnwrap(UpdateChecker.parse(Data(both.utf8)))
        XCTAssertTrue(r.installable)
        XCTAssertEqual(r.zipURL.absoluteString,
                       "https://github.com/Ihnatov-yuri/Macos-Transcriber/releases/download/v3.14.3/Transcriberr-v3.14.3-macOS-arm64.zip")
        XCTAssertEqual(r.signatureURL.lastPathComponent, "Transcriberr-v3.14.3-macOS-arm64.zip.sig")
        XCTAssertFalse(try XCTUnwrap(UpdateChecker.parse(Data(zipOnly.utf8))).installable)
    }

    /// The bundle check accepts this very app at its own version and
    /// nothing else.
    func testBundleCheck() throws {
        let app = Bundle.main.bundleURL
        let version = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        XCTAssertNoThrow(try UpdateInstaller.checkBundle(app, version: version))
        XCTAssertThrowsError(try UpdateInstaller.checkBundle(app, version: version + ".1"))
        XCTAssertThrowsError(try UpdateInstaller.checkBundle(FileManager.default.temporaryDirectory, version: version))
    }

    func testRefusesToReplaceSomethingThatIsNotAnApp() {
        XCTAssertThrowsError(try UpdateInstaller.checkCanReplace(URL(fileURLWithPath: "/tmp/Transcriberr")))
        XCTAssertThrowsError(try UpdateInstaller.checkCanReplace(
            URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Transcriberr.app")))
    }
}
