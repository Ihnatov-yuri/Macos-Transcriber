import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// Ed25519 check of a release zip. The private half of this key lives only
/// in the release Mac's Keychain (scripts/update-keygen.sh); every release
/// zip ships with a .sig made by scripts/sign-update.sh. An update whose
/// signature doesn't verify is never installed, so a hijacked GitHub
/// account alone can't push code to installed copies.
enum UpdateSignature {
    static let publicKey = "dCmBomtsUrKJDHkENGKgsnPkPQ5qixHN/815oU8z6Sc="

    /// Binds the version to the zip, so a genuine older zip can't be
    /// replayed under a newer version. Same text as scripts/update-signing.swift.
    static func message(version: String, sha256Hex: String) -> Data {
        Data("Transcriberr update\n\(version)\n\(sha256Hex)\n".utf8)
    }

    static func isValid(signature: Data, version: String, sha256Hex: String,
                        publicKey: String = publicKey) -> Bool {
        guard let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: message(version: version, sha256Hex: sha256Hex))
    }

    static func sha256Hex(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One-button update: download the release zip and its signature, verify
/// both, unpack, check the app inside is this app at the promised version
/// with an intact code signature, then quit and let a small helper swap the
/// bundle and relaunch. Library, settings and permission grants carry over
/// (the designated requirement is identifier-based, see scripts/package.sh).
///
/// The downloads use UpdateChecker's anonymous session and headers.
@Observable
final class UpdateInstaller: @unchecked Sendable {

    enum Phase: Equatable {
        case idle
        case downloading
        case verifying
        case relaunching
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .downloading, .verifying, .relaunching: return true
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .idle
    static let maxZipBytes = 1_000_000_000

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// `blocker` is asked again right before quitting: a recording started
    /// while the zip downloaded must not be cut off by the relaunch.
    func install(_ release: UpdateChecker.Release, currentVersion: String,
                 blocker: @escaping @MainActor @Sendable () -> String? = { nil }) async {
        // Check and claim in one main-actor hop, so a second press can't
        // slip in between and start a parallel install that wipes this
        // one's staging directory.
        let claimed = await MainActor.run { () -> Bool in
            if phase.isWorking { return false }
            phase = .downloading
            return true
        }
        guard claimed else { return }
        let stage: URL
        do {
            stage = try Self.makeStagingDirectory()
        } catch {
            await setPhase(.failed("Couldn't prepare the download"))
            return
        }
        do {
            guard release.installable else { throw Failure("This release can't be installed from the app") }
            guard UpdateChecker.isNewer(release.version, than: currentVersion) else { throw Failure("Already up to date") }
            let target = Bundle.main.bundleURL
            try Self.checkCanReplace(target)

            let sig = try await Self.fetchSignature(release.signatureURL)
            let zip = try await Self.download(release.zipURL, into: stage)

            await setPhase(.verifying)
            guard UpdateSignature.isValid(signature: sig, version: release.version,
                                          sha256Hex: try UpdateSignature.sha256Hex(of: zip)) else {
                throw Failure("The download failed its signature check")
            }
            let app = try Self.unpack(zip, into: stage)
            try Self.checkBundle(app, version: release.version)
            try? FileManager.default.removeItem(at: zip)
            if let why = await MainActor.run(body: blocker) { throw Failure(why) }

            await setPhase(.relaunching)
            AppLog.info("update", "installing \(release.version) over \(currentVersion)")
            try Self.launchSwapHelper(newApp: app, target: target, stage: stage)
            await MainActor.run { NSApp.terminate(nil) }
        } catch {
            try? FileManager.default.removeItem(at: stage)
            let text = (error as? Failure)?.message ?? "The update couldn't be downloaded"
            AppLog.info("update", "install failed: \(error.localizedDescription)")
            await setPhase(.failed(text))
        }
    }

    private func setPhase(_ p: Phase) async {
        await MainActor.run { phase = p }
    }

    // MARK: - Steps

    private static func makeStagingDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Transcriberr", isDirectory: true)
            .appendingPathComponent("Update", isDirectory: true)
        // Leftovers from an earlier attempt.
        try? FileManager.default.removeItem(at: base)
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The running bundle has to be a real .app in a folder we can write to.
    /// A copy run straight from a download is translocated to a read-only
    /// path and fails here.
    static func checkCanReplace(_ target: URL) throws {
        guard target.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              !target.path.contains("/AppTranslocation/")
        else { throw Failure("Move Transcriberr to Applications to update it from here") }
    }

    private static func fetchSignature(_ url: URL) async throws -> Data {
        let (data, response) = try await UpdateChecker.session.data(for: UpdateChecker.request(for: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1024,
              let sig = Data(base64Encoded: String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)),
              sig.count == 64
        else { throw Failure("The release has no valid signature") }
        return sig
    }

    private static func download(_ url: URL, into stage: URL) async throws -> URL {
        let (tmp, response) = try await UpdateChecker.session.download(for: UpdateChecker.request(for: url, timeout: 60))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("The download failed") }
        let dest = stage.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tmp, to: dest)
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size < maxZipBytes else { throw Failure("The download has the wrong size") }
        return dest
    }

    private static func unpack(_ zip: URL, into stage: URL) throws -> URL {
        let out = stage.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let items = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        guard p.terminationStatus == 0, items == ["Transcriberr.app"] else {
            throw Failure("The download isn't a Transcriberr app")
        }
        return out.appendingPathComponent("Transcriberr.app", isDirectory: true)
    }

    /// Same bundle identifier, the promised version, and a code signature
    /// that is intact and satisfies this app's own identifier requirement.
    static func checkBundle(_ app: URL, version: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let id = info["CFBundleIdentifier"] as? String, id == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version
        else { throw Failure("The download isn't the expected version") }

        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("identifier \"\(id)\"" as CFString, [], &requirement) == errSecSuccess
        else { throw Failure("The download's code signature can't be read") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure("The download's code signature is broken")
        }
    }

    /// A shell helper that outlives the app: waits for this process to exit,
    /// moves the old bundle aside, moves the new one in (putting the old one
    /// back if that fails), relaunches, and cleans up.
    private static func launchSwapHelper(newApp: URL, target: URL, stage: URL) throws {
        let script = stage.appendingPathComponent("swap.sh")
        try Self.swapScript.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                       newApp.path, target.path, stage.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    static let swapScript = """
        #!/bin/sh
        PID="$1"; NEW="$2"; TARGET="$3"; STAGE="$4"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2; i=$((i+1))
          [ "$i" -gt 600 ] && exit 1
        done
        if mv "$TARGET" "$STAGE/previous.app"; then
          if mv "$NEW" "$TARGET"; then
            rm -rf "$STAGE/previous.app"
          else
            mv "$STAGE/previous.app" "$TARGET"
          fi
        fi
        /usr/bin/open "$TARGET"
        rm -rf "$STAGE"
        """
}
