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
