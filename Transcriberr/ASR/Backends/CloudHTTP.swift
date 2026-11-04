import Foundation

/// The one session the cloud engines (OpenAI, Anthropic, Gemini) talk
/// through. `URLSession.shared` keeps an on-disk URL cache (Cache.db under
/// ~/Library/Caches) and a shared cookie jar: every request carries a whole
/// transcript, a meeting's audio or a dictated passage, and its answer is
/// the transcript or summary itself — none of that belongs in a cache file
/// that outlives the library entry, and no provider cookie should follow
/// the user from one request to the next. Ephemeral: nothing is written to
/// disk, no cookies, no stored credentials.
nonisolated enum CloudHTTP {
    static let session: URLSession = URLSession(configuration: configuration)

    static var configuration: URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return cfg
    }
}
