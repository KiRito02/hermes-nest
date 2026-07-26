import XCTest
@testable import HermesMobile

final class CompanionConnectionServiceTests: APIClientTestCase {
    func testRequestBodyReaderSupportsDataAndStreamRepresentations() throws {
        let expected = Data(#"{"device_name":"Owner iPad"}"#.utf8)
        let url = try XCTUnwrap(URL(string: "https://companion.example.test"))

        var dataRequest = URLRequest(url: url)
        dataRequest.httpBody = expected
        XCTAssertEqual(try Self.requestBody(from: dataRequest), expected)

        var streamRequest = URLRequest(url: url)
        streamRequest.httpBodyStream = InputStream(data: expected)
        XCTAssertEqual(try Self.requestBody(from: streamRequest), expected)
    }

    func testPairingUsesOnlyVersionedCompanionRoutesAndStoresDeviceIdentity() async throws {
        let keychain = InMemoryKeychainStore()
        let session = makeSession { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: url.path == "/companion/v1/pairings/claim" ? 201 : 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )

            switch url.path {
            case "/companion/v1/health":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (
                    response,
                    Data(
                        """
                        {
                          "status": "ok",
                          "service": "hermex-companion",
                          "companion_version": "0.1.0",
                          "contract_version": "1"
                        }
                        """.utf8
                    )
                )
            case "/companion/v1/pairings/claim":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = try Self.requestBody(from: request)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                )
                XCTAssertEqual(object["secret"], "single-use-secret")
                XCTAssertEqual(object["device_name"], "Owner iPad")
                return (
                    response,
                    Data(
                        """
                        {
                          "device": {"id": "device-1", "name": "Owner iPad"},
                          "credential": "device-credential",
                          "credential_type": "Bearer",
                          "future_field": {"ignored": true}
                        }
                        """.utf8
                    )
                )
            case "/companion/v1/capabilities":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer device-credential"
                )
                return (
                    response,
                    Data(
                        """
                        {
                          "object": "hermex.companion.capabilities",
                          "contract_version": "1",
                          "companion": {
                            "version": "0.1.0",
                            "features": {
                              "pairing": true,
                              "device_auth": true,
                              "device_revocation": true,
                              "gateway_discovery": true,
                              "gateway_proxy": false
                            },
                            "endpoints": {
                              "health": {
                                "method": "GET",
                                "path": "/companion/v1/health"
                              }
                            }
                          },
                          "gateway": {
                            "status": "ok",
                            "capabilities": {
                              "object": "hermes.api_server.capabilities",
                              "platform": "hermes-agent",
                              "features": {
                                "sessions": true,
                                "session_continuity_header": "X-Hermes-Session-Id"
                              },
                              "endpoints": {}
                            },
                            "future_gateway_field": 42
                          },
                          "future_top_level_field": "ignored"
                        }
                        """.utf8
                    )
                )
            default:
                XCTFail("Unexpected legacy or direct-Gateway route: \(url.path)")
                return (response, Data())
            }
        }
        let service = LiveCompanionConnectionService(
            keychain: keychain,
            session: session
        )

        let connection = try await service.pair(
            companionURLString: "https://companion.example.test/private/path?ignored=1",
            secret: "single-use-secret",
            deviceName: "Owner iPad"
        )

        XCTAssertEqual(connection.companionURL, URL(string: "https://companion.example.test"))
        XCTAssertEqual(connection.deviceID, "device-1")
        XCTAssertEqual(connection.capabilities.gateway?.status, "ok")
        XCTAssertEqual(
            connection.capabilities.gateway?.capabilities?.features?["sessions"],
            .bool(true)
        )
        XCTAssertEqual(
            connection.capabilities.gateway?.capabilities?.features?["session_continuity_header"],
            .string("X-Hermes-Session-Id")
        )
        XCTAssertEqual(keychain.savedValues[.companionURL], "https://companion.example.test")
        XCTAssertEqual(keychain.savedValues[.companionDeviceID], "device-1")
        XCTAssertEqual(keychain.savedValues[.companionDeviceCredential], "device-credential")
        XCTAssertFalse(keychain.savedValues.values.contains("single-use-secret"))
    }

    func testResumeUsesStoredDeviceCredentialWithoutPairingOrWebUILogin() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("https://companion.example.test", forKey: .companionURL)
        try keychain.save("device-1", forKey: .companionDeviceID)
        try keychain.save("device-credential", forKey: .companionDeviceCredential)
        let session = makeSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/companion/v1/capabilities")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer device-credential"
            )
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (
                response,
                Data(
                    """
                    {
                      "object": "hermex.companion.capabilities",
                      "contract_version": "1",
                      "companion": {
                        "version": "0.1.0",
                        "features": {
                          "pairing": true,
                          "device_auth": true,
                          "device_revocation": true,
                          "gateway_discovery": true,
                          "gateway_proxy": false
                        },
                        "endpoints": {
                          "health": {
                            "method": "GET",
                            "path": "/companion/v1/health"
                          }
                        }
                      },
                      "gateway": {"status": "unavailable", "capabilities": null}
                    }
                    """.utf8
                )
            )
        }
        let service = LiveCompanionConnectionService(
            keychain: keychain,
            session: session
        )

        let connection = try await service.resume()

        XCTAssertEqual(connection?.deviceID, "device-1")
        XCTAssertEqual(connection?.capabilities.gateway?.status, "unavailable")
    }

    func testResumeRejectsIncompleteCapabilityDocument() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("https://companion.example.test", forKey: .companionURL)
        try keychain.save("device-1", forKey: .companionDeviceID)
        try keychain.save("device-credential", forKey: .companionDeviceCredential)
        let session = makeSession { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (
                response,
                Data(
                    """
                    {
                      "contract_version": "1",
                      "gateway": {"status": "unavailable", "capabilities": null}
                    }
                    """.utf8
                )
            )
        }
        let service = LiveCompanionConnectionService(
            keychain: keychain,
            session: session
        )

        do {
            _ = try await service.resume()
            XCTFail("Expected incompatible-Companion error")
        } catch CompanionConnectionError.incompatibleCompanion {
            // Expected.
        } catch {
            XCTFail("Expected incompatible-Companion error, got \(error)")
        }
    }

    func testRevokedDeviceClearsCredentialButKeepsURLAndDeviceIDForRepairing() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("https://companion.example.test", forKey: .companionURL)
        try keychain.save("device-1", forKey: .companionDeviceID)
        try keychain.save("revoked-credential", forKey: .companionDeviceCredential)
        let session = makeSession { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (
                response,
                Data(
                    """
                    {
                      "error": {
                        "code": "device_revoked",
                        "message": "Device credential has been revoked."
                      }
                    }
                    """.utf8
                )
            )
        }
        let service = LiveCompanionConnectionService(
            keychain: keychain,
            session: session
        )

        do {
            _ = try await service.resume()
            XCTFail("Expected revoked-device error")
        } catch CompanionConnectionError.deviceRevoked {
            // Expected.
        } catch {
            XCTFail("Expected revoked-device error, got \(error)")
        }

        XCTAssertNil(keychain.savedValues[.companionDeviceCredential])
        XCTAssertEqual(keychain.savedValues[.companionURL], "https://companion.example.test")
        XCTAssertEqual(keychain.savedValues[.companionDeviceID], "device-1")
    }

    func testForgetRevokesCurrentDeviceThenClearsLocalIdentity() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("https://companion.example.test", forKey: .companionURL)
        try keychain.save("device-1", forKey: .companionDeviceID)
        try keychain.save("device-credential", forKey: .companionDeviceCredential)
        let session = makeSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/companion/v1/devices/device-1")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer device-credential"
            )
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data())
        }
        let service = LiveCompanionConnectionService(
            keychain: keychain,
            session: session
        )

        await service.forget()

        XCTAssertNil(keychain.savedValues[.companionURL])
        XCTAssertNil(keychain.savedValues[.companionDeviceID])
        XCTAssertNil(keychain.savedValues[.companionDeviceCredential])
    }

    func testRemotePlainHTTPCompanionURLIsRejectedBeforeNetworkRequest() async {
        let service = LiveCompanionConnectionService(
            keychain: InMemoryKeychainStore(),
            session: makeSession { request in
                XCTFail("Unexpected request to \(String(describing: request.url))")
                throw URLError(.badURL)
            }
        )

        do {
            _ = try await service.checkLiveness(
                companionURLString: "http://nas.example.test:8643"
            )
            XCTFail("Expected insecure-transport error")
        } catch CompanionConnectionError.insecureTransport {
            // Expected.
        } catch {
            XCTFail("Expected insecure-transport error, got \(error)")
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    func testDebugSimulatorAllowsLoopbackHTTPOnly() throws {
        XCTAssertEqual(
            try LiveCompanionConnectionService.normalizedCompanionURL(
                from: "127.0.0.1:8643"
            ),
            URL(string: "http://127.0.0.1:8643")
        )
    }
    #endif

    func testCapabilityDecodingToleratesMissingAndUnknownFields() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let capabilities = try decoder.decode(
            CompanionCapabilities.self,
            from: Data(
                """
                {
                  "contract_version": "1",
                  "companion": {"unknown": {"nested": true}},
                  "gateway": {
                    "status": "incompatible",
                    "capabilities": null,
                    "unknown": [1, 2, 3]
                  },
                  "unknown": true
                }
                """.utf8
            )
        )

        XCTAssertEqual(capabilities.contractVersion, "1")
        XCTAssertNil(capabilities.object)
        XCTAssertNil(capabilities.companion?.version)
        XCTAssertEqual(capabilities.gateway?.status, "incompatible")
    }

    @MainActor
    func testManagerTreatsGatewayUnavailableAsConnectedCompanionState() async throws {
        let connection = CompanionConnection(
            companionURL: try XCTUnwrap(URL(string: "https://companion.example.test")),
            deviceID: "device-1",
            capabilities: CompanionCapabilities(
                object: "hermex.companion.capabilities",
                contractVersion: "1",
                companion: nil,
                gateway: CompanionGatewayCapabilityBlock(
                    status: "unavailable",
                    capabilities: nil
                )
            )
        )
        let service = StubCompanionConnectionService(resumedConnection: connection)
        let manager = CompanionConnectionManager(
            service: service,
            deviceName: { "Owner iPad" }
        )

        await manager.restoreIfNeeded()

        XCTAssertEqual(manager.state, .connected(connection))
        XCTAssertNil(manager.lastErrorMessage)
    }

    @MainActor
    func testRejectedPairingSecretKeepsOnboardingStateAndDoesNotPersistSecret() async {
        let service = StubCompanionConnectionService(
            pairError: .pairingSecretInvalid
        )
        let manager = CompanionConnectionManager(
            service: service,
            deviceName: { "Owner iPad" }
        )
        await manager.restoreIfNeeded()
        XCTAssertEqual(manager.state, .unconfigured(savedURL: nil))

        let paired = await manager.pair(
            companionURLString: "https://companion.example.test",
            secret: "rejected-secret"
        )

        XCTAssertFalse(paired)
        XCTAssertEqual(manager.state, .unconfigured(savedURL: nil))
        XCTAssertEqual(
            manager.lastErrorMessage,
            CompanionConnectionError.pairingSecretInvalid.localizedDescription
        )
        let receivedSecret = await service.receivedPairingSecret()
        XCTAssertEqual(receivedSecret, "rejected-secret")
    }

    private func makeSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func requestBody(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        let stream = try XCTUnwrap(
            request.httpBodyStream,
            "Foundation should preserve a POST body as Data or an input stream"
        )
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead == 0 {
                return body
            }
            guard bytesRead > 0 else {
                throw RequestBodyStreamReadError()
            }
            body.append(contentsOf: buffer.prefix(bytesRead))
        }
    }
}

private struct RequestBodyStreamReadError: Error {}

private actor StubCompanionConnectionService: CompanionConnectionServing {
    private let resumedConnection: CompanionConnection?
    private let pairError: CompanionConnectionError?
    private var pairingSecret: String?

    init(
        resumedConnection: CompanionConnection? = nil,
        pairError: CompanionConnectionError? = nil
    ) {
        self.resumedConnection = resumedConnection
        self.pairError = pairError
    }

    func checkLiveness(companionURLString: String) async throws -> CompanionHealth {
        CompanionHealth(
            status: "ok",
            service: "hermex-companion",
            companionVersion: "0.1.0",
            contractVersion: "1"
        )
    }

    func pair(
        companionURLString: String,
        secret: String,
        deviceName: String
    ) async throws -> CompanionConnection {
        pairingSecret = secret
        if let pairError {
            throw pairError
        }
        guard let resumedConnection else {
            throw CompanionConnectionError.unexpectedResponse
        }
        return resumedConnection
    }

    func savedCompanionURL() async -> URL? {
        resumedConnection?.companionURL
    }

    func hasStoredDeviceCredential() async -> Bool {
        resumedConnection != nil
    }

    func resume() async throws -> CompanionConnection? {
        resumedConnection
    }

    func forget() async {}

    func receivedPairingSecret() -> String? {
        pairingSecret
    }
}
