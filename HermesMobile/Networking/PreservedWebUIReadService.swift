import Foundation

/// The narrow read-only dependency retained by the out-of-process App Intent
/// profile picker and the disabled-for-personal-v1 Live Activity reconciler.
/// It is intentionally not a Companion client and must not grow new routes.
actor PreservedWebUIReadService {
    private let baseURL: URL
    private let session: URLSession
    private let ownedSession: URLSession?
    private let decoder: JSONDecoder
    private let customHeaderProvider: @Sendable () -> [CustomHeader]

    init(
        baseURL: URL,
        session: URLSession? = nil,
        customHeaderProvider: @escaping @Sendable () -> [CustomHeader] = {
            CustomHeaderStore.shared.snapshot()
        }
    ) {
        self.baseURL = baseURL
        self.customHeaderProvider = customHeaderProvider

        if let session {
            self.session = session
            ownedSession = nil
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpCookieStorage = .shared
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
            let delegate = PreservedWebUIRedirectGuard(
                baseURL: baseURL,
                customHeaderProvider: customHeaderProvider
            )
            let created = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            self.session = created
            ownedSession = created
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    deinit {
        ownedSession?.finishTasksAndInvalidate()
    }

    func profiles() async throws -> ProfilesResponse {
        try await get(path: "/api/profiles")
    }

    func chatStreamStatus(streamID: String) async throws -> ChatStreamStatusResponse {
        try await get(
            path: "/api/chat/stream/status",
            queryItems: [URLQueryItem(name: "stream_id", value: streamID)]
        )
    }

    private func get<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        var url = baseURL.appending(path: path)
        if !queryItems.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            url = components.url ?? url
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        customHeaderProvider().apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PreservedWebUIReadError.network(error)
        }

        guard let response = response as? HTTPURLResponse else {
            throw PreservedWebUIReadError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw PreservedWebUIReadError.http(response.statusCode)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw PreservedWebUIReadError.decoding(error)
        }
    }
}

private enum PreservedWebUIReadError: Error {
    case network(Error)
    case invalidResponse
    case http(Int)
    case decoding(Error)
}

/// Prevents the two preserved requests from forwarding owner-configured
/// headers when a same-origin server redirects to another origin.
private final class PreservedWebUIRedirectGuard:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let baseURL: URL
    private let customHeaderProvider: @Sendable () -> [CustomHeader]

    init(
        baseURL: URL,
        customHeaderProvider: @escaping @Sendable () -> [CustomHeader]
    ) {
        self.baseURL = baseURL
        self.customHeaderProvider = customHeaderProvider
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              !Self.isSameOrigin(destination, as: baseURL) else {
            completionHandler(request)
            return
        }

        let namesToStrip = Set(
            customHeaderProvider()
                .filter(\.isApplicable)
                .map { $0.sanitizedName.lowercased() }
        )
        guard !namesToStrip.isEmpty,
              let fields = request.allHTTPHeaderFields else {
            completionHandler(request)
            return
        }

        var stripped = request
        for name in fields.keys where namesToStrip.contains(name.lowercased()) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        completionHandler(stripped)
    }

    private static func isSameOrigin(_ url: URL, as baseURL: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let baseScheme = baseURL.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let baseHost = baseURL.host?.lowercased() else {
            return false
        }

        return scheme == baseScheme
            && host == baseHost
            && normalizedPort(for: url) == normalizedPort(for: baseURL)
    }

    private static func normalizedPort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

struct ProfilesResponse: Decodable, Equatable {
    let profiles: [ProfileSummary]?
    let active: String?
    let singleProfileMode: Bool?
}

struct ProfileSummary: Decodable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { name ?? path ?? UUID().uuidString }

    let name: String?
    let path: String?
    let isDefault: Bool?
    let isActive: Bool?
    let gatewayRunning: Bool?
    let model: String?
    let provider: String?
    let hasEnv: Bool?
    let skillCount: Int?

    var displayName: String {
        guard let name, !name.isEmpty else {
            return String(localized: "Profile")
        }
        return name == "default" ? String(localized: "Default") : name
    }

    var normalizedName: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ChatStreamStatusResponse: Decodable, Equatable {
    let active: Bool?
    let streamId: String?
    let replayAvailable: Bool?
    let journal: RunJournalStatus?
}

struct RunJournalStatus: Decodable, Equatable {
    let terminal: Bool?
    let terminalState: String?
}
