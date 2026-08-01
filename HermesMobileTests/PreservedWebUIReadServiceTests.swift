import XCTest
@testable import HermesMobile

final class PreservedWebUIReadServiceTests: CompanionHTTPTestCase {
    func testProfilesUsesVerifiedRouteAndPreservesBuiltInHeaderPrecedence() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/profiles")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Accept"),
                "application/json"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Owner-Token"),
                "owner-secret"
            )
            return apiTestJSONResponse(
                """
                {
                  "profiles": [{
                    "name": "default",
                    "is_default": true,
                    "gateway_running": true,
                    "future_field": "ignored"
                  }],
                  "active": "default",
                  "single_profile_mode": false,
                  "future_top_level": true
                }
                """,
                for: request
            )
        }

        let response = try await makeService(
            baseURL: baseURL,
            headers: [
                CustomHeader(name: "Accept", value: "text/plain"),
                CustomHeader(name: "X-Owner-Token", value: "owner-secret"),
            ]
        ).profiles()

        XCTAssertEqual(response.active, "default")
        XCTAssertEqual(response.singleProfileMode, false)
        XCTAssertEqual(response.profiles?.first?.name, "default")
        XCTAssertEqual(response.profiles?.first?.isDefault, true)
        XCTAssertEqual(response.profiles?.first?.gatewayRunning, true)
    }

    func testStreamStatusEncodesQueryAndTolerantlyDecodesJournal() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            let components = try XCTUnwrap(
                URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )
            )
            XCTAssertEqual(
                components.queryItems,
                [URLQueryItem(name: "stream_id", value: "run id/+?")]
            )
            return apiTestJSONResponse(
                """
                {
                  "active": true,
                  "stream_id": "run id/+?",
                  "replay_available": true,
                  "journal": {
                    "terminal": false,
                    "terminal_state": "running",
                    "future_field": 42
                  }
                }
                """,
                for: request
            )
        }

        let response = try await makeService(baseURL: baseURL)
            .chatStreamStatus(streamID: "run id/+?")

        XCTAssertEqual(response.active, true)
        XCTAssertEqual(response.streamId, "run id/+?")
        XCTAssertEqual(response.replayAvailable, true)
        XCTAssertEqual(response.journal?.terminal, false)
        XCTAssertEqual(response.journal?.terminalState, "running")
    }

    func testSessionConfigurationKeepsSharedCookiesEnabled() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never

        let configured = PreservedWebUIReadService
            .configuredSessionConfiguration(from: configuration)

        XCTAssertTrue(configured === configuration)
        XCTAssertTrue(configured.httpCookieStorage === HTTPCookieStorage.shared)
        XCTAssertTrue(configured.httpShouldSetCookies)
        XCTAssertEqual(configured.httpCookieAcceptPolicy, .always)
    }

    func testRedirectGuardKeepsHeadersForSameOriginIncludingDefaultPort() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let redirectGuard = PreservedWebUIRedirectGuard(
            baseURL: baseURL,
            customHeaderProvider: {
                [CustomHeader(name: "X-Owner-Token", value: "owner-secret")]
            }
        )
        var request = URLRequest(
            url: try XCTUnwrap(
                URL(string: "https://gateway.example.test:443/redirected")
            )
        )
        request.setValue("owner-secret", forHTTPHeaderField: "X-Owner-Token")

        let sanitized = redirectGuard.sanitizedRedirectRequest(request)

        XCTAssertEqual(
            sanitized.value(forHTTPHeaderField: "X-Owner-Token"),
            "owner-secret"
        )
    }

    func testRedirectGuardStripsConfiguredSecretsAcrossOrigins() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let redirectGuard = PreservedWebUIRedirectGuard(
            baseURL: baseURL,
            customHeaderProvider: {
                [
                    CustomHeader(name: "X-Owner-Token", value: "owner-secret"),
                    CustomHeader(name: "Authorization", value: "Bearer secret"),
                    CustomHeader(name: "Bad Header", value: "ignored"),
                ]
            }
        )
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://redirect.example.test/path"))
        )
        request.setValue("owner-secret", forHTTPHeaderField: "X-Owner-Token")
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let sanitized = redirectGuard.sanitizedRedirectRequest(request)

        XCTAssertNil(sanitized.value(forHTTPHeaderField: "X-Owner-Token"))
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            sanitized.value(forHTTPHeaderField: "Accept"),
            "application/json"
        )
    }

    func testCredentialReaderPrefersScopedHeadersWithoutReadingGlobalValue() throws {
        let server = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let scoped = try XCTUnwrap(
            [CustomHeader(name: "X-Scope", value: "scoped")]
                .encodedForStorage()
        )

        let headers = PreservedWebUICredentialReader.customHeaders(
            for: server,
            loadScoped: { scope in
                XCTAssertEqual(scope, server.absoluteString)
                return scoped
            },
            loadGlobal: {
                XCTFail("Global headers must not be read when scoped data exists")
                return nil
            }
        )

        XCTAssertEqual(headers, [CustomHeader(name: "X-Scope", value: "scoped")])
    }

    func testCredentialReaderFallsBackWhenScopedValueIsMissing() throws {
        let server = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let global = try XCTUnwrap(
            [CustomHeader(name: "X-Global", value: "fallback")]
                .encodedForStorage()
        )

        let headers = PreservedWebUICredentialReader.customHeaders(
            for: server,
            loadScoped: { _ in nil },
            loadGlobal: { global }
        )

        XCTAssertEqual(
            headers,
            [CustomHeader(name: "X-Global", value: "fallback")]
        )
    }

    func testCredentialReaderExplicitEmptyScopedValueSuppressesGlobalFallback() throws {
        let server = try XCTUnwrap(URL(string: "https://gateway.example.test"))

        let headers = PreservedWebUICredentialReader.customHeaders(
            for: server,
            loadScoped: { _ in "" },
            loadGlobal: {
                XCTFail("An explicit scoped value must suppress legacy fallback")
                return nil
            }
        )

        XCTAssertTrue(headers.isEmpty)
    }

    func testCredentialReaderScopedReadErrorFallsBackAndGlobalErrorIsEmpty() throws {
        let server = try XCTUnwrap(URL(string: "https://gateway.example.test"))
        let global = try XCTUnwrap(
            [CustomHeader(name: "X-Global", value: "fallback")]
                .encodedForStorage()
        )

        let fallback = PreservedWebUICredentialReader.customHeaders(
            for: server,
            loadScoped: { _ in throw CredentialReadError.unavailable },
            loadGlobal: { global }
        )
        let unavailable = PreservedWebUICredentialReader.customHeaders(
            for: server,
            loadScoped: { _ in throw CredentialReadError.unavailable },
            loadGlobal: { throw CredentialReadError.unavailable }
        )

        XCTAssertEqual(
            fallback,
            [CustomHeader(name: "X-Global", value: "fallback")]
        )
        XCTAssertTrue(unavailable.isEmpty)
    }

    private func makeService(
        baseURL: URL,
        headers: [CustomHeader] = []
    ) -> PreservedWebUIReadService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return PreservedWebUIReadService(
            baseURL: baseURL,
            sessionConfiguration: configuration,
            customHeaderProvider: { headers }
        )
    }
}

private enum CredentialReadError: Error {
    case unavailable
}
