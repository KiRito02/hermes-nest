import XCTest
@testable import HermesMobile

final class SessionRepositoryTests: APIClientTestCase {
    func testListUsesCompanionCredentialAndTolerantlyMapsGatewaySessions() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("device-credential", forKey: .companionDeviceCredential)
        let session = makeSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual("/api/sessions", url.path)
            XCTAssertEqual(
                [
                    URLQueryItem(name: "limit", value: "25"),
                    URLQueryItem(name: "offset", value: "50"),
                    URLQueryItem(name: "source", value: "api_server"),
                    URLQueryItem(name: "include_children", value: "true"),
                ],
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            )
            XCTAssertEqual("GET", request.httpMethod)
            XCTAssertEqual(
                "Bearer device-credential",
                request.value(forHTTPHeaderField: "Authorization")
            )
            XCTAssertNil(request.value(forHTTPHeaderField: "API_SERVER_KEY"))
            XCTAssertEqual(
                "application/json",
                request.value(forHTTPHeaderField: "Accept")
            )

            return apiTestJSONResponse(
                """
                {
                  "object": "list",
                  "data": [
                    {
                      "id": "session-1",
                      "title": "Direct session",
                      "source": "api_server",
                      "model": "test-model",
                      "message_count": 3,
                      "input_tokens": 20,
                      "output_tokens": 10,
                      "estimated_cost_usd": 0.012,
                      "started_at": 1721000000.0,
                      "last_active": 1721000100.0,
                      "parent_session_id": null,
                      "future_session_field": {"ignored": true}
                    }
                  ],
                  "limit": 25,
                  "offset": 50,
                  "has_more": true,
                  "future_page_field": "ignored"
                }
                """,
                for: request
            )
        }
        let repository = LiveSessionRepository(
            companionURL: try XCTUnwrap(URL(string: "https://companion.example.test")),
            keychain: keychain,
            session: session
        )

        let page = try await repository.listSessions(
            SessionListQuery(
                limit: 25,
                offset: 50,
                source: "api_server",
                includeChildren: true
            )
        )

        XCTAssertEqual(25, page.limit)
        XCTAssertEqual(50, page.offset)
        XCTAssertEqual(true, page.hasMore)
        XCTAssertEqual(1, page.sessions.count)
        XCTAssertEqual("session-1", page.sessions[0].sessionId)
        XCTAssertEqual("Direct session", page.sessions[0].title)
        XCTAssertEqual("api_server", page.sessions[0].sessionSource)
        XCTAssertEqual(3, page.sessions[0].messageCount)
        XCTAssertEqual(1_721_000_000, page.sessions[0].createdAt)
        XCTAssertEqual(1_721_000_100, page.sessions[0].lastMessageAt)
        XCTAssertEqual(true, page.sessions[0].isSessionReadOnly)
    }

    func testCompanionErrorCodesRemainDistinct() async throws {
        let scenarios: [(Int, String, SessionRepositoryError)] = [
            (401, "device_credential_invalid", .invalidDeviceCredential),
            (502, "gateway_unauthorized", .gatewayUnauthorized),
            (503, "gateway_unavailable", .gatewayUnavailable),
            (502, "gateway_incompatible", .gatewayIncompatible),
            (502, "gateway_malformed_response", .gatewayMalformedResponse),
            (502, "gateway_response_too_large", .gatewayResponseTooLarge),
            (504, "gateway_timeout", .gatewayTimeout),
            (503, "gateway_transport_failure", .gatewayTransportFailure),
        ]

        for (status, code, expectedError) in scenarios {
            let keychain = InMemoryKeychainStore()
            try keychain.save("device-credential", forKey: .companionDeviceCredential)
            let session = makeSession { request in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: status,
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
                            "code": "\(code)",
                            "message": "Bounded Companion message"
                          }
                        }
                        """.utf8
                    )
                )
            }
            let repository = LiveSessionRepository(
                companionURL: try XCTUnwrap(
                    URL(string: "https://companion.example.test")
                ),
                keychain: keychain,
                session: session
            )

            do {
                _ = try await repository.listSessions(SessionListQuery())
                XCTFail("Expected \(expectedError) for \(code)")
            } catch let error as SessionRepositoryError {
                XCTAssertEqual(expectedError, error)
            }
        }
    }

    func testInvalidQueryIsRejectedBeforeNetworkOrCredentialLookup() async throws {
        let repository = LiveSessionRepository(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: InMemoryKeychainStore(),
            session: makeSession { request in
                XCTFail("Unexpected request to \(String(describing: request.url))")
                throw URLError(.badURL)
            }
        )

        do {
            _ = try await repository.listSessions(
                SessionListQuery(limit: 201)
            )
            XCTFail("Expected invalid-query error")
        } catch let error as SessionRepositoryError {
            XCTAssertEqual(.invalidQuery, error)
        }
    }

    @MainActor
    func testViewModelPagesWithoutDuplicatingStableSessionIDs() async throws {
        let first = SessionSummary(
            sessionId: "session-1",
            title: "First",
            messageCount: 1,
            lastMessageAt: 200,
            readOnly: true,
            isReadOnly: true
        )
        let second = SessionSummary(
            sessionId: "session-2",
            title: "Second",
            messageCount: 1,
            lastMessageAt: 100,
            readOnly: true,
            isReadOnly: true
        )
        let repository = StubSessionRepository(
            pages: [
                SessionPage(
                    sessions: [first],
                    limit: 1,
                    offset: 0,
                    hasMore: true
                ),
                SessionPage(
                    sessions: [first, second],
                    limit: 1,
                    offset: 1,
                    hasMore: false
                ),
            ]
        )
        let viewModel = CompanionSessionListViewModel(
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            )
        )

        await viewModel.loadInitial()
        await viewModel.loadNextPageIfNeeded()

        XCTAssertEqual(["session-1", "session-2"], viewModel.sessions.compactMap(\.sessionId))
        XCTAssertFalse(viewModel.hasMore)
        let queries = await repository.recordedQueries
        XCTAssertEqual([0, 1], queries.compactMap(\.offset))
    }
}

private actor StubSessionRepository: SessionRepository {
    private var pages: [SessionPage]
    private(set) var recordedQueries: [SessionListQuery] = []

    init(pages: [SessionPage]) {
        self.pages = pages
    }

    func listSessions(_ query: SessionListQuery) async throws -> SessionPage {
        recordedQueries.append(query)
        guard !pages.isEmpty else {
            throw SessionRepositoryError.unexpectedResponse
        }
        return pages.removeFirst()
    }
}
