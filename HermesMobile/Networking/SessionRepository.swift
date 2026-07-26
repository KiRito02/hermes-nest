import Foundation

struct SessionListQuery: Equatable, Sendable {
    let limit: Int?
    let offset: Int?
    let source: String?
    let includeChildren: Bool?

    init(
        limit: Int? = 50,
        offset: Int? = 0,
        source: String? = nil,
        includeChildren: Bool? = false
    ) {
        self.limit = limit
        self.offset = offset
        self.source = source
        self.includeChildren = includeChildren
    }
}

struct SessionPage: Equatable, Sendable {
    let sessions: [SessionSummary]
    let limit: Int?
    let offset: Int?
    let hasMore: Bool?
}

protocol SessionRepository: Sendable {
    func listSessions(_ query: SessionListQuery) async throws -> SessionPage
}

enum SessionRepositoryError: LocalizedError, Equatable {
    case missingDeviceCredential
    case invalidDeviceCredential
    case deviceRevoked
    case companionUnreachable
    case invalidQuery
    case gatewayUnauthorized
    case gatewayUnavailable
    case gatewayIncompatible
    case gatewayMalformedResponse
    case gatewayResponseTooLarge
    case gatewayTimeout
    case gatewayTransportFailure
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .missingDeviceCredential, .invalidDeviceCredential:
            return String(localized: "This device must pair with Companion again.")
        case .deviceRevoked:
            return String(localized: "This device was revoked and must pair with Companion again.")
        case .companionUnreachable:
            return String(localized: "Hermex Companion is unreachable.")
        case .invalidQuery:
            return String(localized: "The session list request is invalid.")
        case .gatewayUnauthorized:
            return String(localized: "Companion's NAS-local Gateway credential was rejected.")
        case .gatewayUnavailable:
            return String(localized: "Hermes Gateway is temporarily unavailable.")
        case .gatewayIncompatible:
            return String(localized: "This Hermes Gateway session API is incompatible.")
        case .gatewayMalformedResponse:
            return String(localized: "Hermes Gateway returned a malformed session list.")
        case .gatewayResponseTooLarge:
            return String(localized: "The session list exceeded Companion's response limit.")
        case .gatewayTimeout:
            return String(localized: "Hermes Gateway took too long to return sessions.")
        case .gatewayTransportFailure:
            return String(localized: "Companion could not reach Hermes Gateway.")
        case .unexpectedResponse:
            return String(localized: "Companion returned an unexpected session response.")
        }
    }
}

actor LiveSessionRepository: SessionRepository {
    private static let maximumResponseBytes = 2 * 1024 * 1024

    private let companionURL: URL
    private let keychain: any KeychainStoring
    private let session: URLSession
    private let decoder: JSONDecoder

    init(
        companionURL: URL,
        keychain: any KeychainStoring = KeychainStore(),
        session: URLSession? = nil
    ) {
        self.companionURL = companionURL
        self.keychain = keychain
        self.session = session ?? Self.makeSession()

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func listSessions(_ query: SessionListQuery) async throws -> SessionPage {
        let url = try sessionListURL(query)
        guard
            let credential = try? keychain.load(.companionDeviceCredential),
            !credential.isEmpty
        else {
            throw SessionRepositoryError.missingDeviceCredential
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SessionRepositoryError.companionUnreachable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SessionRepositoryError.unexpectedResponse
        }
        guard httpResponse.mimeType == "application/json" else {
            throw SessionRepositoryError.unexpectedResponse
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw SessionRepositoryError.gatewayResponseTooLarge
        }
        guard httpResponse.statusCode == 200 else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
        }

        let payload: GatewaySessionListPayload
        do {
            payload = try decoder.decode(GatewaySessionListPayload.self, from: data)
        } catch {
            throw SessionRepositoryError.unexpectedResponse
        }
        guard
            payload.object == "list",
            let rows = payload.data,
            let limit = payload.limit,
            let offset = payload.offset,
            let hasMore = payload.hasMore
        else {
            throw SessionRepositoryError.unexpectedResponse
        }

        return SessionPage(
            sessions: rows.compactMap(\.sessionSummary),
            limit: limit,
            offset: offset,
            hasMore: hasMore
        )
    }

    private func sessionListURL(_ query: SessionListQuery) throws -> URL {
        if let limit = query.limit, !(0...200).contains(limit) {
            throw SessionRepositoryError.invalidQuery
        }
        if let offset = query.offset, !(0...1_000_000).contains(offset) {
            throw SessionRepositoryError.invalidQuery
        }
        if let source = query.source,
           source.count > 128 || source.unicodeScalars.contains(where: {
               CharacterSet.controlCharacters.contains($0)
           }) {
            throw SessionRepositoryError.invalidQuery
        }

        let endpoint = companionURL
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: false)
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw SessionRepositoryError.invalidQuery
        }

        var items: [URLQueryItem] = []
        if let limit = query.limit {
            items.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let offset = query.offset {
            items.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        if let source = query.source {
            items.append(URLQueryItem(name: "source", value: source))
        }
        if let includeChildren = query.includeChildren {
            items.append(
                URLQueryItem(
                    name: "include_children",
                    value: includeChildren ? "true" : "false"
                )
            )
        }
        components.queryItems = items.isEmpty ? nil : items

        guard let url = components.url else {
            throw SessionRepositoryError.invalidQuery
        }
        return url
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> SessionRepositoryError {
        let code = (
            try? decoder.decode(CompanionSessionErrorEnvelope.self, from: data)
        )?.error?.code
        switch (statusCode, code) {
        case (401, "device_credential_invalid"):
            return .invalidDeviceCredential
        case (403, "device_revoked"):
            return .deviceRevoked
        case (400, "invalid_query"):
            return .invalidQuery
        case (502, "gateway_unauthorized"):
            return .gatewayUnauthorized
        case (503, "gateway_unavailable"):
            return .gatewayUnavailable
        case (502, "gateway_incompatible"):
            return .gatewayIncompatible
        case (502, "gateway_malformed_response"):
            return .gatewayMalformedResponse
        case (502, "gateway_response_too_large"):
            return .gatewayResponseTooLarge
        case (504, "gateway_timeout"):
            return .gatewayTimeout
        case (503, "gateway_transport_failure"):
            return .gatewayTransportFailure
        default:
            return .unexpectedResponse
        }
    }

    private nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: CompanionRedirectBlocker(),
            delegateQueue: nil
        )
    }
}

private struct GatewaySessionListPayload: Decodable {
    let object: String?
    let data: [GatewaySessionPayload]?
    let limit: Int?
    let offset: Int?
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case object
        case data
        case limit
        case offset
        case hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try? container.decodeIfPresent(String.self, forKey: .object)
        data = try? container.decodeIfPresent(
            [GatewaySessionPayload].self,
            forKey: .data
        )
        limit = try? container.decodeIfPresent(Int.self, forKey: .limit)
        offset = try? container.decodeIfPresent(Int.self, forKey: .offset)
        hasMore = try? container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }
}

private struct GatewaySessionPayload: Decodable {
    let id: String?
    let source: String?
    let model: String?
    let title: String?
    let startedAt: Double?
    let messageCount: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let estimatedCostUsd: Double?
    let parentSessionId: String?
    let lastActive: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case model
        case title
        case startedAt
        case messageCount
        case inputTokens
        case outputTokens
        case estimatedCostUsd
        case parentSessionId
        case lastActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyStringIfPresent(forKey: .id)
        source = container.decodeLossyStringIfPresent(forKey: .source)
        model = container.decodeLossyStringIfPresent(forKey: .model)
        title = container.decodeLossyStringIfPresent(forKey: .title)
        startedAt = container.decodeLossyDoubleIfPresent(forKey: .startedAt)
        messageCount = container.decodeLossyIntIfPresent(forKey: .messageCount)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens)
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens)
        estimatedCostUsd = container.decodeLossyDoubleIfPresent(
            forKey: .estimatedCostUsd
        )
        parentSessionId = container.decodeLossyStringIfPresent(
            forKey: .parentSessionId
        )
        lastActive = container.decodeLossyDoubleIfPresent(forKey: .lastActive)
    }

    var sessionSummary: SessionSummary? {
        guard let id = Self.nonEmpty(id) else { return nil }
        let source = Self.nonEmpty(source)
        return SessionSummary(
            sessionId: id,
            title: Self.nonEmpty(title),
            model: Self.nonEmpty(model),
            messageCount: messageCount,
            createdAt: startedAt,
            updatedAt: lastActive,
            lastMessageAt: lastActive,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: estimatedCostUsd,
            isCliSession: source == "cli",
            rawSource: source,
            sessionSource: source,
            parentSessionId: Self.nonEmpty(parentSessionId),
            readOnly: true,
            isReadOnly: true
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CompanionSessionErrorEnvelope: Decodable {
    let error: CompanionSessionErrorBody?
}

private struct CompanionSessionErrorBody: Decodable {
    let code: String?
    let message: String?
}
