import Foundation

struct CompanionHealth: Codable, Equatable, Sendable {
    let status: String?
    let service: String?
    let companionVersion: String?
    let contractVersion: String?
}

struct CompanionPairingResponse: Codable, Equatable, Sendable {
    let device: CompanionPairedDevice?
    let credential: String?
    let credentialType: String?
}

struct CompanionPairedDevice: Codable, Equatable, Sendable {
    let id: String?
    let name: String?
}

struct CompanionCapabilities: Codable, Equatable, Sendable {
    let object: String?
    let contractVersion: String?
    let companion: CompanionCapabilityBlock?
    let gateway: CompanionGatewayCapabilityBlock?

    var supportsRunApprovals: Bool {
        guard
            gateway?.status == "ok",
            companion?.features?["run_approval_proxy"] == .bool(true),
            companion?.endpoints?["run_approval"]?.method == "POST",
            companion?.endpoints?["run_approval"]?.path
                == "/v1/runs/{run_id}/approval",
            let capabilities = gateway?.capabilities,
            capabilities.features?["approval_events"] == .bool(true),
            capabilities.features?["run_approval_response"] == .bool(true),
            capabilities.endpoints?["run_approval"]?.method == "POST",
            capabilities.endpoints?["run_approval"]?.path
                == "/v1/runs/{run_id}/approval"
        else {
            return false
        }
        return true
    }

    var supportsModelSelection: Bool {
        guard
            gateway?.status == "ok",
            companion?.features?["model_options_proxy"] == .bool(true),
            companion?.features?["session_model_lock_proxy"] == .bool(true),
            companion?.endpoints?["model_options"]?.method == "GET",
            companion?.endpoints?["model_options"]?.path
                == "/api/model/options",
            companion?.endpoints?["session_model_lock"]?.method == "POST",
            companion?.endpoints?["session_model_lock"]?.path
                == "/api/sessions/{session_id}/model",
            let capabilities = gateway?.capabilities,
            capabilities.features?["model_options"] == .bool(true),
            capabilities.features?["session_model_lock"] == .bool(true),
            capabilities.endpoints?["model_options"]?.method == "GET",
            capabilities.endpoints?["model_options"]?.path
                == "/api/model/options",
            capabilities.endpoints?["session_model_lock"]?.method == "POST",
            capabilities.endpoints?["session_model_lock"]?.path
                == "/api/sessions/{session_id}/model"
        else {
            return false
        }
        return true
    }
}

struct CompanionCapabilityBlock: Codable, Equatable, Sendable {
    let version: String?
    let features: [String: JSONValue]?
    let endpoints: [String: CompanionEndpointCapability]?
}

struct CompanionEndpointCapability: Codable, Equatable, Sendable {
    let method: String?
    let path: String?
}

struct CompanionGatewayCapabilityBlock: Codable, Equatable, Sendable {
    let status: String?
    let capabilities: CompanionGatewayCapabilities?
}

struct CompanionGatewayCapabilities: Codable, Equatable, Sendable {
    let object: String?
    let platform: String?
    let auth: CompanionGatewayAuthCapability?
    let runtime: CompanionGatewayRuntimeCapability?
    let features: [String: JSONValue]?
    let endpoints: [String: CompanionEndpointCapability]?
}

struct CompanionGatewayAuthCapability: Codable, Equatable, Sendable {
    let type: String?
    let required: Bool?
}

struct CompanionGatewayRuntimeCapability: Codable, Equatable, Sendable {
    let mode: String?
    let toolExecution: String?
    let splitRuntime: Bool?
}

enum CompanionReasoningEffort:
    String,
    CaseIterable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh

    var displayName: String {
        switch self {
        case .none: return String(localized: "Off")
        case .minimal: return String(localized: "Minimal")
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        case .xhigh: return String(localized: "Extra High")
        }
    }
}

struct CompanionModelSelection: Equatable, Sendable {
    let model: String
    let provider: String
    let reasoningEffort: CompanionReasoningEffort?
}

struct CompanionModelOption: Identifiable, Equatable, Sendable {
    var id: String {
        "\(provider)/\(model)"
    }

    let model: String
    let provider: String
    let providerName: String
    let supportsReasoning: Bool
}

struct CompanionModelGroup: Identifiable, Equatable, Sendable {
    var id: String {
        provider
    }

    let provider: String
    let name: String
    let models: [CompanionModelOption]
}

struct CompanionModelInventory: Decodable, Equatable, Sendable {
    let providers: [CompanionModelProvider]?
    let model: String?
    let provider: String?

    enum CodingKeys: String, CodingKey {
        case providers
        case model
        case provider
    }

    init(
        providers: [CompanionModelProvider]?,
        model: String?,
        provider: String?
    ) {
        self.providers = providers
        self.model = model
        self.provider = provider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = (
            try? container.decodeIfPresent(
                [LossyCompanionModelProvider].self,
                forKey: .providers
            )
        )?.compactMap(\.value)
        model = container.decodeLossyStringIfPresent(forKey: .model)
        provider = container.decodeLossyStringIfPresent(forKey: .provider)
    }

    var catalogGroups: [CompanionModelGroup] {
        var seenProviders: Set<String> = []
        var groups: [CompanionModelGroup] = []
        for provider in providers ?? [] {
            guard
                provider.authenticated == true,
                let slug = provider.slug?.trimmedNonEmpty,
                slug.count <= 80,
                seenProviders.insert(slug.lowercased()).inserted,
                let rawModels = provider.modelIDs
            else {
                continue
            }
            var seenModels: Set<String> = []
            let models = rawModels.filter {
                $0.count <= 200 && seenModels.insert($0).inserted
            }
            guard
                !models.isEmpty
            else {
                continue
            }
            let providerName = provider.name?.trimmedNonEmpty ?? slug
            groups.append(
                CompanionModelGroup(
                    provider: slug,
                    name: providerName,
                    models: models.map {
                        CompanionModelOption(
                            model: $0,
                            provider: slug,
                            providerName: providerName,
                            supportsReasoning:
                                provider.supportsReasoning(model: $0)
                        )
                    }
                )
            )
        }
        return groups
    }

    var currentSelection: CompanionModelSelection? {
        guard
            let model = model?.trimmedNonEmpty,
            let provider = provider?.trimmedNonEmpty
        else {
            return nil
        }
        return CompanionModelSelection(
            model: model,
            provider: provider,
            reasoningEffort: nil
        )
    }
}

struct CompanionModelProvider: Decodable, Equatable, Sendable {
    let slug: String?
    let name: String?
    let models: [JSONValue]?
    let authenticated: Bool?
    let capabilities: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case slug
        case name
        case models
        case authenticated
        case capabilities
    }

    init(
        slug: String?,
        name: String?,
        models: [JSONValue]?,
        authenticated: Bool?,
        capabilities: [String: JSONValue]?
    ) {
        self.slug = slug
        self.name = name
        self.models = models
        self.authenticated = authenticated
        self.capabilities = capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = container.decodeLossyStringIfPresent(forKey: .slug)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        models = try? container.decodeIfPresent(
            [JSONValue].self,
            forKey: .models
        )
        authenticated = try? container.decodeIfPresent(
            Bool.self,
            forKey: .authenticated
        )
        capabilities = try? container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .capabilities
        )
    }

    var modelIDs: [String]? {
        models?.compactMap {
            guard case .string(let value) = $0 else { return nil }
            return value.trimmedNonEmpty
        }
    }

    func supportsReasoning(model: String) -> Bool {
        guard
            case .object(let capability) = capabilities?[model],
            case .bool(let supported) = capability["reasoning"]
        else {
            return false
        }
        return supported
    }
}

struct CompanionModelLockAcknowledgement:
    Decodable,
    Equatable,
    Sendable
{
    let object: String?
    let sessionID: String?
    let runtime: CompanionModelRuntime?

    enum CodingKeys: String, CodingKey {
        case object
        case sessionID = "session_id"
        case runtime
    }

    init(
        object: String?,
        sessionID: String?,
        runtime: CompanionModelRuntime?
    ) {
        self.object = object
        self.sessionID = sessionID
        self.runtime = runtime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = container.decodeLossyStringIfPresent(forKey: .object)
        sessionID = container.decodeLossyStringIfPresent(
            forKey: .sessionID
        )
        runtime = try? container.decodeIfPresent(
            CompanionModelRuntime.self,
            forKey: .runtime
        )
    }

    var selection: CompanionModelSelection? {
        guard
            let model = runtime?.model?.trimmedNonEmpty,
            let provider = runtime?.provider?.trimmedNonEmpty
        else {
            return nil
        }
        return CompanionModelSelection(
            model: model,
            provider: provider,
            reasoningEffort: nil
        )
    }
}

struct CompanionModelRuntime: Decodable, Equatable, Sendable {
    let provider: String?
    let model: String?
    let modelLock: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case model
        case modelLock = "model_lock"
    }

    init(
        provider: String?,
        model: String?,
        modelLock: String?
    ) {
        self.provider = provider
        self.model = model
        self.modelLock = modelLock
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = container.decodeLossyStringIfPresent(forKey: .provider)
        model = container.decodeLossyStringIfPresent(forKey: .model)
        modelLock = container.decodeLossyStringIfPresent(
            forKey: .modelLock
        )
    }
}

private struct LossyCompanionModelProvider: Decodable {
    let value: CompanionModelProvider?

    init(from decoder: Decoder) throws {
        value = try? CompanionModelProvider(from: decoder)
    }
}

protocol CompanionModelServing: Sendable {
    func fetchOptions(refresh: Bool) async throws -> CompanionModelInventory
    func lock(
        _ selection: CompanionModelSelection,
        sessionID: String
    ) async throws -> CompanionModelLockAcknowledgement
}

enum CompanionModelServiceError: LocalizedError, Equatable {
    case missingDeviceCredential
    case invalidSelection
    case invalidSessionID
    case companionUnreachable
    case deviceCredentialInvalid
    case deviceRevoked
    case gatewayUnavailable
    case gatewayIncompatible
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .missingDeviceCredential, .deviceCredentialInvalid:
            return String(localized: "This device must pair with Companion again.")
        case .invalidSelection:
            return String(localized: "Choose a valid Hermes model and provider.")
        case .invalidSessionID:
            return String(localized: "The Hermes session identity is invalid.")
        case .companionUnreachable:
            return String(localized: "Hermes Nest Companion is unreachable.")
        case .deviceRevoked:
            return String(localized: "This device was revoked and must pair again.")
        case .gatewayUnavailable:
            return String(localized: "Hermes Gateway is temporarily unavailable.")
        case .gatewayIncompatible:
            return String(localized: "Upgrade Hermes Gateway to use native model selection.")
        case .unexpectedResponse:
            return String(localized: "Companion returned unexpected model data.")
        }
    }
}

actor CompanionModelService: CompanionModelServing {
    static let maximumResponseBytes = 2 * 1024 * 1024

    private let companionURL: URL
    private let keychain: any KeychainStoring
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        companionURL: URL,
        keychain: any KeychainStoring = KeychainStore(),
        session: URLSession? = nil
    ) {
        self.companionURL = companionURL
        self.keychain = keychain
        self.session = session ?? Self.makeSession()
    }

    func fetchOptions(
        refresh: Bool = false
    ) async throws -> CompanionModelInventory {
        var components = URLComponents(
            url: companionURL
                .appendingPathComponent("api", isDirectory: true)
                .appendingPathComponent("model", isDirectory: true)
                .appendingPathComponent("options", isDirectory: false),
            resolvingAgainstBaseURL: false
        )
        if refresh {
            components?.queryItems = [
                URLQueryItem(name: "refresh", value: "true")
            ]
        }
        guard let url = components?.url else {
            throw CompanionModelServiceError.unexpectedResponse
        }
        let inventory: CompanionModelInventory = try await send(
            url: url,
            method: "GET",
            body: Optional<CompanionModelLockBody>.none
        )
        guard !inventory.catalogGroups.isEmpty else {
            throw CompanionModelServiceError.gatewayIncompatible
        }
        return inventory
    }

    func lock(
        _ selection: CompanionModelSelection,
        sessionID: String
    ) async throws -> CompanionModelLockAcknowledgement {
        guard
            selection.model.trimmedNonEmpty != nil,
            selection.model.count <= 200,
            selection.provider.trimmedNonEmpty != nil,
            selection.provider.count <= 80
        else {
            throw CompanionModelServiceError.invalidSelection
        }
        let sessionID = try Self.validatedSessionID(sessionID)
        let url = companionURL
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("model", isDirectory: false)
        let acknowledgement: CompanionModelLockAcknowledgement =
            try await send(
                url: url,
                method: "POST",
                body: CompanionModelLockBody(selection: selection)
            )
        guard
            acknowledgement.object == "hermes.session.model_lock",
            acknowledgement.sessionID == sessionID,
            acknowledgement.selection?.model == selection.model,
            acknowledgement.selection?.provider == selection.provider
        else {
            throw CompanionModelServiceError.unexpectedResponse
        }
        return acknowledgement
    }

    private func send<Response: Decodable, Body: Encodable>(
        url: URL,
        method: String,
        body: Body?
    ) async throws -> Response {
        guard
            let credential = try? keychain.load(
                .companionDeviceCredential
            ),
            !credential.isEmpty
        else {
            throw CompanionModelServiceError.missingDeviceCredential
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Bearer \(credential)",
            forHTTPHeaderField: "Authorization"
        )
        if let body {
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw CompanionModelServiceError.invalidSelection
            }
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CompanionModelServiceError.companionUnreachable
        }
        guard
            data.count <= Self.maximumResponseBytes,
            let response = response as? HTTPURLResponse
        else {
            throw CompanionModelServiceError.unexpectedResponse
        }
        guard response.statusCode == 200 else {
            throw Self.mapHTTPError(
                statusCode: response.statusCode,
                data: data
            )
        }
        guard response.mimeType == "application/json" else {
            throw CompanionModelServiceError.unexpectedResponse
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw CompanionModelServiceError.unexpectedResponse
        }
    }

    private static func validatedSessionID(
        _ value: String
    ) throws -> String {
        guard
            !value.isEmpty,
            value.count <= 256,
            !value.contains("/"),
            !value.contains("\\"),
            !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw CompanionModelServiceError.invalidSessionID
        }
        return value
    }

    private static func mapHTTPError(
        statusCode: Int,
        data: Data
    ) -> CompanionModelServiceError {
        let code = (
            try? JSONDecoder().decode(
                CompanionErrorEnvelope.self,
                from: data
            )
        )?.error?.code
        switch (statusCode, code) {
        case (401, "device_credential_invalid"):
            return .deviceCredentialInvalid
        case (403, "device_revoked"):
            return .deviceRevoked
        case (400, _):
            return .invalidSelection
        case (502, "gateway_incompatible"),
             (502, "gateway_malformed_response"):
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
        configuration.requestCachePolicy =
            .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: CompanionRedirectBlocker(),
            delegateQueue: nil
        )
    }
}

private struct CompanionModelLockBody: Encodable {
    let model: String
    let provider: String
    let modelOptions: CompanionModelOptionsBody?

    init(selection: CompanionModelSelection) {
        model = selection.model
        provider = selection.provider
        modelOptions = selection.reasoningEffort.map {
            CompanionModelOptionsBody(reasoningEffort: $0)
        }
    }

    enum CodingKeys: String, CodingKey {
        case model
        case provider
        case modelOptions = "model_options"
    }
}

private struct CompanionModelOptionsBody: Encodable {
    let reasoningEffort: CompanionReasoningEffort
    let reasoning: CompanionReasoningBody

    init(reasoningEffort: CompanionReasoningEffort) {
        self.reasoningEffort = reasoningEffort
        reasoning = CompanionReasoningBody(
            enabled: reasoningEffort != .none,
            effort: reasoningEffort
        )
    }

    enum CodingKeys: String, CodingKey {
        case reasoningEffort = "reasoning_effort"
        case reasoning
    }
}

private struct CompanionReasoningBody: Encodable {
    let enabled: Bool
    let effort: CompanionReasoningEffort
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CompanionConnection: Equatable, Sendable {
    let companionURL: URL
    let deviceID: String
    let capabilities: CompanionCapabilities
}

enum CompanionConnectionError: LocalizedError, Equatable {
    case invalidURL
    case insecureTransport
    case companionUnreachable
    case incompatibleCompanion
    case invalidDeviceCredential
    case deviceRevoked
    case pairingSecretInvalid
    case pairingSecretUsed
    case pairingSecretExpired
    case invalidRequest
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Enter a valid Companion URL.")
        case .insecureTransport:
            return String(localized: "Use an HTTPS Companion URL. Plain HTTP is allowed only for local simulator development.")
        case .companionUnreachable:
            return String(localized: "Hermes Nest Companion is unreachable. Check Lucky or Tailscale HTTPS and confirm the Companion service is running.")
        case .incompatibleCompanion:
            return String(localized: "This Hermes Nest Companion version is not compatible with the app.")
        case .invalidDeviceCredential:
            return String(localized: "This device credential is no longer valid. Create a new pairing secret on the NAS.")
        case .deviceRevoked:
            return String(localized: "This device was revoked. Create a new pairing secret on the NAS.")
        case .pairingSecretInvalid:
            return String(localized: "The pairing secret is invalid.")
        case .pairingSecretUsed:
            return String(localized: "The pairing secret was already used. Create a new one on the NAS.")
        case .pairingSecretExpired:
            return String(localized: "The pairing secret expired. Create a new one on the NAS.")
        case .invalidRequest:
            return String(localized: "Check the Companion URL, pairing secret, and device name.")
        case .unexpectedResponse:
            return String(localized: "Hermes Nest Companion returned an unexpected response.")
        }
    }
}

protocol CompanionConnectionServing: Sendable {
    func checkLiveness(companionURLString: String) async throws -> CompanionHealth
    func pair(
        companionURLString: String,
        secret: String,
        deviceName: String
    ) async throws -> CompanionConnection
    func savedCompanionURL() async -> URL?
    func hasStoredDeviceCredential() async -> Bool
    func resume() async throws -> CompanionConnection?
    func forget() async
}

actor LiveCompanionConnectionService: CompanionConnectionServing {
    nonisolated static let supportedContractVersion = "1"

    private let keychain: any KeychainStoring
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        keychain: any KeychainStoring = KeychainStore(),
        session: URLSession? = nil
    ) {
        self.keychain = keychain
        self.session = session ?? Self.makeSession()

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func checkLiveness(companionURLString: String) async throws -> CompanionHealth {
        let companionURL = try Self.normalizedCompanionURL(from: companionURLString)
        let health: CompanionHealth = try await send(
            baseURL: companionURL,
            path: "/companion/v1/health",
            method: "GET",
            credential: nil,
            body: Optional<EmptyCompanionBody>.none,
            expectedStatus: 200
        )
        guard
            health.status == "ok",
            health.service == "hermex-companion",
            health.contractVersion == Self.supportedContractVersion
        else {
            throw CompanionConnectionError.incompatibleCompanion
        }
        return health
    }

    func pair(
        companionURLString: String,
        secret: String,
        deviceName: String
    ) async throws -> CompanionConnection {
        let companionURL = try Self.normalizedCompanionURL(from: companionURLString)
        _ = try await checkLiveness(companionURLString: companionURL.absoluteString)

        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty, !trimmedDeviceName.isEmpty else {
            throw CompanionConnectionError.invalidRequest
        }

        let response: CompanionPairingResponse = try await send(
            baseURL: companionURL,
            path: "/companion/v1/pairings/claim",
            method: "POST",
            credential: nil,
            body: CompanionPairingRequest(
                secret: trimmedSecret,
                deviceName: trimmedDeviceName
            ),
            expectedStatus: 201
        )

        guard
            response.credentialType?.caseInsensitiveCompare("Bearer") == .orderedSame,
            let credential = response.credential?.trimmingCharacters(in: .whitespacesAndNewlines),
            !credential.isEmpty,
            let deviceID = response.device?.id?.trimmingCharacters(in: .whitespacesAndNewlines),
            !deviceID.isEmpty
        else {
            throw CompanionConnectionError.unexpectedResponse
        }

        try persistIdentity(
            companionURL: companionURL,
            deviceID: deviceID,
            credential: credential
        )

        do {
            let capabilities = try await fetchCapabilities(
                baseURL: companionURL,
                credential: credential
            )
            return CompanionConnection(
                companionURL: companionURL,
                deviceID: deviceID,
                capabilities: capabilities
            )
        } catch {
            // The one-time pairing secret has already been consumed. Keep the
            // newly minted device identity so a transient discovery failure can
            // resume without forcing the owner to mint another secret.
            throw error
        }
    }

    func resume() async throws -> CompanionConnection? {
        guard
            let savedURL = try? keychain.load(.companionURL),
            let companionURL = URL(string: savedURL),
            let deviceID = try? keychain.load(.companionDeviceID),
            !deviceID.isEmpty,
            let credential = try? keychain.load(.companionDeviceCredential),
            !credential.isEmpty
        else {
            return nil
        }

        do {
            let capabilities = try await fetchCapabilities(
                baseURL: companionURL,
                credential: credential
            )
            return CompanionConnection(
                companionURL: companionURL,
                deviceID: deviceID,
                capabilities: capabilities
            )
        } catch CompanionConnectionError.invalidDeviceCredential {
            try? keychain.delete(.companionDeviceCredential)
            throw CompanionConnectionError.invalidDeviceCredential
        } catch CompanionConnectionError.deviceRevoked {
            try? keychain.delete(.companionDeviceCredential)
            throw CompanionConnectionError.deviceRevoked
        }
    }

    func savedCompanionURL() async -> URL? {
        guard
            let rawValue = try? keychain.load(.companionURL),
            !rawValue.isEmpty
        else {
            return nil
        }
        return URL(string: rawValue)
    }

    func hasStoredDeviceCredential() async -> Bool {
        guard
            let credential = try? keychain.load(.companionDeviceCredential),
            !credential.isEmpty
        else {
            return false
        }
        return true
    }

    func forget() async {
        if
            let rawURL = try? keychain.load(.companionURL),
            let companionURL = URL(string: rawURL),
            let deviceID = try? keychain.load(.companionDeviceID),
            !deviceID.isEmpty,
            let credential = try? keychain.load(.companionDeviceCredential),
            !credential.isEmpty
        {
            await revokeDeviceBestEffort(
                baseURL: companionURL,
                deviceID: deviceID,
                credential: credential
            )
        }
        try? keychain.delete(.companionDeviceCredential)
        try? keychain.delete(.companionDeviceID)
        try? keychain.delete(.companionURL)
    }

    nonisolated static func normalizedCompanionURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CompanionConnectionError.invalidURL
        }

        let schemedValue = trimmed.contains("://")
            ? trimmed
            : "\(defaultScheme(for: trimmed))://\(trimmed)"
        guard
            var components = URLComponents(string: schemedValue),
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil
        else {
            throw CompanionConnectionError.invalidURL
        }

        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else {
            throw CompanionConnectionError.invalidURL
        }
        if scheme == "http",
           !(allowsLocalHTTPForDebugSimulator && isLocalDevelopmentHost(host)) {
            throw CompanionConnectionError.insecureTransport
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw CompanionConnectionError.invalidURL
        }
        return url
    }

    private func fetchCapabilities(
        baseURL: URL,
        credential: String
    ) async throws -> CompanionCapabilities {
        let capabilities: CompanionCapabilities = try await send(
            baseURL: baseURL,
            path: "/companion/v1/capabilities",
            method: "GET",
            credential: credential,
            body: Optional<EmptyCompanionBody>.none,
            expectedStatus: 200
        )
        guard Self.isSupported(capabilities) else {
            throw CompanionConnectionError.incompatibleCompanion
        }
        return capabilities
    }

    private nonisolated static func isSupported(
        _ capabilities: CompanionCapabilities
    ) -> Bool {
        guard
            capabilities.object == "hermex.companion.capabilities",
            capabilities.contractVersion == supportedContractVersion,
            let companion = capabilities.companion,
            let version = companion.version,
            !version.isEmpty,
            version.count <= 64,
            companion.features?["pairing"] == .bool(true),
            companion.features?["device_auth"] == .bool(true),
            companion.features?["device_revocation"] == .bool(true),
            companion.features?["gateway_discovery"] == .bool(true),
            companion.features?["gateway_proxy"] == .bool(true),
            companion.endpoints?["health"]?.method == "GET",
            companion.endpoints?["health"]?.path == "/companion/v1/health",
            let gateway = capabilities.gateway,
            let gatewayStatus = gateway.status
        else {
            return false
        }

        switch gatewayStatus {
        case "ok":
            return gateway.capabilities?.object == "hermes.api_server.capabilities"
                && gateway.capabilities?.platform == "hermes-agent"
                && gateway.capabilities?.features?["session_resources"] == .bool(true)
                && gateway.capabilities?.endpoints?["sessions"]?.method == "GET"
                && gateway.capabilities?.endpoints?["sessions"]?.path == "/api/sessions"
        case "unavailable", "unauthorized", "incompatible":
            return gateway.capabilities == nil
        default:
            return false
        }
    }

    private func persistIdentity(
        companionURL: URL,
        deviceID: String,
        credential: String
    ) throws {
        do {
            try keychain.save(companionURL.absoluteString, forKey: .companionURL)
            try keychain.save(deviceID, forKey: .companionDeviceID)
            try keychain.save(credential, forKey: .companionDeviceCredential)
        } catch {
            try? keychain.delete(.companionDeviceCredential)
            try? keychain.delete(.companionDeviceID)
            try? keychain.delete(.companionURL)
            throw error
        }
    }

    private func revokeDeviceBestEffort(
        baseURL: URL,
        deviceID: String,
        credential: String
    ) async {
        let url = baseURL
            .appendingPathComponent("companion", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent(deviceID, isDirectory: false)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    private func send<Response: Decodable, Body: Encodable>(
        baseURL: URL,
        path: String,
        method: String,
        credential: String?,
        body: Body?,
        expectedStatus: Int
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw CompanionConnectionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credential {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CompanionConnectionError.companionUnreachable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CompanionConnectionError.unexpectedResponse
        }
        guard httpResponse.statusCode == expectedStatus else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw CompanionConnectionError.unexpectedResponse
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> CompanionConnectionError {
        let code = (try? decoder.decode(CompanionErrorEnvelope.self, from: data))?.error?.code
        switch (statusCode, code) {
        case (401, "device_credential_invalid"):
            return .invalidDeviceCredential
        case (403, "device_revoked"):
            return .deviceRevoked
        case (401, "pairing_secret_invalid"):
            return .pairingSecretInvalid
        case (409, "pairing_secret_used"):
            return .pairingSecretUsed
        case (410, "pairing_secret_expired"):
            return .pairingSecretExpired
        case (400, _):
            return .invalidRequest
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

    private nonisolated static func defaultScheme(for rawValue: String) -> String {
        guard let host = URLComponents(string: "http://\(rawValue)")?.host else {
            return "https"
        }
        return allowsLocalHTTPForDebugSimulator && isLocalDevelopmentHost(host)
            ? "http"
            : "https"
    }

    private nonisolated static var allowsLocalHTTPForDebugSimulator: Bool {
        #if DEBUG && targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private nonisolated static func isLocalDevelopmentHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }
}

private struct CompanionPairingRequest: Encodable {
    let secret: String
    let deviceName: String
}

private struct EmptyCompanionBody: Encodable {}

private struct CompanionErrorEnvelope: Decodable {
    let error: CompanionErrorBody?
}

private struct CompanionErrorBody: Decodable {
    let code: String?
    let message: String?
}

/// Pairing secrets and device credentials must never follow an HTTP redirect.
/// Operators configure the final Lucky/Tailscale HTTPS origin in the App.
final class CompanionRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
