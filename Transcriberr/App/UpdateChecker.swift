import Foundation
import Observation

/// Tells the user when a newer release is out, without telling anyone
/// anything about the user.
///
/// The whole exchange is one anonymous GET of the public "latest release"
/// record on GitHub. The request is byte-for-byte the same on every Mac:
/// no version, no identifier, no query string, no cookies, no cache, a
/// fixed User-Agent (the default one carries the app build, CFNetwork and
/// Darwin versions) and a fixed Accept-Language (the default one carries
/// the user's locale). The comparison with the running version happens
/// here, on the Mac, so the server cannot even tell whether this copy is
/// out of date. What it does see is the IP address, as with any request.
///
/// Off until the user says yes: the first launch asks once (AppShell), and
/// the switch in Settings → Updates changes the answer later.
///
/// Nothing is downloaded or installed. The notice links to the release
/// page and the user updates by hand, as before.
@Observable
final class UpdateChecker: @unchecked Sendable {

    struct Release: Equatable {
        let version: String
        let title: String
        let pageURL: URL
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    static let repo = "Ihnatov-yuri/Macos-Transcriber"
    static let endpoint = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    /// Automatic checks at most this often; a manual check ignores it.
    static let interval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private enum Key {
        static let autoCheck = "update.autoCheck"
        static let lastCheck = "update.lastCheck"
        static let skipped   = "update.skippedVersion"
        static let asked     = "update.consentAsked"
    }

    var autoCheck: Bool {
        didSet {
            defaults.set(autoCheck, forKey: Key.autoCheck)
            // Flipping the switch in Settings is an answer too.
            if needsConsent { needsConsent = false; defaults.set(true, forKey: Key.asked) }
        }
    }
    /// True until the user has answered the first-launch question.
    private(set) var needsConsent: Bool
    /// A release the user dismissed from the sidebar. A later one shows again.
    var skippedVersion: String? { didSet { defaults.set(skippedVersion, forKey: Key.skipped) } }
    private(set) var lastCheck: Date? { didSet { defaults.set(lastCheck, forKey: Key.lastCheck) } }
    private(set) var status: Status = .idle

    let currentVersion: String
    private var loop: Task<Void, Never>?

    init(currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
         defaults: UserDefaults = .standard,
         askOnLaunch: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        autoCheck = defaults.bool(forKey: Key.autoCheck)
        // Never ask inside the unit-test host.
        needsConsent = askOnLaunch && !defaults.bool(forKey: Key.asked)
        skippedVersion = defaults.string(forKey: Key.skipped)
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
    }

    /// The answer to the first-launch question. Yes checks straight away.
    func answerConsent(_ allow: Bool) {
        needsConsent = false
        defaults.set(true, forKey: Key.asked)
        autoCheck = allow
        if allow { Task { await check() } }
    }

    /// The release to show in the sidebar, if any.
    var pendingNotice: Release? {
        guard case .available(let r) = status, r.version != skippedVersion else { return nil }
        return r
    }

    /// Automatic checks: once shortly after launch, then re-evaluated every
    /// few hours for a Mac that stays up for days. Each wake only goes to
    /// the network when checks are on and the last one is a day old.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                guard let self else { return }
                if self.autoCheck, Date().timeIntervalSince(self.lastCheck ?? .distantPast) >= Self.interval {
                    await self.check()
                }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    @discardableResult
    func check() async -> Status {
        if await MainActor.run(body: { status == .checking }) { return .checking }
        await MainActor.run { status = .checking }
        let result: Status
        do {
            let (data, response) = try await Self.session.data(for: Self.request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            if let release = Self.parse(data), Self.isNewer(release.version, than: currentVersion) {
                result = .available(release)
            } else {
                result = .upToDate
            }
        } catch {
            result = .failed("Couldn't reach GitHub")
            AppLog.info("update", "check failed: \(error.localizedDescription)")
        }
        await MainActor.run {
            status = result
            if case .failed = result {} else { lastCheck = Date() }
        }
        return result
    }

    /// The first-launch question's text. Kept accurate: model downloads and
    /// the cloud engines (API keys) also reach the network, so the check is
    /// described as the one thing the app would share on its own.
    static let consentExplanation = """
        Your recordings and transcripts stay on this Mac. Apart from downloading its speech models, this check would be the only thing Transcriberr shares with the outside world on its own.

        Once a day it asks GitHub for the number of the newest release and compares it with the version on this Mac. The comparison happens here. The request is the same from every Mac and carries no version, account or identifier; GitHub sees your IP address, as it would for any web page.

        When a new version is out, a notice appears in the sidebar with a link to the release page. Nothing is downloaded or installed. You can change this later in Settings, Updates.
        """

    // MARK: - The request (kept identical for every user)

    static var request: URLRequest {
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        // GitHub rejects requests without a User-Agent; this one names the
        // app and nothing else.
        req.setValue("Transcriberr", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("en", forHTTPHeaderField: "Accept-Language")
        return req
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpAdditionalHeaders = [:]
        return URLSession(configuration: cfg)
    }()

    // MARK: - Parsing

    private struct Payload: Decodable {
        let tag_name: String
        let name: String?
        let draft: Bool?
        let prerelease: Bool?
    }

    /// Only the tag is trusted, and only when it looks like a version. The
    /// link is rebuilt from it rather than taken from the response, so the
    /// notice can only ever open this repository's release page.
    static func parse(_ data: Data) -> Release? {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              p.draft != true, p.prerelease != true,
              let version = normalizedVersion(p.tag_name),
              let url = URL(string: "https://github.com/\(repo)/releases/tag/v\(version)")
        else { return nil }
        let title = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Release(version: version, title: String(title.prefix(200)), pageURL: url)
    }

    /// "v3.13.1" → "3.13.1"; nil for anything that isn't 1–4 numeric parts.
    static func normalizedVersion(_ tag: String) -> String? {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return s
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
