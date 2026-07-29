import XCTest
@testable import HermesMobile

final class CompanionConnectionServiceTests: CompanionHTTPTestCase {
    func testRepeatedDefaultCompanionServiceGraphsUseTwoBoundedSessionPools() throws {
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        var requestSessions: [URLSession] = []
        var eventSessions: [URLSession] = []

        for _ in 0..<3 {
            let runService = ConversationRunService(
                companionURL: companionURL
            )
            requestSessions.append(
                contentsOf: [
                    LiveCompanionConnectionService().session,
                    CompanionModelService(
                        companionURL: companionURL
                    ).session,
                    LiveSessionRepository(
                        companionURL: companionURL
                    ).session,
                    runService.session,
                    CompanionWorkspaceService(
                        companionURL: companionURL
                    ).session,
                    CompanionDiscoveryService(
                        companionURL: companionURL
                    ).session,
                ]
            )
            eventSessions.append(runService.eventSession)
        }

        let requestSession = try XCTUnwrap(requestSessions.first)
        XCTAssertEqual(18, requestSessions.count)
        XCTAssertTrue(requestSessions.allSatisfy { $0 === requestSession })

        let eventSession = try XCTUnwrap(eventSessions.first)
        XCTAssertEqual(3, eventSessions.count)
        XCTAssertTrue(eventSessions.allSatisfy { $0 === eventSession })
        XCTAssertFalse(eventSession === requestSession)
        assertCompanionSessionConfiguration(
            requestSession,
            maximumConnectionsPerHost: 2
        )
        assertCompanionSessionConfiguration(
            eventSession,
            maximumConnectionsPerHost: 1
        )
    }

    func testMessageAttachmentDecodesOpaqueCompanionDownloadPath() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let attachment = try decoder.decode(
            MessageAttachment.self,
            from: Data(
                """
                {
                  "name": "photo.png",
                  "download_path": "/companion/v1/uploads/id-1/content",
                  "mime": "image/png"
                }
                """.utf8
            )
        )

        XCTAssertNil(attachment.path)
        XCTAssertEqual(
            "/companion/v1/uploads/id-1/content",
            attachment.downloadPath
        )
    }

    func testRequestBodyReaderSupportsDataAndStreamRepresentations() throws {
        let expected = Data(#"{"device_name":"Owner iPad"}"#.utf8)
        let url = try XCTUnwrap(URL(string: "https://companion.example.test"))

        var dataRequest = URLRequest(url: url)
        dataRequest.httpBody = expected
        XCTAssertEqual(apiTestBodyData(from: dataRequest), expected)

        var streamRequest = URLRequest(url: url)
        streamRequest.httpBodyStream = InputStream(data: expected)
        XCTAssertEqual(apiTestBodyData(from: streamRequest), expected)
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
                let body = try XCTUnwrap(apiTestBodyData(from: request))
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
                              "gateway_proxy": true
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
                                "session_resources": true,
                                "session_continuity_header": "X-Hermes-Session-Id"
                              },
                              "endpoints": {
                                "sessions": {
                                  "method": "GET",
                                  "path": "/api/sessions"
                                }
                              }
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
            connection.capabilities.gateway?.capabilities?.features?["session_resources"],
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
                          "gateway_proxy": true
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
                companionURLString: "http://hermes-host.example.test:8643"
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

    func testRunApprovalSupportRequiresBothFeaturesAndExactEndpoint() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let capabilities = try decoder.decode(
            CompanionCapabilities.self,
            from: Data(
                """
                {
                  "companion": {
                    "features": {"run_approval_proxy": true},
                    "endpoints": {
                      "run_approval": {
                        "method": "POST",
                        "path": "/v1/runs/{run_id}/approval"
                      }
                    }
                  },
                  "gateway": {
                    "status": "ok",
                    "capabilities": {
                      "features": {
                        "approval_events": true,
                        "run_approval_response": true
                      },
                      "endpoints": {
                        "run_approval": {
                          "method": "POST",
                          "path": "/v1/runs/{run_id}/approval"
                        }
                      }
                    }
                  }
                }
                """.utf8
            )
        )
        let missingResponseFeature = try decoder.decode(
            CompanionCapabilities.self,
            from: Data(
                """
                {
                  "companion": {
                    "features": {"run_approval_proxy": true},
                    "endpoints": {
                      "run_approval": {
                        "method": "POST",
                        "path": "/v1/runs/{run_id}/approval"
                      }
                    }
                  },
                  "gateway": {
                    "status": "ok",
                    "capabilities": {
                      "features": {"approval_events": true},
                      "endpoints": {
                        "run_approval": {
                          "method": "POST",
                          "path": "/v1/runs/{run_id}/approval"
                        }
                      }
                    }
                  }
                }
                """.utf8
            )
        )

        XCTAssertTrue(capabilities.supportsRunApprovals)
        XCTAssertFalse(missingResponseFeature.supportsRunApprovals)
    }

    func testNativeFilesUploadsAndMemoryRequireExactCompanionContracts() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let capabilities = try decoder.decode(
            CompanionCapabilities.self,
            from: Data(
                """
                {
                  "companion": {
                    "features": {
                      "files": true,
                      "uploads": true,
                      "upload_from_file": true,
                      "memory": true
                    },
                    "endpoints": {
                      "file_roots": {
                        "method": "GET",
                        "path": "/companion/v1/files/roots"
                      },
                      "uploads": {
                        "method": "POST",
                        "path": "/companion/v1/uploads"
                      },
                      "upload_from_file": {
                        "method": "POST",
                        "path": "/companion/v1/uploads/from-file"
                      },
                      "memory": {
                        "method": "GET",
                        "path": "/companion/v1/memory/{target}"
                      },
                      "memory_operations": {
                        "method": "POST",
                        "path": "/companion/v1/memory/{target}/operations"
                      },
                      "memory_reset": {
                        "method": "POST",
                        "path": "/companion/v1/memory/{target}/reset"
                      }
                    }
                  }
                }
                """.utf8
            )
        )

        XCTAssertTrue(capabilities.supportsFiles)
        XCTAssertTrue(capabilities.supportsUploads)
        XCTAssertTrue(capabilities.supportsServerFileAttachments)
        XCTAssertTrue(capabilities.supportsBuiltInMemory)
    }

    func testModelSelectionSupportRequiresCompanionAndGatewayContracts() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let capabilities = try decoder.decode(
            CompanionCapabilities.self,
            from: Data(
                """
                {
                  "companion": {
                    "features": {
                      "model_options_proxy": true,
                      "session_model_lock_proxy": true
                    },
                    "endpoints": {
                      "model_options": {
                        "method": "GET",
                        "path": "/api/model/options"
                      },
                      "session_model_lock": {
                        "method": "POST",
                        "path": "/api/sessions/{session_id}/model"
                      }
                    }
                  },
                  "gateway": {
                    "status": "ok",
                    "capabilities": {
                      "features": {
                        "model_options": true,
                        "session_model_lock": true
                      },
                      "endpoints": {
                        "model_options": {
                          "method": "GET",
                          "path": "/api/model/options"
                        },
                        "session_model_lock": {
                          "method": "POST",
                          "path": "/api/sessions/{session_id}/model"
                        }
                      }
                    }
                  }
                }
                """.utf8
            )
        )

        XCTAssertTrue(capabilities.supportsModelSelection)
    }

    func testModelServiceUsesDeviceCredentialAndTolerantPickerShape() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        var requestCount = 0
        let session = makeSession { request in
            requestCount += 1
            XCTAssertEqual(
                "Bearer device-credential",
                request.value(forHTTPHeaderField: "Authorization")
            )
            XCTAssertNil(
                request.value(forHTTPHeaderField: "API_SERVER_KEY")
            )
            switch requestCount {
            case 1:
                XCTAssertEqual("/api/model/options", request.url?.path)
                XCTAssertEqual("refresh=true", request.url?.query)
                XCTAssertEqual("GET", request.httpMethod)
                return (
                    self.httpResponse(for: request, status: 200),
                    Data(
                        """
                        {
                          "providers": [
                            {
                              "slug": "openrouter",
                              "name": "OpenRouter",
                              "models": [
                                "anthropic/claude-sonnet-4.6",
                                42
                              ],
                              "authenticated": true,
                              "capabilities": {
                                "anthropic/claude-sonnet-4.6": {
                                  "reasoning": true,
                                  "fast": false,
                                  "future": "ignored"
                                }
                              },
                              "future": {"ignored": true}
                            },
                            {
                              "slug": "unconfigured",
                              "name": "Unavailable",
                              "models": [],
                              "authenticated": false
                            }
                          ],
                          "model": "anthropic/claude-sonnet-4.6",
                          "provider": "openrouter",
                          "future": ["ignored"]
                        }
                        """.utf8
                    )
                )
            default:
                XCTAssertEqual(
                    "/api/sessions/session-1/model",
                    request.url?.path
                )
                XCTAssertEqual("POST", request.httpMethod)
                let body = try XCTUnwrap(apiTestBodyData(from: request))
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body)
                        as? [String: Any]
                )
                XCTAssertEqual(
                    "anthropic/claude-sonnet-4.6",
                    object["model"] as? String
                )
                XCTAssertEqual(
                    "openrouter",
                    object["provider"] as? String
                )
                let options = try XCTUnwrap(
                    object["model_options"] as? [String: Any]
                )
                XCTAssertEqual(
                    "high",
                    options["reasoning_effort"] as? String
                )
                XCTAssertEqual(
                    true,
                    (options["reasoning"] as? [String: Any])?["enabled"]
                        as? Bool
                )
                XCTAssertEqual(
                    "high",
                    (options["reasoning"] as? [String: Any])?["effort"]
                        as? String
                )
                return (
                    self.httpResponse(for: request, status: 200),
                    Data(
                        """
                        {
                          "object": "hermes.session.model_lock",
                          "session_id": "session-1",
                          "runtime": {
                            "provider": "openrouter",
                            "model": "anthropic/claude-sonnet-4.6",
                            "model_lock": "accepted",
                            "future": true
                          },
                          "future": true
                        }
                        """.utf8
                    )
                )
            }
        }
        let service = CompanionModelService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let inventory = try await service.fetchOptions(refresh: true)
        XCTAssertEqual(
            "anthropic/claude-sonnet-4.6",
            inventory.currentSelection?.model
        )
        XCTAssertEqual(1, inventory.catalogGroups.count)
        XCTAssertTrue(
            inventory.catalogGroups[0].models[0].supportsReasoning
        )

        let selection = CompanionModelSelection(
            model: "anthropic/claude-sonnet-4.6",
            provider: "openrouter",
            reasoningEffort: .high
        )
        let acknowledgement = try await service.lock(
            selection,
            sessionID: "session-1"
        )
        XCTAssertEqual(selection.model, acknowledgement.selection?.model)
        XCTAssertEqual(
            selection.provider,
            acknowledgement.selection?.provider
        )
    }

    func testModelSelectionStoreScopesReasoningByServerAndSession() async throws {
        let suiteName = "test.hermes.model-selection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let selection = CompanionModelSelection(
            model: "anthropic/claude-sonnet-4.6",
            provider: "openrouter",
            reasoningEffort: .high
        )
        let store = CompanionModelSelectionStore(defaults: defaults)

        await store.save(
            selection,
            companionURL: companionURL,
            sessionID: "session-1"
        )

        let restoredSelection =
            await CompanionModelSelectionStore(defaults: defaults).load(
                companionURL: companionURL,
                sessionID: "session-1"
            )
        let otherSessionSelection = await store.load(
            companionURL: companionURL,
            sessionID: "session-2"
        )
        let otherServerSelection = await store.load(
            companionURL: try XCTUnwrap(
                URL(string: "https://other.example.test")
            ),
            sessionID: "session-1"
        )
        XCTAssertEqual(
            selection,
            restoredSelection
        )
        XCTAssertNil(otherSessionSelection)
        XCTAssertNil(otherServerSelection)
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

    func testWorkspaceRootsUseDeviceCredentialAndNativeCompanionPath() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            XCTAssertEqual(
                "/companion/v1/files/roots",
                request.url?.path
            )
            XCTAssertEqual("GET", request.httpMethod)
            XCTAssertEqual(
                "Bearer device-credential",
                request.value(forHTTPHeaderField: "Authorization")
            )
            XCTAssertNil(
                request.value(forHTTPHeaderField: "API_SERVER_KEY")
            )
            return (
                self.httpResponse(for: request, status: 200),
                Data(
                    """
                    {
                      "roots": [{
                        "id": "projects",
                        "name": "Projects",
                        "writable": true,
                        "attachable": true,
                        "future": 1
                      }]
                    }
                    """.utf8
                )
            )
        }
        let service = CompanionWorkspaceService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let roots = try await service.roots()

        XCTAssertEqual("projects", roots.first?.id)
        XCTAssertEqual(true, roots.first?.attachable)
    }

    func testWorkspaceUploadUsesMetadataFirstAndFiftyMiBBound() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            XCTAssertEqual("/companion/v1/uploads", request.url?.path)
            XCTAssertEqual("POST", request.httpMethod)
            let contentType = try XCTUnwrap(
                request.value(forHTTPHeaderField: "Content-Type")
            )
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data;"))
            let body = String(
                decoding: try XCTUnwrap(apiTestBodyData(from: request)),
                as: UTF8.self
            )
            let metadataIndex = try XCTUnwrap(
                body.range(of: "name=\"metadata\"")?.lowerBound
            )
            let fileIndex = try XCTUnwrap(
                body.range(of: "name=\"file\"")?.lowerBound
            )
            XCTAssertLessThan(metadataIndex, fileIndex)
            XCTAssertTrue(body.contains(#""root_id":"projects""#))
            XCTAssertTrue(body.contains(#""session_id":"session-1""#))
            return (
                self.httpResponse(for: request, status: 201),
                Data(
                    """
                    {
                      "upload": {
                        "id": "attachment-1",
                        "root_id": "projects",
                        "path": "notes.txt",
                        "name": "notes.txt",
                        "size": 5,
                        "content_type": "text/plain",
                        "state": "ready"
                      }
                    }
                    """.utf8
                )
            )
        }
        let service = CompanionWorkspaceService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let upload = try await service.upload(
            sessionID: "session-1",
            destination: CompanionUploadDestination(
                rootID: "projects",
                directory: ""
            ),
            filename: "notes.txt",
            contentType: "text/plain",
            fileURL: fileURL
        )

        XCTAssertEqual("attachment-1", upload.id)
    }

    func testWorkspaceStagesAuthorizedServerFileWithoutDownloadingIt() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            XCTAssertEqual(
                "/companion/v1/uploads/from-file",
                request.url?.path
            )
            XCTAssertEqual("POST", request.httpMethod)
            let body = try JSONSerialization.jsonObject(
                with: try XCTUnwrap(apiTestBodyData(from: request))
            ) as? [String: String]
            XCTAssertEqual("projects", body?["source_root_id"])
            XCTAssertEqual("reports/summary.txt", body?["source_path"])
            XCTAssertEqual("incoming", body?["destination_directory"])
            XCTAssertEqual("session-1", body?["session_id"])
            return (
                self.httpResponse(for: request, status: 201),
                Data(
                    """
                    {
                      "upload": {
                        "id": "attachment-server-1",
                        "root_id": "projects",
                        "name": "summary.txt",
                        "size": 5,
                        "content_type": "text/plain",
                        "state": "ready"
                      }
                    }
                    """.utf8
                )
            )
        }
        let service = CompanionWorkspaceService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let upload = try await service.stageServerFile(
            sessionID: "session-1",
            sourceRootID: "projects",
            sourcePath: "reports/summary.txt",
            destination: CompanionUploadDestination(
                rootID: "projects",
                directory: "incoming"
            )
        )

        XCTAssertEqual("attachment-server-1", upload.id)
        XCTAssertNil(upload.path)
    }

    func testWorkspaceDownloadsConsumedAttachmentFromOpaqueContractPath() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            XCTAssertEqual(
                "/companion/v1/uploads/attachment-1/content",
                request.url?.path
            )
            XCTAssertEqual("GET", request.httpMethod)
            XCTAssertEqual(
                "Bearer device-credential",
                request.value(forHTTPHeaderField: "Authorization")
            )
            return (
                self.httpResponse(for: request, status: 200),
                Data("image bytes".utf8)
            )
        }
        let service = CompanionWorkspaceService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let data = try await service.downloadAttachment(
            path: "/companion/v1/uploads/attachment-1/content"
        )

        XCTAssertEqual(Data("image bytes".utf8), data)
    }

    func testWorkspacePendingUploadsUseAuthenticatedSessionQuery() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            XCTAssertEqual("/companion/v1/uploads", request.url?.path)
            XCTAssertEqual("GET", request.httpMethod)
            XCTAssertEqual(
                "session-1",
                URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first { $0.name == "session_id" }?.value
            )
            XCTAssertEqual(
                "Bearer device-credential",
                request.value(forHTTPHeaderField: "Authorization")
            )
            return (
                self.httpResponse(for: request, status: 200),
                Data(
                    """
                    {
                      "uploads": [{
                        "id": "attachment-1",
                        "name": "notes.txt",
                        "state": "ready",
                        "future": true
                      }]
                    }
                    """.utf8
                )
            )
        }
        let service = CompanionWorkspaceService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let uploads = try await service.uploads(sessionID: "session-1")

        XCTAssertEqual(["attachment-1"], uploads.compactMap(\.id))
    }

    func testWorkspacePreviewUsesBoundedNativeRoute() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            XCTAssertEqual(
                "/companion/v1/files/roots/projects/preview",
                request.url?.path
            )
            XCTAssertEqual(
                "notes/readme.md",
                URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems?.first { $0.name == "path" }?.value
            )
            return (
                self.httpResponse(for: request, status: 200),
                Data(
                    """
                    {
                      "root_id": "projects",
                      "path": "notes/readme.md",
                      "name": "readme.md",
                      "kind": "text",
                      "size": 5,
                      "truncated": false,
                      "content": "hello",
                      "future": true
                    }
                    """.utf8
                )
            )
        }
        let service = CompanionWorkspaceService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let preview = try await service.preview(
            rootID: "projects",
            path: "notes/readme.md"
        )

        XCTAssertEqual("hello", preview.content)
        XCTAssertEqual(false, preview.truncated)
    }

    func testMemoryMutationSendsRevisionAndControlledOperations() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let revision = String(repeating: "a", count: 64)
        let session = makeSession { request in
            XCTAssertEqual(
                "/companion/v1/memory/user/operations",
                request.url?.path
            )
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(revision, body["revision"] as? String)
            let operations = try XCTUnwrap(
                body["operations"] as? [[String: Any]]
            )
            XCTAssertEqual("add", operations.first?["action"] as? String)
            XCTAssertEqual(
                "Uses an iPhone",
                operations.first?["content"] as? String
            )
            return (
                self.httpResponse(for: request, status: 200),
                Data(
                    """
                    {
                      "target": "user",
                      "entries": ["Uses an iPhone"],
                      "revision": "\(revision)",
                      "char_count": 14,
                      "char_limit": 1375
                    }
                    """.utf8
                )
            )
        }
        let service = CompanionWorkspaceService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let snapshot = try await service.mutateMemory(
            target: "user",
            revision: revision,
            operations: [
                CompanionMemoryOperation(
                    action: "add",
                    oldText: nil,
                    content: "Uses an iPhone"
                )
            ]
        )

        XCTAssertEqual(["Uses an iPhone"], snapshot.entries)
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

    private func httpResponse(
        for request: URLRequest,
        status: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private func assertCompanionSessionConfiguration(
        _ session: URLSession,
        maximumConnectionsPerHost: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let configuration = session.configuration
        XCTAssertNil(
            configuration.httpCookieStorage,
            file: file,
            line: line
        )
        XCTAssertEqual(
            .never,
            configuration.httpCookieAcceptPolicy,
            file: file,
            line: line
        )
        XCTAssertFalse(
            configuration.httpShouldSetCookies,
            file: file,
            line: line
        )
        XCTAssertNil(configuration.urlCache, file: file, line: line)
        XCTAssertEqual(
            .reloadIgnoringLocalCacheData,
            configuration.requestCachePolicy,
            file: file,
            line: line
        )
        XCTAssertEqual(
            maximumConnectionsPerHost,
            configuration.httpMaximumConnectionsPerHost,
            file: file,
            line: line
        )
        XCTAssertTrue(
            session.delegate is CompanionRedirectBlocker,
            file: file,
            line: line
        )
    }

}

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
