import XCTest
@testable import HermesMobile

final class CompanionDiscoveryTests: APIClientTestCase {
    func testCapabilitiesRequireBothExactCompanionAndGatewaySurfaces() throws {
        let capabilities = try JSONDecoder().decode(
            CompanionCapabilities.self,
            from: Data(
                """
                {
                  "object": "hermex.companion.capabilities",
                  "contract_version": "1",
                  "companion": {
                    "version": "0.1.0",
                    "features": {
                      "skills_proxy": true,
                      "toolsets_proxy": true
                    },
                    "endpoints": {
                      "skills": {"method": "GET", "path": "/v1/skills"},
                      "toolsets": {"method": "GET", "path": "/v1/toolsets"}
                    }
                  },
                  "gateway": {
                    "status": "ok",
                    "capabilities": {
                      "object": "hermes.api_server.capabilities",
                      "platform": "hermes-agent",
                      "features": {"skills_api": true},
                      "endpoints": {
                        "skills": {"method": "GET", "path": "/v1/skills"},
                        "toolsets": {"method": "GET", "path": "/v1/toolsets"}
                      }
                    }
                  }
                }
                """.utf8
            )
        )

        XCTAssertTrue(capabilities.supportsSkillsAndToolsetsDiscovery)

        let missingGatewayFeature = CompanionCapabilities(
            object: capabilities.object,
            contractVersion: capabilities.contractVersion,
            companion: capabilities.companion,
            gateway: CompanionGatewayCapabilityBlock(
                status: "ok",
                capabilities: CompanionGatewayCapabilities(
                    object: "hermes.api_server.capabilities",
                    platform: "hermes-agent",
                    auth: nil,
                    runtime: nil,
                    features: [:],
                    endpoints: capabilities.gateway?.capabilities?.endpoints
                )
            )
        )
        XCTAssertFalse(
            missingGatewayFeature.supportsSkillsAndToolsetsDiscovery
        )
    }

    func testServiceUsesOnlyReadOnlyCompanionRoutesAndToleratesAdditions()
        async throws
    {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        var paths: [String] = []
        let session = makeSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer device-credential"
            )
            XCTAssertNil(apiTestBodyData(from: request))
            paths.append(url.path)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            switch url.path {
            case "/v1/skills":
                return (
                    response,
                    Data(
                        """
                        {
                          "object": "list",
                          "data": [
                            {
                              "name": "ios-review",
                              "description": "Review Swift changes.",
                              "category": "coding",
                              "future": {"ignored": true}
                            },
                            {
                              "description": "Missing stable identity.",
                              "category": null
                            },
                            {
                              "name": "ios-review",
                              "description": "Duplicate identity.",
                              "category": "duplicate"
                            }
                          ],
                          "future": true
                        }
                        """.utf8
                    )
                )
            case "/v1/toolsets":
                return (
                    response,
                    Data(
                        """
                        {
                          "object": "list",
                          "platform": "api_server",
                          "data": [
                            {
                              "name": "file",
                              "label": "File Tools",
                              "description": "Read and write files.",
                              "enabled": true,
                              "configured": false,
                              "tools": ["read_file", 42, "write_file"],
                              "future": "ignored"
                            },
                            {
                              "name": "future",
                              "tools": null
                            }
                          ]
                        }
                        """.utf8
                    )
                )
            default:
                XCTFail("Unexpected WebUI or mutation route: \(url.path)")
                return (response, Data())
            }
        }
        let service = CompanionDiscoveryService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let catalog = try await service.fetch()

        XCTAssertEqual(Set(paths), ["/v1/skills", "/v1/toolsets"])
        XCTAssertEqual(catalog.skills.map(\.id), ["ios-review"])
        XCTAssertEqual(catalog.skills.first?.category, "coding")
        XCTAssertEqual(catalog.toolsets.map(\.id), ["file", "future"])
        XCTAssertEqual(
            catalog.toolsets.first?.tools,
            ["read_file", "write_file"]
        )
        XCTAssertEqual(catalog.toolsets.first?.enabled, true)
        XCTAssertEqual(catalog.toolsets.last?.enabled, nil)
        XCTAssertEqual(catalog.toolsets.last?.configured, nil)
        XCTAssertEqual(catalog.toolsets.last?.tools, nil)
    }

    @MainActor
    func testViewModelSearchesMetadataAndDoesNotProbeWhenUnavailable()
        async
    {
        let catalog = CompanionDiscoveryCatalog(
            skills: [
                CompanionSkill(
                    name: "ios-review",
                    description: "Review Swift changes.",
                    category: "coding"
                ),
                CompanionSkill(
                    name: "research",
                    description: "Find primary sources.",
                    category: nil
                ),
            ],
            toolsets: [
                CompanionToolset(
                    name: "file",
                    label: "File Tools",
                    description: "Read and write files.",
                    enabled: true,
                    configured: true,
                    tools: ["read_file"]
                )
            ]
        )
        let service = DiscoveryServiceStub(result: .success(catalog))
        let viewModel = CompanionDiscoveryViewModel(
            service: service,
            isSupported: true
        )

        await viewModel.load()

        XCTAssertEqual(
            viewModel.matchingSkills(searchText: "swift").map(\.id),
            ["ios-review"]
        )
        XCTAssertEqual(
            viewModel.matchingToolsets(searchText: "read_file").map(\.id),
            ["file"]
        )
        let supportedFetchCount = await service.fetchCount
        XCTAssertEqual(supportedFetchCount, 1)

        let unavailable = CompanionDiscoveryViewModel(
            service: service,
            isSupported: false
        )
        await unavailable.load()
        XCTAssertTrue(unavailable.skills.isEmpty)
        XCTAssertNotNil(unavailable.unavailableMessage)
        let unavailableFetchCount = await service.fetchCount
        XCTAssertEqual(unavailableFetchCount, 1)
    }

    @MainActor
    func testRefreshFailureKeepsCatalogAndSurfacesError() async {
        let catalog = CompanionDiscoveryCatalog(
            skills: [
                CompanionSkill(
                    name: "research",
                    description: "Find primary sources.",
                    category: nil
                )
            ],
            toolsets: []
        )
        let service = SequencedDiscoveryServiceStub(
            results: [
                .success(catalog),
                .failure(.gatewayUnavailable),
            ]
        )
        let viewModel = CompanionDiscoveryViewModel(
            service: service,
            isSupported: true
        )

        await viewModel.load()
        await viewModel.load()

        XCTAssertEqual(viewModel.skills.map(\.id), ["research"])
        XCTAssertEqual(
            viewModel.errorMessage,
            CompanionDiscoveryServiceError.gatewayUnavailable
                .localizedDescription
        )
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
}

private actor DiscoveryServiceStub: CompanionDiscoveryServing {
    private let result: Result<
        CompanionDiscoveryCatalog,
        CompanionDiscoveryServiceError
    >
    private(set) var fetchCount = 0

    init(
        result: Result<
            CompanionDiscoveryCatalog,
            CompanionDiscoveryServiceError
        >
    ) {
        self.result = result
    }

    func fetch() async throws -> CompanionDiscoveryCatalog {
        fetchCount += 1
        return try result.get()
    }
}

private actor SequencedDiscoveryServiceStub: CompanionDiscoveryServing {
    private var results: [
        Result<CompanionDiscoveryCatalog, CompanionDiscoveryServiceError>
    ]

    init(
        results: [
            Result<CompanionDiscoveryCatalog, CompanionDiscoveryServiceError>
        ]
    ) {
        self.results = results
    }

    func fetch() async throws -> CompanionDiscoveryCatalog {
        guard !results.isEmpty else {
            throw CompanionDiscoveryServiceError.unexpectedResponse
        }
        return try results.removeFirst().get()
    }
}
