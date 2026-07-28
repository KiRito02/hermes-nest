import Foundation

/// Process-lifetime connection pools for the App-only Companion transport.
///
/// Short JSON and file requests share one bounded pool. Run event streams use
/// a separate single-connection pool so a long-lived SSE request cannot block
/// stop, approval, history, or attachment operations.
final class CompanionSessionPool: @unchecked Sendable {
    static let shared = CompanionSessionPool()

    let requestSession: URLSession
    let eventSession: URLSession

    private init() {
        let redirectBlocker = CompanionRedirectBlocker()
        requestSession = Self.makeSession(
            maximumConnectionsPerHost: 2,
            redirectBlocker: redirectBlocker
        )
        eventSession = Self.makeSession(
            maximumConnectionsPerHost: 1,
            redirectBlocker: redirectBlocker
        )
    }

    private static func makeSession(
        maximumConnectionsPerHost: Int,
        redirectBlocker: CompanionRedirectBlocker
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost =
            maximumConnectionsPerHost
        return URLSession(
            configuration: configuration,
            delegate: redirectBlocker,
            delegateQueue: nil
        )
    }
}
