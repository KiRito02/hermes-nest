import Foundation

/// Process-lifetime connection pools for the App-only Companion transport.
///
/// Short JSON and file requests share one bounded pool. Run event streams use
/// a separate bounded pool so long-lived SSE requests cannot block stop,
/// approval, history, or attachment operations, while a run kept alive across
/// navigation does not prevent a second session from opening its own stream.
final class CompanionSessionPool: @unchecked Sendable {
    static let shared = CompanionSessionPool()
    static let maximumConcurrentEventStreams = 4

    let requestSession: URLSession
    let eventSession: URLSession

    private init() {
        let redirectBlocker = CompanionRedirectBlocker()
        requestSession = Self.makeSession(
            maximumConnectionsPerHost: 2,
            supportsLongLivedRequests: false,
            redirectBlocker: redirectBlocker
        )
        eventSession = Self.makeSession(
            maximumConnectionsPerHost: Self.maximumConcurrentEventStreams,
            supportsLongLivedRequests: true,
            redirectBlocker: redirectBlocker
        )
    }

    private static func makeSession(
        maximumConnectionsPerHost: Int,
        supportsLongLivedRequests: Bool,
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
        if supportsLongLivedRequests {
            configuration.timeoutIntervalForRequest =
                .greatestFiniteMagnitude
            configuration.timeoutIntervalForResource =
                .greatestFiniteMagnitude
        }
        return URLSession(
            configuration: configuration,
            delegate: redirectBlocker,
            delegateQueue: nil
        )
    }
}
