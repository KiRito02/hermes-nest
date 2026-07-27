import XCTest
@testable import HermesMobile

final class SessionRepositoryTests: CompanionHTTPTestCase {
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
        XCTAssertEqual(false, page.sessions[0].isSessionReadOnly)
    }

    func testCompanionErrorCodesRemainDistinct() async throws {
        let scenarios: [(Int, String, SessionRepositoryError)] = [
            (401, "device_credential_invalid", .invalidDeviceCredential),
            (403, "device_revoked", .deviceRevoked),
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

    func testSuccessRequiresJSONMediaTypeAndCompletePaginationShape() async throws {
        let scenarios: [([String: String], String)] = [
            (
                ["Content-Type": "text/html"],
                """
                {"object":"list","data":[],"limit":50,"offset":0,"has_more":false}
                """
            ),
            (
                ["Content-Type": "application/json"],
                """
                {"object":"list","data":[],"limit":50,"offset":0}
                """
            ),
            (
                ["Content-Type": "application/json"],
                """
                {"object":"list","data":[],"limit":50,"offset":0,"has_more":"false"}
                """
            ),
        ]

        for (headers, body) in scenarios {
            let keychain = InMemoryKeychainStore()
            try keychain.save("device-credential", forKey: .companionDeviceCredential)
            let session = makeSession { request in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: headers
                    )
                )
                return (response, Data(body.utf8))
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
                XCTFail("Expected unexpected-response error")
            } catch let error as SessionRepositoryError {
                XCTAssertEqual(.unexpectedResponse, error)
            }
        }
    }

    func testLifecycleUsesExactGatewayCompatibleMethodsAndMapsLineage() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("device-credential", forKey: .companionDeviceCredential)
        var observed: [(String, String, [String: Any]?)] = []
        let session = makeSession { request in
            let url = try XCTUnwrap(request.url)
            let body = try apiTestBodyData(from: request).map {
                try XCTUnwrap(
                    JSONSerialization.jsonObject(with: $0) as? [String: Any]
                )
            }
            observed.append((request.httpMethod ?? "", url.path, body))
            XCTAssertEqual(
                "Bearer device-credential",
                request.value(forHTTPHeaderField: "Authorization")
            )

            switch (request.httpMethod, url.path) {
            case ("POST", "/api/sessions"):
                XCTAssertEqual("Mobile chat", body?["title"] as? String)
                return sessionTestJSONResponse(
                    """
                    {
                      "object": "hermes.session",
                      "session": {
                        "id": "session-1",
                        "source": "ios",
                        "title": "Mobile chat",
                        "future_field": true
                      }
                    }
                    """,
                    statusCode: 201,
                    for: request
                )
            case ("GET", "/api/sessions/session-1"):
                return apiTestJSONResponse(
                    """
                    {
                      "object": "hermes.session",
                      "session": {
                        "id": "session-1",
                        "source": "ios",
                        "title": "Mobile chat"
                      }
                    }
                    """,
                    for: request
                )
            case ("PATCH", "/api/sessions/session-1"):
                XCTAssertEqual("Renamed", body?["title"] as? String)
                return apiTestJSONResponse(
                    """
                    {
                      "object": "hermes.session",
                      "session": {
                        "id": "session-1",
                        "source": "ios",
                        "title": "Renamed"
                      }
                    }
                    """,
                    for: request
                )
            case ("POST", "/api/sessions/session-1/fork"):
                XCTAssertEqual("Alternative", body?["title"] as? String)
                return sessionTestJSONResponse(
                    """
                    {
                      "object": "hermes.session",
                      "session": {
                        "id": "session-fork",
                        "source": "api_server",
                        "title": "Alternative",
                        "parent_session_id": "session-1"
                      }
                    }
                    """,
                    statusCode: 201,
                    for: request
                )
            case ("DELETE", "/api/sessions/session-1"):
                return apiTestJSONResponse(
                    """
                    {
                      "object": "hermes.session.deleted",
                      "id": "session-1",
                      "deleted": true
                    }
                    """,
                    for: request
                )
            default:
                XCTFail("Unexpected lifecycle request: \(request)")
                throw URLError(.badURL)
            }
        }
        let repository = LiveSessionRepository(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let created = try await repository.createSession(
            SessionCreateRequest(title: "Mobile chat", source: "ios")
        )
        let detail = try await repository.session(id: "session-1")
        let updated = try await repository.updateSession(
            id: "session-1",
            request: SessionUpdateRequest(title: "Renamed")
        )
        let fork = try await repository.forkSession(
            id: "session-1",
            request: SessionForkRequest(title: "Alternative")
        )
        let deleted = try await repository.deleteSession(id: "session-1")

        XCTAssertEqual("session-1", created.sessionId)
        XCTAssertEqual("ios", detail.sessionSource)
        XCTAssertEqual("Renamed", updated.title)
        XCTAssertEqual("session-fork", fork.sessionId)
        XCTAssertEqual("api_server", fork.sessionSource)
        XCTAssertEqual("session-1", fork.parentSessionId)
        XCTAssertTrue(deleted)
        XCTAssertEqual(
            [
                "POST /api/sessions",
                "GET /api/sessions/session-1",
                "PATCH /api/sessions/session-1",
                "POST /api/sessions/session-1/fork",
                "DELETE /api/sessions/session-1",
            ],
            observed.map { "\($0.0) \($0.1)" }
        )
    }

    func testMessageHistoryTolerantlyMapsStableIDsAndWireOrdering() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("device-credential", forKey: .companionDeviceCredential)
        let session = makeSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual("/api/sessions/session-1/messages", url.path)
            XCTAssertNil(url.query)
            XCTAssertEqual("GET", request.httpMethod)
            return apiTestJSONResponse(
                """
                {
                  "object": "list",
                  "session_id": "session-1",
                  "data": [
                    {
                      "id": 41,
                      "session_id": "session-1",
                      "role": "user",
                      "content": "First",
                      "timestamp": 1721000000.0,
                      "future_field": true
                    },
                    {
                      "id": "42",
                      "session_id": "session-1",
                      "role": "assistant",
                      "content": "Second",
                      "tool_name": "terminal",
                      "tool_call_id": "call-1",
                      "tool_calls": [{"id": "call-1"}],
                      "reasoning_content": "Checked",
                      "timestamp": "1721000001"
                    }
                  ],
                  "future_page_field": "ignored"
                }
                """,
                for: request
            )
        }
        let repository = LiveSessionRepository(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let history = try await repository.messageHistory(id: "session-1")

        XCTAssertEqual("session-1", history.sessionID)
        XCTAssertEqual(["First", "Second"], history.messages.compactMap(\.content))
        XCTAssertEqual(
            ["session-1:message:41", "session-1:message:42"],
            history.messages.map(\.id)
        )
        XCTAssertEqual("terminal", history.messages[1].name)
        XCTAssertEqual("call-1", history.messages[1].toolCallId)
        XCTAssertEqual("Checked", history.messages[1].reasoning)
        XCTAssertEqual(1_721_000_001, history.messages[1].timestamp)
        XCTAssertEqual(1, history.messages[1].toolCalls?.count)
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
        XCTAssertEqual([true, true], queries.compactMap(\.includeChildren))
    }

    @MainActor
    func testHistoryViewModelPagesFullGatewayHistoryLocally() async throws {
        let summary = SessionSummary(
            sessionId: "session-1",
            title: "History"
        )
        let messages = (0..<120).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Message \(index)",
                timestamp: Double(index),
                messageId: "session-1:message:\(index)"
            )
        }
        let repository = HistoryStubSessionRepository(
            detail: summary,
            history: SessionHistory(
                sessionID: "session-1",
                messages: messages
            )
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: summary,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            pageSize: 50
        )

        await viewModel.load()
        XCTAssertEqual("Message 70", viewModel.visibleMessages.first?.content)
        XCTAssertEqual(50, viewModel.visibleMessages.count)
        XCTAssertTrue(viewModel.hasOlderMessages)

        viewModel.loadOlderMessages()
        XCTAssertEqual("Message 20", viewModel.visibleMessages.first?.content)
        XCTAssertEqual(100, viewModel.visibleMessages.count)

        viewModel.loadOlderMessages()
        XCTAssertEqual("Message 0", viewModel.visibleMessages.first?.content)
        XCTAssertEqual(120, viewModel.visibleMessages.count)
        XCTAssertFalse(viewModel.hasOlderMessages)
    }

    @MainActor
    func testFailedRemoteDeleteKeepsSessionInList() async throws {
        let session = SessionSummary(
            sessionId: "session-1",
            title: "Keep on failure"
        )
        let repository = StubSessionRepository(
            pages: [
                SessionPage(
                    sessions: [session],
                    limit: 50,
                    offset: 0,
                    hasMore: false
                )
            ]
        )
        let viewModel = CompanionSessionListViewModel(
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            )
        )

        await viewModel.loadInitial()
        let deleted = await viewModel.deleteSession(session)

        XCTAssertFalse(deleted)
        XCTAssertEqual(["session-1"], viewModel.sessions.compactMap(\.sessionId))
        XCTAssertNotNil(viewModel.mutationErrorMessage)
    }

    @MainActor
    func testSuccessfulDeleteRestartsAuthoritativePaginationAtZero() async throws {
        let first = SessionSummary(sessionId: "session-1", title: "First")
        let second = SessionSummary(sessionId: "session-2", title: "Second")
        let third = SessionSummary(sessionId: "session-3", title: "Third")
        let repository = MutationStubSessionRepository(
            pages: [
                SessionPage(
                    sessions: [first, second],
                    limit: 2,
                    offset: 0,
                    hasMore: true
                ),
                SessionPage(
                    sessions: [second, third],
                    limit: 2,
                    offset: 0,
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
        let deleted = await viewModel.deleteSession(first)

        XCTAssertTrue(deleted)
        XCTAssertEqual(
            ["session-2", "session-3"],
            viewModel.sessions.compactMap(\.sessionId)
        )
        let recordedOffsets = await repository.recordedOffsets
        XCTAssertEqual([0, 0], recordedOffsets)
    }

    @MainActor
    func testResolvedHistoryIdentityOwnsSubsequentLifecycleActions() async throws {
        let parent = SessionSummary(
            sessionId: "parent-session",
            title: "Compressed parent"
        )
        let tip = SessionSummary(
            sessionId: "tip-session",
            title: "Compression tip",
            parentSessionId: "parent-session"
        )
        let repository = ResolvedHistoryStubSessionRepository(
            detail: tip,
            history: SessionHistory(
                sessionID: "tip-session",
                messages: [
                    ChatMessage(
                        role: "assistant",
                        content: "Resolved transcript",
                        timestamp: 1,
                        messageId: "tip-session:message:1"
                    )
                ]
            )
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: parent,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            )
        )

        await viewModel.load()
        let renamed = await viewModel.rename(to: "Renamed tip")
        let recordedDetailIDs = await repository.recordedDetailIDs
        let recordedUpdateIDs = await repository.recordedUpdateIDs

        XCTAssertTrue(renamed)
        XCTAssertEqual("tip-session", viewModel.session.sessionId)
        XCTAssertEqual(["tip-session"], recordedDetailIDs)
        XCTAssertEqual(["tip-session"], recordedUpdateIDs)
    }

    private func makeSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
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

    func createSession(_ request: SessionCreateRequest) async throws -> SessionSummary {
        throw SessionRepositoryError.unexpectedResponse
    }

    func session(id: String) async throws -> SessionSummary {
        throw SessionRepositoryError.unexpectedResponse
    }

    func updateSession(
        id: String,
        request: SessionUpdateRequest
    ) async throws -> SessionSummary {
        throw SessionRepositoryError.unexpectedResponse
    }

    func deleteSession(id: String) async throws -> Bool {
        throw SessionRepositoryError.unexpectedResponse
    }

    func forkSession(
        id: String,
        request: SessionForkRequest
    ) async throws -> SessionSummary {
        throw SessionRepositoryError.unexpectedResponse
    }

    func messageHistory(id: String) async throws -> SessionHistory {
        throw SessionRepositoryError.unexpectedResponse
    }
}

private actor HistoryStubSessionRepository: SessionRepository {
    let detail: SessionSummary
    let history: SessionHistory

    init(detail: SessionSummary, history: SessionHistory) {
        self.detail = detail
        self.history = history
    }

    func listSessions(_ query: SessionListQuery) async throws -> SessionPage {
        SessionPage(sessions: [detail], limit: 50, offset: 0, hasMore: false)
    }

    func createSession(_ request: SessionCreateRequest) async throws -> SessionSummary {
        detail
    }

    func session(id: String) async throws -> SessionSummary {
        detail
    }

    func updateSession(
        id: String,
        request: SessionUpdateRequest
    ) async throws -> SessionSummary {
        detail
    }

    func deleteSession(id: String) async throws -> Bool {
        true
    }

    func forkSession(
        id: String,
        request: SessionForkRequest
    ) async throws -> SessionSummary {
        detail
    }

    func messageHistory(id: String) async throws -> SessionHistory {
        history
    }
}

private actor MutationStubSessionRepository: SessionRepository {
    private var pages: [SessionPage]
    private(set) var recordedOffsets: [Int] = []

    init(pages: [SessionPage]) {
        self.pages = pages
    }

    func listSessions(_ query: SessionListQuery) async throws -> SessionPage {
        recordedOffsets.append(query.offset ?? -1)
        guard !pages.isEmpty else {
            throw SessionRepositoryError.unexpectedResponse
        }
        return pages.removeFirst()
    }

    func createSession(_ request: SessionCreateRequest) async throws -> SessionSummary {
        throw SessionRepositoryError.unexpectedResponse
    }

    func session(id: String) async throws -> SessionSummary {
        throw SessionRepositoryError.unexpectedResponse
    }

    func updateSession(
        id: String,
        request: SessionUpdateRequest
    ) async throws -> SessionSummary {
        throw SessionRepositoryError.unexpectedResponse
    }

    func deleteSession(id: String) async throws -> Bool {
        true
    }

    func forkSession(
        id: String,
        request: SessionForkRequest
    ) async throws -> SessionSummary {
        throw SessionRepositoryError.unexpectedResponse
    }

    func messageHistory(id: String) async throws -> SessionHistory {
        throw SessionRepositoryError.unexpectedResponse
    }
}

private actor ResolvedHistoryStubSessionRepository: SessionRepository {
    let detail: SessionSummary
    let history: SessionHistory
    private(set) var recordedDetailIDs: [String] = []
    private(set) var recordedUpdateIDs: [String] = []

    init(detail: SessionSummary, history: SessionHistory) {
        self.detail = detail
        self.history = history
    }

    func listSessions(_ query: SessionListQuery) async throws -> SessionPage {
        throw SessionRepositoryError.unexpectedResponse
    }

    func createSession(_ request: SessionCreateRequest) async throws -> SessionSummary {
        throw SessionRepositoryError.unexpectedResponse
    }

    func session(id: String) async throws -> SessionSummary {
        recordedDetailIDs.append(id)
        return detail
    }

    func updateSession(
        id: String,
        request: SessionUpdateRequest
    ) async throws -> SessionSummary {
        recordedUpdateIDs.append(id)
        return detail
    }

    func deleteSession(id: String) async throws -> Bool {
        true
    }

    func forkSession(
        id: String,
        request: SessionForkRequest
    ) async throws -> SessionSummary {
        detail
    }

    func messageHistory(id: String) async throws -> SessionHistory {
        history
    }
}

private func sessionTestJSONResponse(
    _ json: String,
    statusCode: Int,
    for request: URLRequest
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(json.utf8))
}
