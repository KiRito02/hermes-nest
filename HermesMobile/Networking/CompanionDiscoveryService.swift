import Foundation
import Observation

struct CompanionSkill: Identifiable, Equatable, Sendable {
    let name: String
    let description: String?
    let category: String?

    var id: String { name }

    init(name: String, description: String?, category: String?) {
        self.name = name
        self.description = description
        self.category = category
    }
}

struct CompanionToolset: Identifiable, Equatable, Sendable {
    let name: String
    let label: String?
    let description: String?
    let enabled: Bool?
    let configured: Bool?
    let tools: [String]?

    var id: String { name }
    var displayName: String { label?.discoveryTrimmedNonEmpty ?? name }

    init(
        name: String,
        label: String?,
        description: String?,
        enabled: Bool?,
        configured: Bool?,
        tools: [String]?
    ) {
        self.name = name
        self.label = label
        self.description = description
        self.enabled = enabled
        self.configured = configured
        self.tools = tools
    }
}

struct CompanionDiscoveryCatalog: Equatable, Sendable {
    static let maximumRows = 2_048
    static let maximumTools = 512
    static let maximumNameLength = 256
    static let maximumLabelLength = 256
    static let maximumCategoryLength = 128
    static let maximumDescriptionLength = 4_096
    static let maximumToolNameLength = 256

    let skills: [CompanionSkill]
    let toolsets: [CompanionToolset]

    init(
        skills: [CompanionSkill],
        toolsets: [CompanionToolset]
    ) {
        self.skills = Self.unique(skills)
        self.toolsets = Self.unique(toolsets)
    }

    private static func unique<Value: Identifiable>(
        _ values: [Value]
    ) -> [Value] where Value.ID == String {
        var seen: Set<String> = []
        return values.prefix(maximumRows).filter {
            seen.insert($0.id).inserted
        }
    }
}

private struct CompanionSkillsEnvelope: Decodable {
    let object: String?
    let data: [CompanionSkillPayload]?

    private enum CodingKeys: String, CodingKey {
        case object
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = container.decodeDiscoveryStringIfPresent(forKey: .object)
        data = (
            try? container.decodeIfPresent(
                [LossyCompanionSkillPayload].self,
                forKey: .data
            )
        )?.compactMap(\.value)
    }
}

private struct CompanionToolsetsEnvelope: Decodable {
    let object: String?
    let platform: String?
    let data: [CompanionToolsetPayload]?

    private enum CodingKeys: String, CodingKey {
        case object
        case platform
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = container.decodeDiscoveryStringIfPresent(forKey: .object)
        platform = container.decodeDiscoveryStringIfPresent(forKey: .platform)
        data = (
            try? container.decodeIfPresent(
                [LossyCompanionToolsetPayload].self,
                forKey: .data
            )
        )?.compactMap(\.value)
    }
}

private struct CompanionSkillPayload: Decodable {
    let name: String?
    let description: String?
    let category: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeDiscoveryStringIfPresent(forKey: .name)
        description = container.decodeDiscoveryStringIfPresent(
            forKey: .description
        )
        category = container.decodeDiscoveryStringIfPresent(forKey: .category)
    }

    var domainValue: CompanionSkill? {
        guard
            let name = name?.discoveryTrimmedNonEmpty,
            name.count <= CompanionDiscoveryCatalog.maximumNameLength
        else {
            return nil
        }
        return CompanionSkill(
            name: name,
            description: discoveryBounded(
                description,
                maximum:
                    CompanionDiscoveryCatalog.maximumDescriptionLength
            ),
            category: discoveryBounded(
                category?.discoveryTrimmedNonEmpty,
                maximum: CompanionDiscoveryCatalog.maximumCategoryLength
            )
        )
    }
}

private struct CompanionToolsetPayload: Decodable {
    let name: String?
    let label: String?
    let description: String?
    let enabled: Bool?
    let configured: Bool?
    let tools: [String]?

    private enum CodingKeys: String, CodingKey {
        case name
        case label
        case description
        case enabled
        case configured
        case tools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeDiscoveryStringIfPresent(forKey: .name)
        label = container.decodeDiscoveryStringIfPresent(forKey: .label)
        description = container.decodeDiscoveryStringIfPresent(
            forKey: .description
        )
        enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        configured = try? container.decodeIfPresent(
            Bool.self,
            forKey: .configured
        )
        tools = (
            try? container.decodeIfPresent(
                [LossyDiscoveryString].self,
                forKey: .tools
            )
        )?.compactMap(\.value)
    }

    var domainValue: CompanionToolset? {
        guard
            let name = name?.discoveryTrimmedNonEmpty,
            name.count <= CompanionDiscoveryCatalog.maximumNameLength
        else {
            return nil
        }
        return CompanionToolset(
            name: name,
            label: discoveryBounded(
                label?.discoveryTrimmedNonEmpty,
                maximum: CompanionDiscoveryCatalog.maximumLabelLength
            ),
            description: discoveryBounded(
                description,
                maximum:
                    CompanionDiscoveryCatalog.maximumDescriptionLength
            ),
            enabled: enabled,
            configured: configured,
            tools: validTools
        )
    }

    private var validTools: [String]? {
        guard let tools else { return nil }
        var seen: Set<String> = []
        return tools.prefix(CompanionDiscoveryCatalog.maximumTools).compactMap {
            guard
                let value = $0.discoveryTrimmedNonEmpty,
                value.count <=
                    CompanionDiscoveryCatalog.maximumToolNameLength,
                seen.insert(value).inserted
            else {
                return nil
            }
            return value
        }
    }
}

private struct LossyCompanionSkillPayload: Decodable {
    let value: CompanionSkillPayload?

    init(from decoder: Decoder) throws {
        value = try? CompanionSkillPayload(from: decoder)
    }
}

private struct LossyCompanionToolsetPayload: Decodable {
    let value: CompanionToolsetPayload?

    init(from decoder: Decoder) throws {
        value = try? CompanionToolsetPayload(from: decoder)
    }
}

private struct LossyDiscoveryString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(String.self)
    }
}

protocol CompanionDiscoveryServing: Sendable {
    func fetch() async throws -> CompanionDiscoveryCatalog
}

enum CompanionDiscoveryServiceError: LocalizedError, Equatable {
    case missingDeviceCredential
    case companionUnreachable
    case deviceCredentialInvalid
    case deviceRevoked
    case gatewayUnavailable
    case gatewayIncompatible
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .missingDeviceCredential, .deviceCredentialInvalid:
            return String(
                localized: "This device must pair with Companion again."
            )
        case .companionUnreachable:
            return String(localized: "Hermes Nest Companion is unreachable.")
        case .deviceRevoked:
            return String(
                localized: "This device was revoked and must pair again."
            )
        case .gatewayUnavailable:
            return String(localized: "Hermes Gateway is temporarily unavailable.")
        case .gatewayIncompatible:
            return String(
                localized: "Upgrade Hermes Gateway and Companion to browse Skills and Toolsets."
            )
        case .unexpectedResponse:
            return String(
                localized: "Companion returned unexpected Skills or Toolsets data."
            )
        }
    }
}

actor CompanionDiscoveryService: CompanionDiscoveryServing {
    static let maximumResponseBytes = 2 * 1024 * 1024

    private let companionURL: URL
    private let keychain: any KeychainStoring
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(
        companionURL: URL,
        keychain: any KeychainStoring = KeychainStore(),
        session: URLSession? = nil
    ) {
        self.companionURL = companionURL
        self.keychain = keychain
        self.session = session ?? Self.makeSession()
    }

    func fetch() async throws -> CompanionDiscoveryCatalog {
        let skills: CompanionSkillsEnvelope = try await send(path: "/v1/skills")
        guard skills.object == "list" else {
            throw CompanionDiscoveryServiceError.unexpectedResponse
        }
        let toolsets: CompanionToolsetsEnvelope = try await send(
            path: "/v1/toolsets"
        )
        guard
            toolsets.object == "list",
            toolsets.platform == "api_server"
        else {
            throw CompanionDiscoveryServiceError.unexpectedResponse
        }
        return CompanionDiscoveryCatalog(
            skills: (skills.data ?? []).compactMap(\.domainValue),
            toolsets: (toolsets.data ?? []).compactMap(\.domainValue)
        )
    }

    private func send<Response: Decodable>(
        path: String
    ) async throws -> Response {
        guard
            let credential = try? keychain.load(
                .companionDeviceCredential
            ),
            !credential.isEmpty
        else {
            throw CompanionDiscoveryServiceError.missingDeviceCredential
        }
        guard
            let url = URL(string: path, relativeTo: companionURL)?.absoluteURL,
            url.host == companionURL.host
        else {
            throw CompanionDiscoveryServiceError.unexpectedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Bearer \(credential)",
            forHTTPHeaderField: "Authorization"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CompanionDiscoveryServiceError.companionUnreachable
        }
        guard
            data.count <= Self.maximumResponseBytes,
            let response = response as? HTTPURLResponse
        else {
            throw CompanionDiscoveryServiceError.unexpectedResponse
        }
        guard response.statusCode == 200 else {
            throw Self.mapHTTPError(
                statusCode: response.statusCode,
                data: data
            )
        }
        guard response.mimeType == "application/json" else {
            throw CompanionDiscoveryServiceError.unexpectedResponse
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw CompanionDiscoveryServiceError.unexpectedResponse
        }
    }

    private static func mapHTTPError(
        statusCode: Int,
        data: Data
    ) -> CompanionDiscoveryServiceError {
        let code = (
            try? JSONDecoder().decode(
                CompanionDiscoveryErrorEnvelope.self,
                from: data
            )
        )?.error?.code
        switch (statusCode, code) {
        case (401, "device_credential_invalid"):
            return .deviceCredentialInvalid
        case (403, "device_revoked"):
            return .deviceRevoked
        case (502, "gateway_incompatible"),
             (502, "gateway_malformed_response"),
             (502, "gateway_response_too_large"):
            return .gatewayIncompatible
        case (503, _), (504, _):
            return .gatewayUnavailable
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

@MainActor
@Observable
final class CompanionDiscoveryViewModel {
    private(set) var skills: [CompanionSkill] = []
    private(set) var toolsets: [CompanionToolset] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    let unavailableMessage: String?

    private let service: any CompanionDiscoveryServing

    init(
        service: any CompanionDiscoveryServing,
        isSupported: Bool
    ) {
        self.service = service
        unavailableMessage = isSupported ? nil : String(
            localized: "This Gateway or Companion does not advertise the verified read-only Skills and Toolsets API."
        )
    }

    func load() async {
        guard unavailableMessage == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let catalog = try await service.fetch()
            skills = catalog.skills
            toolsets = catalog.toolsets
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func matchingSkills(searchText: String) -> [CompanionSkill] {
        let query = searchText.discoveryTrimmedNonEmpty?.lowercased()
        guard let query else { return skills }
        return skills.filter {
            [$0.name, $0.description, $0.category]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }

    func matchingToolsets(searchText: String) -> [CompanionToolset] {
        let query = searchText.discoveryTrimmedNonEmpty?.lowercased()
        guard let query else { return toolsets }
        return toolsets.filter {
            [
                $0.name,
                $0.label,
                $0.description,
                $0.tools?.joined(separator: " "),
            ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
        }
    }
}

private struct CompanionDiscoveryErrorEnvelope: Decodable {
    let error: CompanionDiscoveryErrorBody?
}

private struct CompanionDiscoveryErrorBody: Decodable {
    let code: String?
}

private extension String {
    var discoveryTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}

private func discoveryBounded(
    _ value: String?,
    maximum: Int
) -> String? {
    guard let value, value.count <= maximum else { return nil }
    return value
}

private extension KeyedDecodingContainer {
    func decodeDiscoveryStringIfPresent(forKey key: Key) -> String? {
        try? decodeIfPresent(String.self, forKey: key)
    }
}
