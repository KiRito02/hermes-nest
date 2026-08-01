import XCTest
import SwiftData
@testable import HermesMobile

final class ConversationRunServiceTests: CompanionHTTPTestCase {
    override func tearDown() {
        RunJSONURLProtocol.reset()
        RunSSEURLProtocol.reset()
        super.tearDown()
    }

    func testStartUsesDeviceCredentialAndAuthoritativeHistory() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            XCTAssertEqual("/v1/runs", request.url?.path)
            XCTAssertEqual("POST", request.httpMethod)
            XCTAssertEqual(
                "Bearer device-credential",
                request.value(forHTTPHeaderField: "Authorization")
            )
            XCTAssertNil(request.value(forHTTPHeaderField: "API_SERVER_KEY"))
            XCTAssertEqual(
                "application/json",
                request.value(forHTTPHeaderField: "Content-Type")
            )

            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual("Continue", body["input"] as? String)
            XCTAssertEqual("session-1", body["session_id"] as? String)
            let history = try XCTUnwrap(
                body["conversation_history"] as? [[String: Any]]
            )
            XCTAssertEqual("user", history[0]["role"] as? String)
            XCTAssertEqual(
                "Earlier question",
                history[0]["content"] as? String
            )
            XCTAssertEqual("assistant", history[1]["role"] as? String)
            XCTAssertEqual(
                "Earlier answer",
                history[1]["content"] as? String
            )

            return self.response(
                status: 202,
                json: """
                {
                  "run_id": "run-1",
                  "status": "started",
                  "future_field": {"ignored": true}
                }
                """,
                request: request
            )
        }
        let service = ConversationRunService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let snapshot = try await service.start(
            ConversationRunStartRequest(
                input: "Continue",
                sessionID: "session-1",
                conversationHistory: [
                    ChatMessage(
                        role: "user",
                        content: "Earlier question",
                        timestamp: 1,
                        messageId: "m1"
                    ),
                    ChatMessage(
                        role: "assistant",
                        content: "Earlier answer",
                        timestamp: 2,
                        messageId: "m2"
                    ),
                ]
            )
        )

        XCTAssertEqual("run-1", snapshot.runID)
        XCTAssertEqual(.started, snapshot.state)
    }

    func testStartIncludesExactProviderModelAndReasoningOverride() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(
                [
                    "conversation_history",
                    "input",
                    "model",
                    "model_options",
                    "provider",
                    "session_id",
                ],
                body.keys.sorted()
            )
            XCTAssertEqual(
                "anthropic/claude-sonnet-4.6",
                body["model"] as? String
            )
            XCTAssertEqual("openrouter", body["provider"] as? String)
            let options = try XCTUnwrap(
                body["model_options"] as? [String: Any]
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
            return self.response(
                status: 202,
                json: #"{"run_id":"run-1","status":"started"}"#,
                request: request
            )
        }
        let service = ConversationRunService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        _ = try await service.start(
            ConversationRunStartRequest(
                input: "Continue",
                sessionID: "session-1",
                conversationHistory: [],
                selection: CompanionModelSelection(
                    model: "anthropic/claude-sonnet-4.6",
                    provider: "openrouter",
                    reasoningEffort: .high
                )
            )
        )
    }

    func testStartIncludesOnlyCompanionAttachmentIDs() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(
                ["attachment-1", "attachment-2"],
                body["attachment_ids"] as? [String]
            )
            XCTAssertNil(body["attachments"])
            XCTAssertNil(body["file_ids"])
            return self.response(
                status: 202,
                json: """
                {
                  "run_id": "run-attachment",
                  "status": "started"
                }
                """,
                request: request
            )
        }
        let service = ConversationRunService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        _ = try await service.start(
            ConversationRunStartRequest(
                input: "Review these files",
                sessionID: "session-1",
                conversationHistory: [],
                attachmentIDs: ["attachment-1", "attachment-2"]
            )
        )
    }

    func testStatusAndStopKeepLifecycleStatesDistinct() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        var requestCount = 0
        let session = makeSession { request in
            requestCount += 1
            switch requestCount {
            case 1:
                XCTAssertEqual("/v1/runs/run-1", request.url?.path)
                XCTAssertEqual("GET", request.httpMethod)
                return self.response(
                    status: 200,
                    json: """
                    {
                      "object": "hermes.run",
                      "run_id": "run-1",
                      "status": "failed",
                      "session_id": "session-1",
                      "last_event": "run.failed",
                      "error": "Provider unavailable",
                      "created_at": 100,
                      "updated_at": 101,
                      "future_field": true
                    }
                    """,
                    request: request
                )
            default:
                XCTAssertEqual("/v1/runs/run-1/stop", request.url?.path)
                XCTAssertEqual("POST", request.httpMethod)
                return self.response(
                    status: 200,
                    json: """
                    {"run_id":"run-1","status":"stopping"}
                    """,
                    request: request
                )
            }
        }
        let service = ConversationRunService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let failed = try await service.status(runID: "run-1")
        let stopping = try await service.stop(runID: "run-1")

        XCTAssertEqual(.failed, failed.state)
        XCTAssertEqual("session-1", failed.sessionID)
        XCTAssertEqual("Provider unavailable", failed.errorMessage)
        XCTAssertEqual(.stopping, stopping.state)
        XCTAssertNotEqual(.cancelled, stopping.state)
    }

    func testStatusDecodesExactTerminalUsageWithoutInferringContext() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            self.response(
                status: 200,
                json: """
                {
                  "run_id": "run-usage",
                  "status": "completed",
                  "usage": {
                    "input_tokens": 1234,
                    "output_tokens": 56,
                    "total_tokens": 1290,
                    "future_counter": 99
                  }
                }
                """,
                request: request
            )
        }
        let service = ConversationRunService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let snapshot = try await service.status(runID: "run-usage")

        XCTAssertEqual(
            ConversationRunUsage(
                inputTokens: 1_234,
                outputTokens: 56,
                totalTokens: 1_290
            ),
            snapshot.usage
        )
    }

    func testStatusToleratesMissingAndMalformedUsageFields() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        var requestCount = 0
        let session = makeSession { request in
            requestCount += 1
            let usage = requestCount == 1
                ? #""usage":{"input_tokens":"42","output_tokens":{},"total_tokens":-1},"#
                : #""usage":"future-shape","#
            return self.response(
                status: 200,
                json: """
                {
                  "run_id": "run-usage",
                  "status": "completed",
                  \(usage)
                  "future_field": true
                }
                """,
                request: request
            )
        }
        let service = ConversationRunService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let partiallyDecoded = try await service.status(runID: "run-usage")
        let unknownShape = try await service.status(runID: "run-usage")

        XCTAssertEqual(42, partiallyDecoded.usage?.inputTokens)
        XCTAssertNil(partiallyDecoded.usage?.outputTokens)
        XCTAssertNil(partiallyDecoded.usage?.totalTokens)
        XCTAssertNil(unknownShape.usage)
    }

    func testApprovalPostsCanonicalChoiceToExactExistingRun() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            XCTAssertEqual(
                "/v1/runs/run-1/approval",
                request.url?.path
            )
            XCTAssertEqual("POST", request.httpMethod)
            XCTAssertEqual(
                "Bearer device-credential",
                request.value(forHTTPHeaderField: "Authorization")
            )
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(["choice"], body.keys.sorted())
            XCTAssertEqual("deny", body["choice"] as? String)
            return self.response(
                status: 200,
                json: """
                {
                  "object": "hermes.run.approval_response",
                  "run_id": "run-1",
                  "choice": "deny",
                  "resolved": 1,
                  "future_field": true
                }
                """,
                request: request
            )
        }
        let service = ConversationRunService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let response = try await service.respondToApproval(
            runID: "run-1",
            choice: .deny
        )

        XCTAssertEqual("run-1", response.runID)
        XCTAssertEqual(.deny, response.choice)
        XCTAssertEqual(1, response.resolved)
    }

    func testExpiredApprovalMapsToReconciliationError() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let session = makeSession { request in
            self.response(
                status: 409,
                json: """
                {
                  "error": {
                    "code": "approval_not_pending",
                    "message": "No approval is pending for this run."
                  }
                }
                """,
                request: request
            )
        }
        let service = ConversationRunService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        do {
            _ = try await service.respondToApproval(
                runID: "run-1",
                choice: .once
            )
            XCTFail("Expected an expired approval error")
        } catch {
            XCTAssertEqual(
                .approvalNotPending,
                error as? ConversationRunServiceError
            )
        }
    }

    func testParserKeepsTransportAndJSONEventNamesIndependent() throws {
        var parser = ConversationRunSSEParser()

        XCTAssertEqual(
            [.comment("keepalive")],
            parser.consume(line: ": keepalive")
        )
        XCTAssertEqual([], parser.consume(line: "event: future.transport"))
        XCTAssertEqual(
            [],
            parser.consume(
                line: """
                data: {"event":"message.delta","run_id":"run-1","delta":"Hi"}
                """
            )
        )
        let events = parser.consume(line: "")

        guard case .data(let payload) = try XCTUnwrap(events.first) else {
            XCTFail("Expected a data event")
            return
        }
        XCTAssertEqual("future.transport", payload.transportEvent)
        XCTAssertEqual("message.delta", payload.event)
        XCTAssertEqual("run-1", payload.runID)
        XCTAssertEqual("Hi", payload.delta)

        XCTAssertEqual(
            [],
            parser.consume(line: "event: run.completed")
        )
        XCTAssertEqual(
            [],
            parser.consume(line: #"data: {"run_id":"run-1","output":"Done"}"#)
        )
        guard case .data(let transportOnly) = try XCTUnwrap(
            parser.consume(line: "").first
        ) else {
            XCTFail("Expected transport-only terminal event")
            return
        }
        XCTAssertNil(transportOnly.event)
        XCTAssertEqual("run.completed", transportOnly.semanticEvent)
    }

    func testParserDecodesUsageFromTerminalEventTolerantly() throws {
        var parser = ConversationRunSSEParser()

        XCTAssertEqual(
            [],
            parser.consume(
                line: """
                data: {"event":"run.completed","run_id":"run-1","usage":{"input_tokens":21,"output_tokens":"5","total_tokens":26,"future":true}}
                """
            )
        )
        guard case .data(let payload) = try XCTUnwrap(
            parser.consume(line: "").first
        ) else {
            XCTFail("Expected terminal data event")
            return
        }

        XCTAssertEqual(
            ConversationRunUsage(
                inputTokens: 21,
                outputTokens: 5,
                totalTokens: 26
            ),
            payload.usage
        )
    }

    func testApprovalEventUsesOnlyBoundedVerifiedDisplayFields() throws {
        var parser = ConversationRunSSEParser()
        // Approval request fixture pinned to Hermes Agent 0.19.0 commit
        // 07e97d2f5dc3d2092cfe693ef07b2527a36cd2d8.
        let object: [String: Any] = [
            "event": "approval.request",
            "run_id": "run-1",
            "command": String(repeating: "x", count: 5_000),
            "description": String(repeating: "y", count: 3_000),
            "choices": ["once", "future_choice", "deny", "once"],
            "timestamp": 123.0,
            "pattern_keys": ["sudo with privilege flag"],
            "allow_permanent": true,
            "smart_denied": false,
            "private_path": "/volume/private/approval-state.json",
            "unsupported_payload": ["secret": true],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let line = "data: " + String(decoding: data, as: UTF8.self)
        XCTAssertEqual([], parser.consume(line: line))
        guard
            case .data(let payload) = try XCTUnwrap(
                parser.consume(line: "").first
            ),
            let approval = payload.approvalRequest(
                expectedRunID: "run-1"
            )
        else {
            XCTFail("Expected a verified approval request")
            return
        }

        XCTAssertEqual(
            ConversationApprovalRequest.maximumCommandCharacters,
            approval.commandPreview?.count
        )
        XCTAssertEqual(
            ConversationApprovalRequest.maximumDescriptionCharacters,
            approval.description?.count
        )
        XCTAssertEqual([.deny], approval.choices)
        XCTAssertFalse(approval.contextIsComplete)
        XCTAssertNil(payload.approvalRequest(expectedRunID: "another-run"))
    }

    func testLineDecoderPreservesSSEBlankLinesAndLineEndings() throws {
        var decoder = ConversationRunSSELineDecoder()
        var lines: [String] = []
        let bytes = ": keepalive\r\n\r\ndata: {}\n\nfinal\r".utf8

        for byte in bytes {
            if let line = try decoder.consume(byte: byte) {
                lines.append(line)
            }
        }
        if let finalLine = decoder.finish() {
            lines.append(finalLine)
        }

        XCTAssertEqual(
            [": keepalive", "", "data: {}", "", "final"],
            lines
        )
    }

    func testStreamDeliversDeltaBeforeTerminalAndUsesNoCookies() async throws {
        RunSSEURLProtocol.configure(chunks: [
            .init(
                text: """
                : keepalive

                data: {"event":"message.delta","run_id":"run-1","delta":"First"}
                """ + "\n\n",
                delayNanoseconds: 10_000_000
            ),
            .init(
                text: """
                event: future.transport
                data: {"event":"run.completed","run_id":"run-1","output":"First"}
                """ + "\n\n",
                delayNanoseconds: 250_000_000
            ),
        ])
        defer { RunSSEURLProtocol.reset() }

        let keychain = InMemoryKeychainStore()
        try keychain.save(
            "device-credential",
            forKey: .companionDeviceCredential
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RunSSEURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(
            configuration: configuration,
            delegate: CompanionRedirectBlocker(),
            delegateQueue: nil
        )
        let service = ConversationRunService(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            keychain: keychain,
            session: session
        )

        let stream = try await service.events(runID: "run-1")
        var iterator = stream.makeAsyncIterator()
        let comment = try await iterator.next()
        XCTAssertEqual(.comment("keepalive"), comment)

        guard
            let nextDelta = try await iterator.next(),
            case .data(let delta) = nextDelta
        else {
            XCTFail("Expected live delta")
            return
        }
        XCTAssertEqual("First", delta.delta)

        let request = try XCTUnwrap(RunSSEURLProtocol.capturedRequest())
        XCTAssertEqual("/v1/runs/run-1/events", request.url?.path)
        XCTAssertEqual(
            "Bearer device-credential",
            request.value(forHTTPHeaderField: "Authorization")
        )
        XCTAssertEqual(
            "text/event-stream",
            request.value(forHTTPHeaderField: "Accept")
        )
        XCTAssertGreaterThan(request.timeoutInterval, 24 * 60 * 60)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))

        guard
            let nextTerminal = try await iterator.next(),
            case .data(let terminal) = nextTerminal
        else {
            XCTFail("Expected terminal event")
            return
        }
        XCTAssertEqual("future.transport", terminal.transportEvent)
        XCTAssertEqual("run.completed", terminal.event)
    }

    func testSharedEventSessionDoesNotExpireAnIdleRunStream() {
        let configuration =
            CompanionSessionPool.shared.eventSession.configuration

        XCTAssertGreaterThan(
            configuration.timeoutIntervalForRequest,
            24 * 60 * 60
        )
        XCTAssertGreaterThan(
            configuration.timeoutIntervalForResource,
            24 * 60 * 60
        )
        XCTAssertGreaterThan(
            ConversationRunService.defaultEventConnectTimeoutNanoseconds,
            30_000_000_000,
            "The first-byte guard must outlast the Gateway idle keepalive."
        )
    }

    func testActiveRunStoreSurvivesProcessStoreRecreation() async throws {
        let suiteName = "CompanionActiveRunStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = CompanionActiveRunKey(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            sessionID: "session-1"
        )
        let record = CompanionActiveRunRecord(
            runID: "run-1",
            stopState: .confirmedStopping
        )

        let firstStore = CompanionActiveRunStore(defaults: defaults)
        await firstStore.store(record, for: key)
        let recreatedStore = CompanionActiveRunStore(defaults: defaults)

        let restored = await recreatedStore.activeRun(for: key)
        XCTAssertEqual(record, restored)
    }

    @MainActor
    func testDisconnectPollsSameRunWithoutResubmittingPrompt() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let runService = RunServiceStub(
            eventResult: .disconnect,
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .completed,
                    sessionID: "session-1",
                    lastEvent: "run.completed",
                    output: "Done",
                    errorMessage: nil,
                    usage: ConversationRunUsage(
                        inputTokens: 90,
                        outputTokens: 10,
                        totalTokens: 100
                    )
                )
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()

        let didSend = await viewModel.send("Continue")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.activeRunID == nil }

        let startRequests = await runService.startRequests
        let statusRunIDs = await runService.statusRunIDs
        XCTAssertEqual(1, startRequests.count)
        XCTAssertEqual("session-1", startRequests[0].sessionID)
        XCTAssertEqual(["run-1"], statusRunIDs)
        XCTAssertEqual(.completed, viewModel.runState)
        XCTAssertNil(viewModel.runStatusText)
        XCTAssertEqual(100, viewModel.latestRunUsage?.totalTokens)
    }

    @MainActor
    func testDisconnectRefreshesReasoningWhileSameRunIsStillRunning() async throws {
        let session = try makeSessionSummary()
        let runningHistory = [
            ChatMessage(
                role: "user",
                content: "Compare the models",
                timestamp: 1,
                messageId: "user-1"
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 2,
                messageId: "reasoning-1",
                toolCalls: [
                    .object([
                        "id": .string("tool-1"),
                        "function": .object([
                            "name": .string("web_search"),
                            "arguments": .string(#"{"q":"models"}"#),
                        ]),
                    ])
                ],
                reasoning: "Checking the current model documentation."
            ),
            ChatMessage(
                role: "tool",
                content: "Current model documentation",
                timestamp: 3,
                messageId: "tool-result-1",
                toolCallId: "tool-1"
            ),
        ]
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [2: runningHistory]
        )
        let runService = RunServiceStub(
            eventResult: .disconnect,
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .running,
                    sessionID: "session-1",
                    lastEvent: "reasoning.available",
                    output: nil,
                    errorMessage: nil
                )
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 100_000_000
        )
        await viewModel.load()

        let didSend = await viewModel.send("Compare the models")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.durableReasoningGroups.map { group in group.text } == [
                "Checking the current model documentation."
            ]
        }

        let startRequests = await runService.startRequests
        XCTAssertEqual(1, startRequests.count)
        XCTAssertEqual("run-1", viewModel.activeRunID)
        XCTAssertEqual(
            "web_search",
            viewModel.durableToolCallGroups.first?.toolCalls.first?.name
        )
        XCTAssertEqual(.streaming, viewModel.runState)
        XCTAssertNil(viewModel.runStatusText)
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testRecoveredCurrentTurnProgressKeepsOneStableLivePresentation() async throws {
        let session = try makeSessionSummary()
        let runningHistory = [
            ChatMessage(
                role: "user",
                content: "Inspect the repository",
                timestamp: 1,
                messageId: "user-1"
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 2,
                messageId: "assistant-1",
                toolCalls: [
                    .object([
                        "id": .string("tool-1"),
                        "function": .object([
                            "name": .string("read_file")
                        ]),
                    ])
                ],
                reasoning: "Checking the repository structure."
            ),
        ]
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [2: runningHistory]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .disconnect,
                statuses: [
                    ConversationRunSnapshot(
                        runID: "run-1",
                        state: .running,
                        sessionID: "session-1",
                        lastEvent: "tool.started",
                        output: nil,
                        errorMessage: nil
                    )
                ]
            ),
            reconciliationDelayNanoseconds: 100_000_000
        )
        await viewModel.load()

        let didSend = await viewModel.send("Inspect the repository")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.liveReasoningGroups.map(\.text) == [
                "Checking the repository structure."
            ]
        }

        let assistant = try XCTUnwrap(
            viewModel.allMessages.first { $0.messageId == "assistant-1" }
        )
        XCTAssertTrue(viewModel.durableReasoning(anchoredTo: assistant).isEmpty)
        XCTAssertEqual(
            "read_file",
            viewModel.liveToolActivityGroup?.toolCalls.first?.name
        )
        XCTAssertTrue(viewModel.durableToolActivity(anchoredTo: assistant).isEmpty)
        XCTAssertTrue(viewModel.hasLiveTranscriptContent)
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testActiveRunWithoutEventsStillPresentsThinkingFeedback() async throws {
        let session = try makeSessionSummary()
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: RunHistoryRepositoryStub(session: session),
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .holdOpen,
                statuses: []
            )
        )
        await viewModel.load()

        let didSend = await viewModel.send("Think carefully")

        XCTAssertTrue(didSend)
        XCTAssertTrue(viewModel.showsThinkingIndicator)
        XCTAssertTrue(viewModel.hasLiveTranscriptContent)
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testThinkingFeedbackReturnsWhenVisibleStreamingPauses() async throws {
        let session = try makeSessionSummary()
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: RunHistoryRepositoryStub(session: session),
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .deltasThenWait(
                    ["Partial answer"],
                    5_000_000_000
                ),
                statuses: []
            )
        )
        await viewModel.load()

        let didSend = await viewModel.send("Think, then continue")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.streamingMessage?.content == "Partial answer"
        }
        XCTAssertFalse(viewModel.showsThinkingIndicator)

        await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            viewModel.showsThinkingIndicator
        }
        XCTAssertEqual(
            "Partial answer",
            viewModel.streamingMessage?.content
        )
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testSuccessfulBlankRunningHistoryKeepsNonemptyTranscript() async throws {
        let session = try makeSessionSummary()
        let initialHistory = [
            ChatMessage(
                role: "user",
                content: "Earlier question",
                timestamp: 1,
                messageId: "user-old"
            ),
            ChatMessage(
                role: "assistant",
                content: "Earlier answer",
                timestamp: 2,
                messageId: "assistant-old"
            ),
        ]
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [1: initialHistory, 2: []]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .disconnect,
                statuses: [
                    ConversationRunSnapshot(
                        runID: "run-1",
                        state: .running,
                        sessionID: "session-1",
                        lastEvent: nil,
                        output: nil,
                        errorMessage: nil
                    )
                ]
            ),
            reconciliationDelayNanoseconds: 100_000_000
        )
        await viewModel.load()

        let didSend = await viewModel.send("Continue")
        XCTAssertTrue(didSend)
        let expectedMessages = viewModel.allMessages
        let historyDeadline = ContinuousClock.now + .seconds(1)
        while (await repository.historyCallCount) < 2,
              ContinuousClock.now < historyDeadline {
            await Task.yield()
        }

        let historyCallCount = await repository.historyCallCount
        XCTAssertGreaterThanOrEqual(historyCallCount, 2)
        XCTAssertEqual(expectedMessages, viewModel.allMessages)
        XCTAssertFalse(viewModel.visibleMessages.isEmpty)
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testRecreatedChatRestoresRunWithoutResubmittingPrompt() async throws {
        let session = try makeSessionSummary()
        let activeRunStore = ActiveRunStoreStub()
        let firstViewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: RunHistoryRepositoryStub(session: session),
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .holdOpen,
                statuses: []
            ),
            activeRunStore: activeRunStore
        )
        await firstViewModel.load()
        let didSend = await firstViewModel.send("Keep working")
        XCTAssertTrue(didSend)
        firstViewModel.suspendRunObservation()

        let restoredHistory = [
            ChatMessage(
                role: "user",
                content: "Keep working",
                timestamp: 1,
                messageId: "user-1"
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 2,
                messageId: "reasoning-1",
                reasoning: "Continuing the long-running analysis."
            ),
        ]
        let restoredRepository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [1: restoredHistory]
        )
        let restoredRunService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .running,
                    sessionID: "session-1",
                    lastEvent: "reasoning.available",
                    output: nil,
                    errorMessage: nil
                )
            ]
        )
        let restoredViewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: restoredRepository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: restoredRunService,
            activeRunStore: activeRunStore,
            reconciliationDelayNanoseconds: 100_000_000
        )

        await restoredViewModel.load()
        await restoredViewModel.resumeRunObservation()
        await waitUntil {
            restoredViewModel.activeRunID == "run-1"
                && restoredViewModel.runState == .streaming
        }

        let statusWaitStart = ContinuousClock.now
        while (await restoredRunService.statusRunIDs).isEmpty,
              ContinuousClock.now - statusWaitStart < .seconds(1) {
            await Task.yield()
        }

        let restoredStartRequests = await restoredRunService.startRequests
        let restoredStatusRunIDs = await restoredRunService.statusRunIDs
        XCTAssertTrue(restoredStartRequests.isEmpty)
        XCTAssertEqual(["run-1"], restoredStatusRunIDs)
        XCTAssertFalse(restoredViewModel.canSend)
        restoredViewModel.suspendRunObservation()
    }

    @MainActor
    func testNavigationReusesLiveRunViewModelAndEventStream() async throws {
        let session = try makeSessionSummary()
        let reasoning = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "reasoning.available",
                runID: "run-1",
                delta: nil,
                text: "Still working on the same live run.",
                output: nil,
                error: nil,
                timestamp: 2
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventBatchesThenWait(
                [],
                [reasoning],
                50_000_000,
                5_000_000_000
            ),
            statuses: []
        )
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let registry = CompanionSessionHistoryViewModelRegistry()
        let firstViewModel = registry.viewModel(for: session) {
            CompanionSessionHistoryViewModel(
                session: session,
                repository: RunHistoryRepositoryStub(session: session),
                companionURL: companionURL,
                runService: runService
            )
        }

        await firstViewModel.load()
        let didSend = await firstViewModel.send("Keep the live stream")
        XCTAssertTrue(didSend)

        let reopenedViewModel = registry.viewModel(for: session) {
            XCTFail("Reopening the same chat must reuse its live view model")
            return firstViewModel
        }

        XCTAssertTrue(firstViewModel === reopenedViewModel)
        await waitUntil {
            reopenedViewModel.reasoningText
                == "Still working on the same live run."
        }
        XCTAssertTrue(reopenedViewModel.hasLiveTranscriptContent)
        XCTAssertEqual(.streaming, reopenedViewModel.runState)
        let eventRunIDs = await runService.eventRunIDs
        XCTAssertEqual(["run-1"], eventRunIDs)
        reopenedViewModel.suspendRunObservation()
    }

    @MainActor
    func testRegistryPreservesLiveSessionWhileBrowsingInactiveChats() async throws {
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let registry = CompanionSessionHistoryViewModelRegistry()
        let firstSession = try makeSessionSummary(id: "session-0")
        let firstRunService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: []
        )
        let firstViewModel = registry.viewModel(for: firstSession) {
            CompanionSessionHistoryViewModel(
                session: firstSession,
                repository: RunHistoryRepositoryStub(session: firstSession),
                companionURL: companionURL,
                runService: firstRunService
            )
        }

        await firstViewModel.load()
        let didStartFirstRun = await firstViewModel.send(
            "Keep this stream open"
        )
        XCTAssertTrue(didStartFirstRun)
        await waitForEventStreamStart(firstRunService)

        for index in 1...4 {
            let session = try makeSessionSummary(id: "session-\(index)")
            _ = registry.viewModel(for: session) {
                CompanionSessionHistoryViewModel(
                    session: session,
                    repository: RunHistoryRepositoryStub(session: session),
                    companionURL: companionURL,
                    runService: RunServiceStub(
                        eventResult: .holdOpen,
                        statuses: []
                    )
                )
            }
        }

        let reopenedViewModel = registry.viewModel(for: firstSession) {
            XCTFail("Inactive browsing must not evict a live event stream")
            return firstViewModel
        }

        XCTAssertTrue(firstViewModel === reopenedViewModel)
        let terminatedRunIDs = await firstRunService.eventTerminationRunIDs
        XCTAssertTrue(terminatedRunIDs.isEmpty)
        registry.removeAll()
    }

    @MainActor
    func testEvictedViewModelCannotSendUntilReadopted() async throws {
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let registry = CompanionSessionHistoryViewModelRegistry()
        let firstSession = try makeSessionSummary(id: "session-retained")
        let firstRunService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: []
        )
        let retainedViewModel = registry.viewModel(for: firstSession) {
            CompanionSessionHistoryViewModel(
                session: firstSession,
                repository: RunHistoryRepositoryStub(session: firstSession),
                companionURL: companionURL,
                runService: firstRunService
            )
        }

        for index in 1...(CompanionSessionPool.maximumConcurrentEventStreams + 1) {
            let session = try makeSessionSummary(id: "inactive-\(index)")
            _ = registry.viewModel(for: session) {
                CompanionSessionHistoryViewModel(
                    session: session,
                    repository: RunHistoryRepositoryStub(session: session),
                    companionURL: companionURL,
                    runService: RunServiceStub(
                        eventResult: .holdOpen,
                        statuses: []
                    )
                )
            }
        }

        let didSendWhileEvicted = await retainedViewModel.send(
            "Must not start outside registry accounting"
        )
        XCTAssertFalse(didSendWhileEvicted)
        let evictedStartRequests = await firstRunService.startRequests
        XCTAssertTrue(evictedStartRequests.isEmpty)

        registry.adopt(retainedViewModel, sessionID: firstSession.id)
        let didSendAfterReadoption = await retainedViewModel.send(
            "Now start under registry accounting"
        )
        XCTAssertTrue(didSendAfterReadoption)
        await waitForEventStreamStart(firstRunService)
        registry.removeAll()
    }

    @MainActor
    func testRegistryRejectsFifthRunWithoutEvictingLiveStreams() async throws {
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let registry = CompanionSessionHistoryViewModelRegistry()
        var viewModels: [CompanionSessionHistoryViewModel] = []
        var runServices: [RunServiceStub] = []

        for index in 0..<CompanionSessionPool.maximumConcurrentEventStreams {
            let session = try makeSessionSummary(id: "session-\(index)")
            let runService = RunServiceStub(
                eventResult: .holdOpen,
                statuses: []
            )
            let viewModel = registry.viewModel(for: session) {
                CompanionSessionHistoryViewModel(
                    session: session,
                    repository: RunHistoryRepositoryStub(session: session),
                    companionURL: companionURL,
                    runService: runService
                )
            }
            await viewModel.load()
            let didStartRun = await viewModel.send(
                "Keep stream \(index) open"
            )
            XCTAssertTrue(didStartRun)
            await waitForEventStreamStart(runService)
            viewModels.append(viewModel)
            runServices.append(runService)
        }

        let fifthSession = try makeSessionSummary(id: "session-overflow")
        let fifthRunService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: []
        )
        let fifthViewModel = registry.viewModel(for: fifthSession) {
            CompanionSessionHistoryViewModel(
                session: fifthSession,
                repository: RunHistoryRepositoryStub(session: fifthSession),
                companionURL: companionURL,
                runService: fifthRunService
            )
        }

        let didStartFifthRun = await fifthViewModel.send(
            "Do not exceed the event capacity"
        )
        XCTAssertFalse(didStartFifthRun)
        XCTAssertNotNil(fifthViewModel.mutationErrorMessage)
        let fifthStartRequests = await fifthRunService.startRequests
        XCTAssertTrue(fifthStartRequests.isEmpty)

        for runService in runServices {
            let terminatedRunIDs = await runService.eventTerminationRunIDs
            XCTAssertTrue(terminatedRunIDs.isEmpty)
        }

        let firstViewModel = try XCTUnwrap(viewModels.first)
        let firstSession = firstViewModel.session
        let reopenedViewModel = registry.viewModel(for: firstSession) {
            XCTFail("Capacity admission must not evict a live stream")
            return firstViewModel
        }
        XCTAssertTrue(firstViewModel === reopenedViewModel)
        registry.removeAll()
    }

    @MainActor
    func testRegistryRejectsFifthSimultaneousPendingStart() async throws {
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let registry = CompanionSessionHistoryViewModelRegistry()
        var pendingServices: [RunServiceStub] = []
        var pendingTasks: [Task<Bool, Never>] = []

        for index in 0..<CompanionSessionPool.maximumConcurrentEventStreams {
            let session = try makeSessionSummary(id: "pending-\(index)")
            let runService = RunServiceStub(
                eventResult: .holdOpen,
                statuses: [],
                holdsStartUntilReleased: true
            )
            let viewModel = registry.viewModel(for: session) {
                CompanionSessionHistoryViewModel(
                    session: session,
                    repository: RunHistoryRepositoryStub(session: session),
                    companionURL: companionURL,
                    runService: runService
                )
            }
            let sendTask = Task {
                await viewModel.send("Pending run \(index)")
            }
            await waitForRunStartRequest(runService)
            pendingServices.append(runService)
            pendingTasks.append(sendTask)
        }

        let fifthSession = try makeSessionSummary(id: "pending-overflow")
        let fifthRunService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: []
        )
        let fifthViewModel = registry.viewModel(for: fifthSession) {
            CompanionSessionHistoryViewModel(
                session: fifthSession,
                repository: RunHistoryRepositoryStub(session: fifthSession),
                companionURL: companionURL,
                runService: fifthRunService
            )
        }
        let didStartFifthRun = await fifthViewModel.send(
            "Do not create a fifth pending run"
        )

        XCTAssertFalse(didStartFifthRun)
        XCTAssertNotNil(fifthViewModel.mutationErrorMessage)
        let fifthStartRequests = await fifthRunService.startRequests
        XCTAssertTrue(fifthStartRequests.isEmpty)

        for runService in pendingServices {
            await runService.releaseStart()
        }
        for sendTask in pendingTasks {
            let didStartRun = await sendTask.value
            XCTAssertTrue(didStartRun)
        }
        registry.removeAll()
    }

    @MainActor
    func testRegistryOwnerTeardownCancelsLiveObservation() async throws {
        let session = try makeSessionSummary()
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let runService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: []
        )
        let registry = CompanionSessionHistoryViewModelRegistry()
        let viewModel = registry.viewModel(for: session) {
            CompanionSessionHistoryViewModel(
                session: session,
                repository: RunHistoryRepositoryStub(session: session),
                companionURL: companionURL,
                runService: runService
            )
        }

        await viewModel.load()
        let didStartRun = await viewModel.send("Keep this stream open")
        XCTAssertTrue(didStartRun)
        await waitForEventStreamStart(runService)
        registry.suspendObservations()
        await waitForEventStreamTermination(runService)

        let terminatedRunIDs = await runService.eventTerminationRunIDs
        XCTAssertEqual(["run-1"], terminatedRunIDs)

        let reopenedViewModel = registry.viewModel(for: session) {
            XCTFail("Owner reappearance must reuse the tracked view model")
            return viewModel
        }
        XCTAssertTrue(viewModel === reopenedViewModel)
        registry.removeAll()
    }

    @MainActor
    func testDelayedStartOwnerTeardownSkipsEventStream() async throws {
        let session = try makeSessionSummary()
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let runService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: [],
            holdsStartUntilReleased: true
        )
        let registry = CompanionSessionHistoryViewModelRegistry()
        let viewModel = registry.viewModel(for: session) {
            CompanionSessionHistoryViewModel(
                session: session,
                repository: RunHistoryRepositoryStub(session: session),
                companionURL: companionURL,
                runService: runService
            )
        }
        await viewModel.load()

        let sendTask = Task {
            await viewModel.send("Start while leaving")
        }
        await waitForRunStartRequest(runService)
        registry.suspendObservations()
        await runService.releaseStart()
        let didStartRun = await sendTask.value

        XCTAssertTrue(didStartRun)
        XCTAssertEqual("run-1", viewModel.activeRunID)
        XCTAssertEqual(.transportDisconnected, viewModel.runState)
        let eventRunIDs = await runService.eventRunIDs
        XCTAssertTrue(eventRunIDs.isEmpty)
        registry.removeAll()
    }

    @MainActor
    func testDelayedStartReappearanceRestoresEventStream() async throws {
        let session = try makeSessionSummary()
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let runService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: [],
            holdsStartUntilReleased: true
        )
        let registry = CompanionSessionHistoryViewModelRegistry()
        let viewModel = registry.viewModel(for: session) {
            CompanionSessionHistoryViewModel(
                session: session,
                repository: RunHistoryRepositoryStub(session: session),
                companionURL: companionURL,
                runService: runService
            )
        }
        await viewModel.load()

        let sendTask = Task {
            await viewModel.send("Start while briefly away")
        }
        await waitForRunStartRequest(runService)
        registry.suspendObservations()
        let reopenedViewModel = registry.viewModel(for: session) {
            XCTFail("Reappearance must reuse the tracked view model")
            return viewModel
        }
        await reopenedViewModel.resumeRunObservation()
        await runService.releaseStart()
        let didStartRun = await sendTask.value
        await waitForEventStreamStart(runService)

        XCTAssertTrue(didStartRun)
        XCTAssertTrue(viewModel === reopenedViewModel)
        XCTAssertEqual(.streaming, reopenedViewModel.runState)
        let eventRunIDs = await runService.eventRunIDs
        XCTAssertEqual(["run-1"], eventRunIDs)
        registry.removeAll()
    }

    @MainActor
    func testRegistryRetainsDelayedStartAtFullEventCapacity() async throws {
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let registry = CompanionSessionHistoryViewModelRegistry()
        let firstSession = try makeSessionSummary(id: "session-starting")
        let firstRunService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: [],
            holdsStartUntilReleased: true
        )
        let firstViewModel = registry.viewModel(for: firstSession) {
            CompanionSessionHistoryViewModel(
                session: firstSession,
                repository: RunHistoryRepositoryStub(session: firstSession),
                companionURL: companionURL,
                runService: firstRunService
            )
        }
        await firstViewModel.load()
        let firstSendTask = Task {
            await firstViewModel.send("Start before eviction")
        }
        await waitForRunStartRequest(firstRunService)
        var oldestLiveSession: SessionSummary?
        var oldestLiveViewModel: CompanionSessionHistoryViewModel?
        var oldestLiveRunService: RunServiceStub?

        for index in 1..<CompanionSessionPool.maximumConcurrentEventStreams {
            let session = try makeSessionSummary(id: "session-live-\(index)")
            let runService = RunServiceStub(
                eventResult: .holdOpen,
                statuses: []
            )
            let viewModel = registry.viewModel(for: session) {
                CompanionSessionHistoryViewModel(
                    session: session,
                    repository: RunHistoryRepositoryStub(session: session),
                    companionURL: companionURL,
                    runService: runService
                )
            }
            let didStartRun = await viewModel.send("Fill slot \(index)")
            XCTAssertTrue(didStartRun)
            await waitForEventStreamStart(runService)
            if index == 1 {
                oldestLiveSession = session
                oldestLiveViewModel = viewModel
                oldestLiveRunService = runService
            }
        }

        let overflowSession = try makeSessionSummary(id: "session-overflow")
        let overflowRunService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: []
        )
        let overflowViewModel = registry.viewModel(for: overflowSession) {
            CompanionSessionHistoryViewModel(
                session: overflowSession,
                repository: RunHistoryRepositoryStub(
                    session: overflowSession
                ),
                companionURL: companionURL,
                runService: overflowRunService
            )
        }

        let didStartOverflowRun = await overflowViewModel.send(
            "Fifth pending run must be rejected"
        )
        XCTAssertFalse(didStartOverflowRun)
        let overflowStartRequests = await overflowRunService.startRequests
        XCTAssertTrue(overflowStartRequests.isEmpty)

        let reopenedStartingViewModel = registry.viewModel(for: firstSession) {
            XCTFail("A pending start must retain its registry identity")
            return firstViewModel
        }
        await firstRunService.releaseStart()
        let didStartFirstRun = await firstSendTask.value
        await waitForEventStreamStart(firstRunService)
        XCTAssertTrue(didStartFirstRun)
        XCTAssertTrue(firstViewModel === reopenedStartingViewModel)
        XCTAssertEqual(.streaming, firstViewModel.runState)
        let eventRunIDs = await firstRunService.eventRunIDs
        XCTAssertEqual(["run-1"], eventRunIDs)

        let retainedLiveSession = try XCTUnwrap(oldestLiveSession)
        let retainedLiveViewModel = try XCTUnwrap(oldestLiveViewModel)
        let retainedLiveRunService = try XCTUnwrap(oldestLiveRunService)
        let reopenedLiveViewModel = registry.viewModel(
            for: retainedLiveSession
        ) {
            XCTFail("A rejected fifth run must not evict a live stream")
            return retainedLiveViewModel
        }
        XCTAssertTrue(retainedLiveViewModel === reopenedLiveViewModel)
        let terminatedRunIDs = await retainedLiveRunService
            .eventTerminationRunIDs
        XCTAssertTrue(terminatedRunIDs.isEmpty)
        registry.removeAll()
    }

    @MainActor
    func testRecreatedChatRetainsStopLatch() async throws {
        let session = try makeSessionSummary()
        let activeRunStore = ActiveRunStoreStub()
        let key = CompanionActiveRunKey(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            sessionID: "session-1"
        )
        await activeRunStore.store(
            CompanionActiveRunRecord(
                runID: "run-1",
                stopState: .deliveryUnknown
            ),
            for: key
        )
        let runService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .stopping,
                    sessionID: "session-1",
                    lastEvent: "run.stopping",
                    output: nil,
                    errorMessage: nil
                )
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: RunHistoryRepositoryStub(session: session),
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            activeRunStore: activeRunStore
        )

        await viewModel.load()
        await viewModel.resumeRunObservation()
        XCTAssertFalse(viewModel.canRequestStop)
        await viewModel.stopRun()

        let stopCallCount = await runService.stopCallCount
        XCTAssertEqual(0, stopCallCount)
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testCancelledResumeDoesNotStartAnOrphanReconciliation() async throws {
        let session = try makeSessionSummary()
        let activeRunStore = ActiveRunStoreStub(
            activeRunDelayNanoseconds: 100_000_000
        )
        let key = CompanionActiveRunKey(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            sessionID: "session-1"
        )
        await activeRunStore.store(
            CompanionActiveRunRecord(
                runID: "run-1",
                stopState: .notRequested
            ),
            for: key
        )
        let runService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: []
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: RunHistoryRepositoryStub(session: session),
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            activeRunStore: activeRunStore
        )

        let resumeTask = Task {
            await viewModel.resumeRunObservation()
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        resumeTask.cancel()
        await resumeTask.value

        XCTAssertNil(viewModel.activeRunID)
        let statusRunIDs = await runService.statusRunIDs
        XCTAssertTrue(statusRunIDs.isEmpty)
    }

    @MainActor
    func testRunningHistoryRejectsSameLengthStaleReplacement() async throws {
        let session = try makeSessionSummary()
        let currentHistory = [
            ChatMessage(
                role: "user",
                content: "Question",
                timestamp: 1,
                messageId: "user-1"
            ),
            ChatMessage(
                role: "assistant",
                content: "Newest value",
                timestamp: 2,
                messageId: "assistant-1"
            ),
        ]
        let staleHistory = [
            currentHistory[0],
            ChatMessage(
                role: "assistant",
                content: "Staler value",
                timestamp: 2,
                messageId: "assistant-1"
            ),
        ]
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [
                1: currentHistory,
                2: staleHistory,
            ]
        )
        let activeRunStore = ActiveRunStoreStub()
        let key = CompanionActiveRunKey(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            sessionID: "session-1"
        )
        await activeRunStore.store(
            CompanionActiveRunRecord(
                runID: "run-1",
                stopState: .notRequested
            ),
            for: key
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .holdOpen,
                statuses: [
                    ConversationRunSnapshot(
                        runID: "run-1",
                        state: .running,
                        sessionID: "session-1",
                        lastEvent: "message.delta",
                        output: nil,
                        errorMessage: nil
                    )
                ]
            ),
            activeRunStore: activeRunStore
        )

        await viewModel.load()
        await viewModel.resumeRunObservation()
        await waitUntil {
            viewModel.activeRunID == "run-1"
        }
        let historyWaitStart = ContinuousClock.now
        while (await repository.historyCallCount) < 2,
              ContinuousClock.now - historyWaitStart < .seconds(1) {
            await Task.yield()
        }

        XCTAssertEqual("Newest value", viewModel.allMessages.last?.content)
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testRunningHistoryRejectsSameCountStaleToolReplacement() async throws {
        let session = try makeSessionSummary()
        let currentToolCalls: [JSONValue] = [
            .object([
                "id": .string("tool-1"),
                "function": .object([
                    "name": .string("web_search")
                ]),
            ])
        ]
        let staleToolCalls: [JSONValue] = [
            .object([
                "id": .string("tool-1"),
                "function": .object([
                    "name": .string("read_file")
                ]),
            ])
        ]
        let currentHistory = [
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1,
                messageId: "assistant-1",
                toolCalls: currentToolCalls
            )
        ]
        let staleHistory = [
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1,
                messageId: "assistant-1",
                toolCalls: staleToolCalls
            )
        ]
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [
                1: currentHistory,
                2: staleHistory,
            ]
        )
        let activeRunStore = ActiveRunStoreStub()
        let key = CompanionActiveRunKey(
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            sessionID: "session-1"
        )
        await activeRunStore.store(
            CompanionActiveRunRecord(
                runID: "run-1",
                stopState: .notRequested
            ),
            for: key
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .holdOpen,
                statuses: [
                    ConversationRunSnapshot(
                        runID: "run-1",
                        state: .running,
                        sessionID: "session-1",
                        lastEvent: "tool.started",
                        output: nil,
                        errorMessage: nil
                    )
                ]
            ),
            activeRunStore: activeRunStore
        )

        await viewModel.load()
        await viewModel.resumeRunObservation()
        await waitUntil {
            viewModel.activeRunID == "run-1"
        }
        let historyWaitStart = ContinuousClock.now
        while (await repository.historyCallCount) < 2,
              ContinuousClock.now - historyWaitStart < .seconds(1) {
            await Task.yield()
        }

        XCTAssertEqual(
            currentToolCalls,
            viewModel.allMessages.last?.toolCalls
        )
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testPersistedAssistantTextStaysInStableLiveRowDuringRun() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [
                2: [
                    ChatMessage(
                        role: "user",
                        content: "Answer slowly",
                        timestamp: 1,
                        messageId: "user-1"
                    ),
                    ChatMessage(
                        role: "assistant",
                        content: "Partial answer",
                        timestamp: 2,
                        messageId: "assistant-1"
                    ),
                ]
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .deltasThenWait(["Partial answer"], 10_000_000),
                statuses: [
                    ConversationRunSnapshot(
                        runID: "run-1",
                        state: .running,
                        sessionID: "session-1",
                        lastEvent: "message.delta",
                        output: nil,
                        errorMessage: nil
                    )
                ]
            ),
            reconciliationDelayNanoseconds: 100_000_000
        )
        await viewModel.load()

        let didSend = await viewModel.send("Answer slowly")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.streamingMessage?.content == "Partial answer"
        }

        XCTAssertNil(viewModel.allMessages.last?.content)
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testPartialPersistedAssistantTextKeepsCompleteLiveStream() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [
                2: [
                    ChatMessage(
                        role: "user",
                        content: "Answer slowly",
                        timestamp: 1,
                        messageId: "user-1"
                    ),
                    ChatMessage(
                        role: "assistant",
                        content: "Hello",
                        timestamp: 2,
                        messageId: "assistant-1"
                    ),
                ]
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .deltasThenWait(["Hello world"], 10_000_000),
                statuses: [
                    ConversationRunSnapshot(
                        runID: "run-1",
                        state: .running,
                        sessionID: "session-1",
                        lastEvent: "message.delta",
                        output: nil,
                        errorMessage: nil
                    )
                ]
            ),
            reconciliationDelayNanoseconds: 100_000_000
        )
        await viewModel.load()

        let didSend = await viewModel.send("Answer slowly")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.streamingMessage?.content == "Hello world"
        }

        XCTAssertNil(viewModel.allMessages.last?.content)
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testConflictingPersistedAssistantTextDoesNotBlankLiveStream() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [
                2: [
                    ChatMessage(
                        role: "user",
                        content: "Answer slowly",
                        timestamp: 1,
                        messageId: "user-1"
                    ),
                    ChatMessage(
                        role: "assistant",
                        content: "Saved answer",
                        timestamp: 2,
                        messageId: "assistant-1"
                    ),
                ]
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .deltasThenWait(["Stream answer"], 10_000_000),
                statuses: [
                    ConversationRunSnapshot(
                        runID: "run-1",
                        state: .running,
                        sessionID: "session-1",
                        lastEvent: "message.delta",
                        output: nil,
                        errorMessage: nil
                    )
                ]
            ),
            reconciliationDelayNanoseconds: 100_000_000
        )
        await viewModel.load()

        let didSend = await viewModel.send("Answer slowly")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.streamingMessage?.content == "Stream answer"
        }

        XCTAssertNil(viewModel.allMessages.last?.content)
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testReasoningOnlyHistoryUpdateKeepsNewerStreamText() async throws {
        let session = try makeSessionSummary()
        let initialHistory = [
            ChatMessage(
                role: "user",
                content: "Earlier question",
                timestamp: 1,
                messageId: "user-old"
            ),
            ChatMessage(
                role: "assistant",
                content: "Earlier answer",
                timestamp: 2,
                messageId: "assistant-old"
            ),
        ]
        let enrichedHistory = [
            initialHistory[0],
            ChatMessage(
                role: "assistant",
                content: "Earlier answer",
                timestamp: 2,
                messageId: "assistant-old",
                reasoning: "Reviewing the prior answer."
            ),
            ChatMessage(
                role: "user",
                content: "Continue",
                timestamp: 3,
                messageId: "user-current"
            ),
        ]
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [
                1: initialHistory,
                2: enrichedHistory,
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .deltasThenWait(["New suffix"], 10_000_000),
                statuses: [
                    ConversationRunSnapshot(
                        runID: "run-1",
                        state: .running,
                        sessionID: "session-1",
                        lastEvent: "reasoning.available",
                        output: nil,
                        errorMessage: nil
                    )
                ]
            ),
            reconciliationDelayNanoseconds: 100_000_000
        )
        await viewModel.load()

        let didSend = await viewModel.send("Continue")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.durableReasoningGroups.map(\.text) == [
                "Reviewing the prior answer."
            ]
                && viewModel.streamingMessage?.content == "New suffix"
        }

        XCTAssertEqual("New suffix", viewModel.streamingMessage?.content)
        viewModel.suspendRunObservation()
    }

    @MainActor
    func testMissingRecoveredRunClearsStaleLivePresentation() async throws {
        let session = try makeSessionSummary()
        let authoritativeHistory = [
            ChatMessage(
                role: "user",
                content: "Inspect",
                timestamp: 1,
                messageId: "user-1"
            ),
            ChatMessage(
                role: "assistant",
                content: "Saved answer",
                timestamp: 2,
                messageId: "assistant-1"
            ),
        ]
        let reasoning = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "reasoning.available",
                runID: "run-1",
                delta: nil,
                text: "Stale live reasoning",
                output: nil,
                error: nil,
                timestamp: 2
            )
        )
        let tool = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "tool.started",
                runID: "run-1",
                delta: nil,
                output: nil,
                error: nil,
                tool: "web_search",
                timestamp: 3
            )
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: RunHistoryRepositoryStub(
                session: session,
                historyMessagesByCall: [2: authoritativeHistory]
            ),
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .eventsThenWait(
                    [
                        .data(
                            ConversationRunEventData(
                                transportEvent: nil,
                                event: "message.delta",
                                runID: "run-1",
                                delta: "Stale live answer",
                                output: nil,
                                error: nil,
                                timestamp: 1
                            )
                        ),
                        reasoning,
                        tool,
                    ],
                    10_000_000
                ),
                statuses: [],
                statusError: .runNotFound
            ),
            reconciliationDelayNanoseconds: 100_000_000
        )
        await viewModel.load()

        let didSend = await viewModel.send("Inspect")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.activeRunID == nil
                && viewModel.allMessages.last?.content == "Saved answer"
        }

        XCTAssertEqual("Saved answer", viewModel.allMessages.last?.content)
        XCTAssertNil(viewModel.streamingMessage)
        XCTAssertTrue(viewModel.reasoningText.isEmpty)
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
    }

    @MainActor
    func testSessionModelSelectionLocksThenAppliesToSubsequentRun() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let runService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: []
        )
        let inventory = CompanionModelInventory(
            providers: [
                CompanionModelProvider(
                    slug: "openrouter",
                    name: "OpenRouter",
                    models: [
                        .string("anthropic/claude-sonnet-4.6")
                    ],
                    authenticated: true,
                    capabilities: [
                        "anthropic/claude-sonnet-4.6": .object([
                            "reasoning": .bool(true)
                        ])
                    ]
                )
            ],
            model: "anthropic/claude-sonnet-4.6",
            provider: "openrouter"
        )
        let modelService = ModelServiceStub(inventory: inventory)
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            supportsModelSelection: true,
            modelService: modelService
        )
        await viewModel.load()
        await viewModel.loadModelOptions()

        let option = try XCTUnwrap(
            viewModel.modelGroups.first?.models.first
        )
        let didSelectModel = await viewModel.selectModel(option)
        let didSelectReasoning = await viewModel.selectReasoning(.high)
        let didSend = await viewModel.send("Continue")
        XCTAssertTrue(didSelectModel)
        XCTAssertTrue(didSelectReasoning)
        XCTAssertTrue(didSend)
        XCTAssertNil(viewModel.runStatusText)

        let locks = await modelService.lockedSelections
        XCTAssertEqual(2, locks.count)
        XCTAssertEqual(.high, locks.last?.reasoningEffort)

        let requests = await runService.startRequests
        XCTAssertEqual(1, requests.count)
        XCTAssertEqual(locks.last, requests[0].selection)
    }

    @MainActor
    func testModelSelectionBlocksSendAndRejectsOverlappingLocks() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let runService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: []
        )
        let modelService = ModelServiceStub(
            inventory: makeModelInventory()
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            supportsModelSelection: true,
            modelService: modelService,
            modelSelectionStore: InMemoryModelSelectionStore()
        )
        await viewModel.load()
        await viewModel.loadModelOptions()
        await modelService.setLockDelayNanoseconds(100_000_000)

        let lockTask = Task { @MainActor in
            await viewModel.selectReasoning(.high)
        }
        await waitUntil { viewModel.isApplyingModelSelection }

        XCTAssertFalse(viewModel.canSend)
        let overlappingLock = await viewModel.selectReasoning(.low)
        let sendWhileLocking = await viewModel.send("Must wait")
        XCTAssertFalse(overlappingLock)
        XCTAssertFalse(sendWhileLocking)
        let didLock = await lockTask.value
        XCTAssertTrue(didLock)

        let didSend = await viewModel.send("Continue")
        XCTAssertTrue(didSend)
        let requests = await runService.startRequests
        XCTAssertEqual(.high, requests.first?.selection?.reasoningEffort)
    }

    @MainActor
    func testAcknowledgedReasoningSelectionRestoresForSameServerSession() async throws {
        let session = SessionSummary(
            sessionId: "session-1",
            title: "Run test",
            model: "anthropic/claude-sonnet-4.6",
            modelProvider: "openrouter"
        )
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let store = InMemoryModelSelectionStore()
        let modelService = ModelServiceStub(
            inventory: makeModelInventory()
        )

        let firstViewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: RunHistoryRepositoryStub(session: session),
            companionURL: companionURL,
            runService: RunServiceStub(
                eventResult: .holdOpen,
                statuses: []
            ),
            supportsModelSelection: true,
            modelService: modelService,
            modelSelectionStore: store
        )
        await firstViewModel.load()
        await firstViewModel.loadModelOptions()
        let didSelectReasoning =
            await firstViewModel.selectReasoning(.high)
        XCTAssertTrue(didSelectReasoning)

        let restoredViewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: RunHistoryRepositoryStub(session: session),
            companionURL: companionURL,
            runService: RunServiceStub(
                eventResult: .holdOpen,
                statuses: []
            ),
            supportsModelSelection: true,
            modelService: modelService,
            modelSelectionStore: store
        )
        await restoredViewModel.load()
        await restoredViewModel.loadModelOptions()

        XCTAssertEqual(.high, restoredViewModel.selectedModel?.reasoningEffort)
    }

    @MainActor
    func testRestoredSelectionDropsReasoningWhenCatalogNoLongerSupportsIt() async throws {
        let session = SessionSummary(
            sessionId: "session-1",
            model: "anthropic/claude-sonnet-4.6",
            modelProvider: "openrouter"
        )
        let companionURL = try XCTUnwrap(
            URL(string: "https://companion.example.test")
        )
        let store = InMemoryModelSelectionStore()
        await store.save(
            CompanionModelSelection(
                model: "anthropic/claude-sonnet-4.6",
                provider: "openrouter",
                reasoningEffort: .high
            ),
            companionURL: companionURL,
            sessionID: "session-1"
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: RunHistoryRepositoryStub(session: session),
            companionURL: companionURL,
            runService: RunServiceStub(
                eventResult: .holdOpen,
                statuses: []
            ),
            supportsModelSelection: true,
            modelService: ModelServiceStub(
                inventory: makeModelInventory(
                    supportsReasoning: false
                )
            ),
            modelSelectionStore: store
        )

        await viewModel.load()
        await viewModel.loadModelOptions()

        XCTAssertNil(viewModel.selectedModel?.reasoningEffort)
        let storedSelection = await store.load(
            companionURL: companionURL,
            sessionID: "session-1"
        )
        XCTAssertNil(storedSelection?.reasoningEffort)
    }

    @MainActor
    func testApprovalDecisionIsSingleFlightAndNeverRestartsRun() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let approvalEvent = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "approval.request",
                runID: "run-1",
                delta: nil,
                output: nil,
                error: nil,
                timestamp: 123,
                command: "sudo -S true",
                description: "sudo with privilege flag",
                approvalChoices: ["once", "deny"]
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventBatchesThenWait(
                [approvalEvent],
                [approvalEvent],
                100_000_000,
                1_000_000_000
            ),
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .waitingForApproval,
                    sessionID: "session-1",
                    lastEvent: "approval.request",
                    output: nil,
                    errorMessage: nil
                ),
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                )
            ],
            approvalDelayNanoseconds: 300_000_000
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            supportsRunApprovals: true,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let didSend = await viewModel.send("Inspect safely")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.pendingApproval != nil }

        async let first: Void = viewModel.respondToApproval(.deny)
        async let duplicate: Void = viewModel.respondToApproval(.deny)
        _ = await (first, duplicate)

        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertTrue(viewModel.approvalContextUnavailable)
        let approvalRequests = await runService.approvalRequests
        let startRequests = await runService.startRequests
        XCTAssertEqual(1, approvalRequests.count)
        XCTAssertEqual(
            "run-1",
            approvalRequests.first?.runID
        )
        XCTAssertEqual(
            .deny,
            approvalRequests.first?.choice
        )
        XCTAssertEqual(1, startRequests.count)

        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }
    }

    @MainActor
    func testExpiredApprovalReconcilesTheSameRun() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let approvalEvent = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "approval.request",
                runID: "run-1",
                delta: nil,
                output: nil,
                error: nil,
                timestamp: 123,
                command: "command",
                description: "approval required",
                approvalChoices: ["once", "deny"]
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsThenWait(
                [approvalEvent],
                1_000_000_000
            ),
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .running,
                    sessionID: "session-1",
                    lastEvent: "approval.responded",
                    output: nil,
                    errorMessage: nil
                ),
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                ),
            ],
            approvalError: .approvalNotPending
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            supportsRunApprovals: true,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let didSend = await viewModel.send("Inspect safely")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.pendingApproval != nil }

        await viewModel.respondToApproval(.once)

        XCTAssertNil(viewModel.pendingApproval)
        let statusRunIDs = await runService.statusRunIDs
        let startRequests = await runService.startRequests
        XCTAssertEqual(["run-1"], statusRunIDs)
        XCTAssertEqual(1, startRequests.count)
        XCTAssertNotNil(viewModel.approvalErrorMessage)

        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }
    }

    @MainActor
    func testAmbiguousApprovalFailureBecomesNonActionable() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let approvalEvent = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "approval.request",
                runID: "run-1",
                delta: nil,
                output: nil,
                error: nil,
                timestamp: 123,
                command: "command",
                description: "approval required",
                approvalChoices: ["once", "deny"]
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsThenWait(
                [approvalEvent],
                1_000_000_000
            ),
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .waitingForApproval,
                    sessionID: "session-1",
                    lastEvent: "approval.request",
                    output: nil,
                    errorMessage: nil
                ),
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                ),
            ],
            approvalError: .gatewayTransportFailure
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            supportsRunApprovals: true,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let didSend = await viewModel.send("Inspect safely")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.pendingApproval != nil }

        await viewModel.respondToApproval(.once)

        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertTrue(viewModel.approvalContextUnavailable)
        let approvalRequests = await runService.approvalRequests
        let statusRunIDs = await runService.statusRunIDs
        XCTAssertEqual(1, approvalRequests.count)
        XCTAssertEqual(["run-1"], statusRunIDs)

        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }
    }

    @MainActor
    func testDisconnectedApprovalWaitNeverOffersBlindActions() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let approvalEvent = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "approval.request",
                runID: "run-1",
                delta: nil,
                output: nil,
                error: nil,
                timestamp: 123,
                command: "command",
                description: "approval required",
                approvalChoices: ["once", "deny"]
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsThenWait([approvalEvent], 0),
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .waitingForApproval,
                    sessionID: "session-1",
                    lastEvent: "approval.request",
                    output: nil,
                    errorMessage: nil
                ),
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                ),
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            supportsRunApprovals: true,
            reconciliationDelayNanoseconds: 100_000_000
        )
        await viewModel.load()
        let didSend = await viewModel.send("Inspect safely")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.runState == .waitingForApproval
                && viewModel.pendingApproval == nil
                && viewModel.approvalContextUnavailable
        }

        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertTrue(viewModel.approvalContextUnavailable)
        let startRequests = await runService.startRequests
        XCTAssertEqual(1, startRequests.count)

        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }
    }

    @MainActor
    func testLateApprovalEventCannotRegressStoppingState() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let approvalEvent = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "approval.request",
                runID: "run-1",
                delta: nil,
                output: nil,
                error: nil,
                timestamp: 123,
                command: "command",
                description: "approval required",
                approvalChoices: ["once", "deny"]
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsAfterDelay(
                [approvalEvent],
                100_000_000
            ),
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                )
            ],
            statusDelayNanoseconds: 2_000_000_000
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            supportsRunApprovals: true,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let didSend = await viewModel.send("Inspect safely")
        XCTAssertTrue(didSend)

        await viewModel.stopRun()
        XCTAssertEqual(.stopping, viewModel.runState)
        try await Task.sleep(nanoseconds: 175_000_000)
        XCTAssertEqual(.stopping, viewModel.runState)
        XCTAssertNil(viewModel.pendingApproval)

        await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            viewModel.activeRunID == nil
        }
    }

    @MainActor
    func testStopIsIdempotentAndReconcilesToCancelled() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let runService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                )
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let didSend = await viewModel.send("Stop this")
        XCTAssertTrue(didSend)

        async let first: Void = viewModel.stopRun()
        async let second: Void = viewModel.stopRun()
        _ = await (first, second)
        await waitUntil { viewModel.activeRunID == nil }

        let stopCallCount = await runService.stopCallCount
        XCTAssertEqual(1, stopCallCount)
        XCTAssertEqual(.cancelled, viewModel.runState)
    }

    @MainActor
    func testLatestVisibleMessageIdentityChangesAtPageLimit() async throws {
        let session = try makeSessionSummary()
        let history = (0..<50).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Message \(index)",
                timestamp: Double(index),
                messageId: "message-\(index)"
            )
        }
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [1: history]
        )
        let runService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                )
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            pageSize: 50,
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )

        await viewModel.load()
        let previousLastMessageID = viewModel.visibleMessages.last?.id
        let didSend = await viewModel.send("Newest")

        XCTAssertTrue(didSend)
        XCTAssertEqual(50, viewModel.visibleMessages.count)
        XCTAssertNotEqual(
            previousLastMessageID,
            viewModel.visibleMessages.last?.id
        )
        XCTAssertEqual("Newest", viewModel.visibleMessages.last?.content)

        let latestMessageID = viewModel.visibleMessages.last?.id
        viewModel.loadOlderMessages()
        XCTAssertEqual(51, viewModel.visibleMessages.count)
        XCTAssertEqual(latestMessageID, viewModel.visibleMessages.last?.id)

        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }
    }

    @MainActor
    func testRawDeltasAreCoalescedBeforeSwiftUIPublication() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let runService = RunServiceStub(
            eventResult: .deltasThenWait(["A", "B", "C"], 200_000_000),
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                )
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let initialFollowTrigger = viewModel.streamingFollowTrigger
        let didSend = await viewModel.send("Stream")
        XCTAssertTrue(didSend)

        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual("", viewModel.streamedAssistantText)
        XCTAssertEqual(
            initialFollowTrigger,
            viewModel.streamingFollowTrigger
        )
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual("ABC", viewModel.streamedAssistantText)
        XCTAssertGreaterThan(
            viewModel.streamingFollowTrigger,
            initialFollowTrigger
        )

        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }
    }

    @MainActor
    func testOverflowBurstStillPublishesOnlyOnFlushCadence() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let deltas = Array(
            repeating: String(repeating: "x", count: 100),
            count: 100
        )
        let runService = RunServiceStub(
            eventResult: .deltasThenWait(deltas, 200_000_000),
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                )
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let didSend = await viewModel.send("Stream")
        XCTAssertTrue(didSend)

        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual("", viewModel.streamedAssistantText)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertFalse(viewModel.streamedAssistantText.isEmpty)
        XCTAssertLessThan(viewModel.streamedAssistantText.count, 10_000)

        await viewModel.stopRun()
        await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            viewModel.activeRunID == nil
        }
    }

    func testProgressiveBufferDrainsLargeRecoverySnapshotsWithABoundedPerTickBudget() {
        var buffer = ConversationRunDeltaBuffer()
        let expected = String(repeating: "x", count: 10_000)
        buffer.append(expected)
        var reconstructed = ""

        while !buffer.isEmpty {
            let frame = buffer.drain(maximumCharacters: 192)
            XCTAssertLessThanOrEqual(frame.count, 192)
            reconstructed += frame
        }

        XCTAssertEqual(expected, reconstructed)
    }

    @MainActor
    func testReasoningAndToolLifecycleKeepStablePresentationIdentity() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let started = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "tool.started",
                runID: "run-1",
                delta: nil,
                output: nil,
                error: nil,
                tool: "read_file",
                preview: "Reading",
                timestamp: 1
            )
        )
        let reasoning = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "reasoning.available",
                runID: "run-1",
                delta: nil,
                text: "Checking the repository",
                output: nil,
                error: nil,
                timestamp: 2
            )
        )
        let completed = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "tool.completed",
                runID: "run-1",
                delta: nil,
                output: nil,
                error: nil,
                tool: "read_file",
                duration: 0.25,
                isError: false,
                timestamp: 3
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsThenWait(
                [started, reasoning, completed],
                200_000_000
            ),
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                )
            ]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let initialFollowTrigger = viewModel.streamingFollowTrigger
        let didSend = await viewModel.send("Inspect")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.liveToolCalls.first?.isCompleted == true
        }

        XCTAssertEqual("Checking the repository", viewModel.reasoningText)
        XCTAssertEqual(1, viewModel.liveToolCalls.count)
        XCTAssertEqual("read_file", viewModel.liveToolCalls[0].name)
        XCTAssertTrue(viewModel.liveToolCalls[0].isCompleted)
        XCTAssertEqual(0.25, viewModel.liveToolCalls[0].duration)
        XCTAssertGreaterThan(
            viewModel.streamingFollowTrigger,
            initialFollowTrigger
        )

        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }
    }

    @MainActor
    func testBulkTerminalRecoveryOutputIsPresentedProgressively() async throws {
        let session = try makeSessionSummary()
        let output = Array(repeating: "progressive", count: 300)
            .joined(separator: " ")
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyMessagesByCall: [
                2: [
                    ChatMessage(
                        role: "assistant",
                        content: output,
                        timestamp: 2,
                        messageId: "assistant-1"
                    )
                ]
            ]
        )
        let terminal = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: "run.completed",
                event: nil,
                runID: "run-1",
                delta: nil,
                output: output,
                error: nil,
                timestamp: 2
            )
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .eventsAfterDelay([terminal], 20_000_000),
                statuses: []
            ),
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()

        let didSend = await viewModel.send("Recover the answer")
        XCTAssertTrue(didSend)
        await waitUntil {
            !(viewModel.streamingMessage?.content?.isEmpty ?? true)
        }

        let firstFrame = try XCTUnwrap(
            viewModel.streamingMessage?.content
        )
        XCTAssertLessThan(firstFrame.count, output.count)
        XCTAssertEqual("run-1", viewModel.activeRunID)

        await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            viewModel.activeRunID == nil
                && viewModel.allMessages.last?.content == output
                && viewModel.streamingMessage == nil
        }
        XCTAssertEqual(output, viewModel.allMessages.last?.content)
        XCTAssertNil(viewModel.streamingMessage)
    }

    @MainActor
    func testTerminalOutputSurvivesAuthoritativeHistoryRefreshFailure() async throws {
        let session = try makeSessionSummary()
        let fallbackOutput = String(
            repeating: "Fallback final answer. ",
            count: 500
        )
        let authoritativeReply = ChatMessage(
            role: "assistant",
            content: "Authoritative final answer",
            timestamp: 5,
            messageId: "assistant-1"
        )
        let repository = RunHistoryRepositoryStub(
            session: session,
            failHistoryCalls: [2, 3, 4],
            historyMessagesByCall: [5: [authoritativeReply]]
        )
        let terminal = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: "run.completed",
                event: nil,
                runID: "run-1",
                delta: nil,
                output: fallbackOutput,
                error: nil,
                timestamp: 4
            )
        )
        let partial = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "message.delta",
                runID: "run-1",
                delta: "Partial",
                output: nil,
                error: nil,
                timestamp: 3
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsThenWait([partial, terminal], 0),
            statuses: []
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        let modelContext = try makeContext()
        await viewModel.load()
        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Cached history",
                    timestamp: 1,
                    messageId: "cached-1"
                )
            ],
            serverURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            sessionID: "session-1",
            in: modelContext
        )
        let didSend = await viewModel.send(
            "Finish",
            modelContext: modelContext
        )
        XCTAssertTrue(didSend)
        await waitUntil {
            !(viewModel.streamingMessage?.content?.isEmpty ?? true)
        }
        let firstFrame = try XCTUnwrap(
            viewModel.streamingMessage?.content
        )
        XCTAssertLessThan(firstFrame.count, fallbackOutput.count)
        XCTAssertTrue(fallbackOutput.hasPrefix(firstFrame))
        await waitUntil(timeoutNanoseconds: 4_000_000_000) {
            viewModel.needsTerminalHistoryRetry
        }

        XCTAssertEqual(.completed, viewModel.runState)
        XCTAssertEqual(
            fallbackOutput,
            viewModel.streamedAssistantText
        )
        XCTAssertEqual("Finish", viewModel.allMessages.last?.content)
        XCTAssertFalse(viewModel.canSend)
        XCTAssertTrue(viewModel.needsTerminalHistoryRetry)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.terminalHistoryRetryMessage.isEmpty)

        let didRetry = await viewModel.retryTerminalHistory(
            modelContext: modelContext
        )
        XCTAssertTrue(didRetry)
        XCTAssertEqual(
            "Authoritative final answer",
            viewModel.allMessages.last?.content
        )
        XCTAssertEqual("", viewModel.streamedAssistantText)
        XCTAssertFalse(viewModel.needsTerminalHistoryRetry)
        XCTAssertTrue(viewModel.canSend)
    }

    @MainActor
    func testTerminalWaitsForOverlappingRefreshThenReloadsHistory() async throws {
        let session = try makeSessionSummary()
        let authoritativeReply = ChatMessage(
            role: "assistant",
            content: "Authoritative final answer",
            timestamp: 5,
            messageId: "assistant-1"
        )
        let repository = RunHistoryRepositoryStub(
            session: session,
            historyDelayByCall: [2: 200_000_000],
            historyMessagesByCall: [3: [authoritativeReply]]
        )
        let terminal = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: "run.completed",
                event: nil,
                runID: "run-1",
                delta: nil,
                output: "Transport fallback",
                error: nil,
                timestamp: 4
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsAfterDelay([terminal], 100_000_000),
            statuses: []
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let didSend = await viewModel.send("Finish")
        XCTAssertTrue(didSend)

        let overlappingLoad = Task {
            await viewModel.load()
        }
        for _ in 0..<100 {
            let historyCallCount = await repository.historyCallCount
            if historyCallCount >= 2 {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let overlappingCallCount = await repository.historyCallCount
        XCTAssertEqual(2, overlappingCallCount)

        await waitUntil {
            viewModel.activeRunID == nil && viewModel.canSend
        }
        _ = await overlappingLoad.value

        let finalHistoryCallCount = await repository.historyCallCount
        XCTAssertEqual(3, finalHistoryCallCount)
        XCTAssertEqual(
            "Authoritative final answer",
            viewModel.allMessages.last?.content
        )
        XCTAssertEqual("", viewModel.streamedAssistantText)
    }

    @MainActor
    func testTerminalEventPublishesExactLatestRunUsage() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let terminal = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "run.completed",
                runID: "run-1",
                delta: nil,
                output: "Done",
                error: nil,
                timestamp: 2,
                usage: ConversationRunUsage(
                    inputTokens: 144,
                    outputTokens: 34,
                    totalTokens: 178
                )
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsAfterDelay([terminal], 20_000_000),
            statuses: []
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()

        let didSend = await viewModel.send("Measure")
        XCTAssertTrue(didSend)
        await waitUntil { viewModel.activeRunID == nil }

        XCTAssertEqual(
            ConversationRunUsage(
                inputTokens: 144,
                outputTokens: 34,
                totalTokens: 178
            ),
            viewModel.latestRunUsage
        )
    }

    @MainActor
    func testTerminalEventWithoutUsageRefreshesAuthoritativeStatusOnce() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let terminal = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "run.completed",
                runID: "run-1",
                delta: nil,
                output: "Done",
                error: nil,
                timestamp: 2
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsAfterDelay([terminal], 20_000_000),
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .completed,
                    sessionID: "session-1",
                    lastEvent: "run.completed",
                    output: "Done",
                    errorMessage: nil,
                    usage: ConversationRunUsage(
                        inputTokens: 200,
                        outputTokens: 50,
                        totalTokens: 250
                    )
                )
            ],
            statusDelayNanoseconds: 300_000_000
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()

        let didSend = await viewModel.send("Measure")
        XCTAssertTrue(didSend)
        await waitUntil {
            viewModel.activeRunID == nil
        }
        XCTAssertNil(viewModel.latestRunUsage)
        await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            viewModel.latestRunUsage != nil
        }

        let statusRunIDs = await runService.statusRunIDs
        XCTAssertEqual(["run-1"], statusRunIDs)
        XCTAssertEqual(
            ConversationRunUsage(
                inputTokens: 200,
                outputTokens: 50,
                totalTokens: 250
            ),
            viewModel.latestRunUsage
        )
        XCTAssertEqual(.completed, viewModel.runState)
    }

    @MainActor
    func testAmbiguousStopFailureDoesNotSendStopTwice() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let runService = RunServiceStub(
            eventResult: .holdOpen,
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .running,
                    sessionID: "session-1",
                    lastEvent: nil,
                    output: nil,
                    errorMessage: nil
                ),
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .cancelled,
                    sessionID: "session-1",
                    lastEvent: "run.cancelled",
                    output: nil,
                    errorMessage: nil
                ),
            ],
            stopError: .transportDisconnected
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 20_000_000
        )
        await viewModel.load()
        let didSend = await viewModel.send("Stop")
        XCTAssertTrue(didSend)

        await viewModel.stopRun()
        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }

        let stopCallCount = await runService.stopCallCount
        XCTAssertEqual(1, stopCallCount)
        XCTAssertEqual(.cancelled, viewModel.runState)
    }

    @MainActor
    func testLateStopResponseCannotOverwriteStreamTerminalState() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let terminal = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "run.completed",
                runID: "run-1",
                delta: nil,
                output: "Done",
                error: nil,
                timestamp: 2
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsAfterDelay([terminal], 20_000_000),
            statuses: [],
            stopDelayNanoseconds: 100_000_000
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let didSend = await viewModel.send("Finish")
        XCTAssertTrue(didSend)

        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }

        XCTAssertEqual(.completed, viewModel.runState)
    }

    @MainActor
    func testLateStatusResponseCannotOverwriteStreamTerminalState() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let terminal = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "run.completed",
                runID: "run-1",
                delta: nil,
                output: "Done",
                error: nil,
                timestamp: 2,
                usage: ConversationRunUsage(
                    inputTokens: 1,
                    outputTokens: 1,
                    totalTokens: 2
                )
            )
        )
        let runService = RunServiceStub(
            eventResult: .eventsAfterDelay([terminal], 20_000_000),
            statuses: [
                ConversationRunSnapshot(
                    runID: "run-1",
                    state: .running,
                    sessionID: "session-1",
                    lastEvent: nil,
                    output: "Stale partial",
                    errorMessage: nil
                )
            ],
            statusDelayNanoseconds: 100_000_000
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let didSend = await viewModel.send("Finish")
        XCTAssertTrue(didSend)

        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(.completed, viewModel.runState)
        XCTAssertEqual("Done", viewModel.streamedAssistantText)
    }

    @MainActor
    func testLateTerminalStatusSuppliesMissingEventOutputProgressively() async throws {
        let session = try makeSessionSummary()
        let repository = RunHistoryRepositoryStub(session: session)
        let output = "\n  "
            + String(repeating: "Recovered answer. ", count: 600)
            + "\n\n"
        let usage = ConversationRunUsage(
            inputTokens: 20,
            outputTokens: 80,
            totalTokens: 100
        )
        let terminal = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: nil,
                event: "run.completed",
                runID: "run-1",
                delta: nil,
                output: nil,
                error: nil,
                timestamp: 2
            )
        )
        let terminalSnapshot = ConversationRunSnapshot(
            runID: "run-1",
            state: .completed,
            sessionID: "session-1",
            lastEvent: "run.completed",
            output: output,
            errorMessage: nil,
            usage: usage
        )
        let runService = RunServiceStub(
            eventResult: .eventsAfterDelay([terminal], 20_000_000),
            statuses: [terminalSnapshot, terminalSnapshot],
            statusDelayNanoseconds: 100_000_000
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: repository,
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: runService,
            reconciliationDelayNanoseconds: 0
        )
        await viewModel.load()
        let didSend = await viewModel.send("Recover")
        XCTAssertTrue(didSend)

        await viewModel.stopRun()
        await waitUntil {
            !(viewModel.streamingMessage?.content?.isEmpty ?? true)
        }
        let firstFrame = try XCTUnwrap(
            viewModel.streamingMessage?.content
        )
        XCTAssertLessThan(firstFrame.count, output.count)
        XCTAssertTrue(output.hasPrefix(firstFrame))
        XCTAssertEqual("Recover", viewModel.allMessages.last?.content)
        await waitUntil(timeoutNanoseconds: 4_000_000_000) {
            viewModel.streamedAssistantText == output
        }

        XCTAssertEqual(.completed, viewModel.runState)
        XCTAssertEqual(usage, viewModel.latestRunUsage)
        XCTAssertTrue(viewModel.needsTerminalHistoryRetry)
        XCTAssertFalse(viewModel.canSend)
    }

    private func makeSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        RunJSONURLProtocol.configure(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RunJSONURLProtocol.self]
        return URLSession(
            configuration: configuration,
            delegate: CompanionRedirectBlocker(),
            delegateQueue: nil
        )
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func response(
        status: Int,
        json: String,
        request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(json.utf8)
        )
    }

    private func makeSessionSummary(
        id: String = "session-1"
    ) throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data(
                """
                {
                  "session_id": "\(id)",
                  "title": "Run test",
                  "source": "api_server"
                }
                """.utf8
            )
        )
    }

    @MainActor
    private func waitForRunStartRequest(
        _ runService: RunServiceStub
    ) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while (await runService.startRequests).isEmpty,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        let requests = await runService.startRequests
        XCTAssertFalse(requests.isEmpty, "Expected the run start request")
    }

    @MainActor
    private func waitForEventStreamStart(
        _ runService: RunServiceStub
    ) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while (await runService.eventRunIDs).isEmpty,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        let runIDs = await runService.eventRunIDs
        XCTAssertFalse(
            runIDs.isEmpty,
            "Expected the live event stream to start"
        )
    }

    @MainActor
    private func waitForEventStreamTermination(
        _ runService: RunServiceStub
    ) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while (await runService.eventTerminationRunIDs).isEmpty,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        let runIDs = await runService.eventTerminationRunIDs
        XCTAssertFalse(
            runIDs.isEmpty,
            "Expected the live event stream to terminate"
        )
    }

    private func makeModelInventory(
        supportsReasoning: Bool = true
    ) -> CompanionModelInventory {
        CompanionModelInventory(
            providers: [
                CompanionModelProvider(
                    slug: "openrouter",
                    name: "OpenRouter",
                    models: [
                        .string("anthropic/claude-sonnet-4.6")
                    ],
                    authenticated: true,
                    capabilities: [
                        "anthropic/claude-sonnet-4.6": .object([
                            "reasoning": .bool(supportsReasoning)
                        ])
                    ]
                )
            ],
            model: "anthropic/claude-sonnet-4.6",
            provider: "openrouter"
        )
    }

    @MainActor
    func testAuthoritativeHistoryRebuildsReasoningAndToolActivity() async throws {
        let session = try makeSessionSummary()
        let messages = [
            ChatMessage(
                role: "user",
                content: "Inspect the file",
                timestamp: 1,
                messageId: "user-1"
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 2,
                messageId: "assistant-tool",
                toolCalls: [
                    .object([
                        "id": .string("tool-1"),
                        "function": .object([
                            "name": .string("read_file"),
                            "arguments": .string(
                                #"{"path":"README.md"}"#
                            ),
                        ]),
                    ])
                ],
                reasoning: "I should inspect the requested file first."
            ),
            ChatMessage(
                role: "tool",
                content: "Project documentation",
                timestamp: 3,
                messageId: "tool-result",
                toolCallId: "tool-1"
            ),
            ChatMessage(
                role: "assistant",
                content: "The file contains project documentation.",
                timestamp: 4,
                messageId: "assistant-answer"
            ),
        ]
        let viewModel = CompanionSessionHistoryViewModel(
            session: session,
            repository: RunHistoryRepositoryStub(
                session: session,
                historyMessagesByCall: [1: messages]
            ),
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            runService: RunServiceStub(
                eventResult: .holdOpen,
                statuses: []
            )
        )

        let didLoad = await viewModel.load()
        XCTAssertTrue(didLoad)

        XCTAssertEqual(
            ["I should inspect the requested file first."],
            viewModel.durableReasoningGroups.map(\.text)
        )
        XCTAssertEqual(1, viewModel.durableToolCallGroups.count)
        XCTAssertEqual(
            "read_file",
            viewModel.durableToolCallGroups.first?.toolCalls.first?.name
        )
        XCTAssertEqual(
            "Project documentation",
            viewModel.durableToolCallGroups.first?.toolCalls.first?.preview
        )
    }

    @MainActor
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let start = ContinuousClock.now
        while !condition(),
              ContinuousClock.now - start < .nanoseconds(
                Int64(timeoutNanoseconds)
              ) {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private actor RunHistoryRepositoryStub: SessionRepository {
    let detail: SessionSummary
    let failHistoryAfterCall: Int?
    let failHistoryCalls: Set<Int>
    let historyDelayByCall: [Int: UInt64]
    let historyMessagesByCall: [Int: [ChatMessage]]
    private(set) var historyCallCount = 0

    init(
        session: SessionSummary,
        failHistoryAfterCall: Int? = nil,
        failHistoryCalls: Set<Int> = [],
        historyDelayByCall: [Int: UInt64] = [:],
        historyMessagesByCall: [Int: [ChatMessage]] = [:]
    ) {
        detail = session
        self.failHistoryAfterCall = failHistoryAfterCall
        self.failHistoryCalls = failHistoryCalls
        self.historyDelayByCall = historyDelayByCall
        self.historyMessagesByCall = historyMessagesByCall
    }

    func listSessions(_ query: SessionListQuery) async throws -> SessionPage {
        SessionPage(
            sessions: [detail],
            limit: 50,
            offset: 0,
            hasMore: false
        )
    }

    func createSession(
        _ request: SessionCreateRequest
    ) async throws -> SessionSummary {
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
        historyCallCount += 1
        let call = historyCallCount
        if let delay = historyDelayByCall[call] {
            try await Task.sleep(nanoseconds: delay)
        }
        if let failHistoryAfterCall,
           call > failHistoryAfterCall {
            throw SessionRepositoryError.companionUnreachable
        }
        if failHistoryCalls.contains(call) {
            throw SessionRepositoryError.companionUnreachable
        }
        return SessionHistory(
            sessionID: id,
            messages: historyMessagesByCall[call] ?? []
        )
    }
}

private actor ActiveRunStoreStub: CompanionActiveRunStoring {
    private var records: [CompanionActiveRunKey: CompanionActiveRunRecord] = [:]
    private let activeRunDelayNanoseconds: UInt64

    init(activeRunDelayNanoseconds: UInt64 = 0) {
        self.activeRunDelayNanoseconds = activeRunDelayNanoseconds
    }

    func activeRun(
        for key: CompanionActiveRunKey
    ) async -> CompanionActiveRunRecord? {
        if activeRunDelayNanoseconds > 0 {
            try? await Task.sleep(
                nanoseconds: activeRunDelayNanoseconds
            )
        }
        return records[key]
    }

    func store(
        _ record: CompanionActiveRunRecord,
        for key: CompanionActiveRunKey
    ) async {
        records[key] = record
    }

    func updateStopState(
        _ state: CompanionStopRecoveryState,
        runID: String,
        for key: CompanionActiveRunKey
    ) async {
        guard var record = records[key], record.runID == runID else {
            return
        }
        record.stopState = state
        records[key] = record
    }

    func clear(
        runID: String,
        for key: CompanionActiveRunKey
    ) async {
        guard records[key]?.runID == runID else { return }
        records[key] = nil
    }
}

private actor RunServiceStub: ConversationRunServing {
    struct ApprovalRequest: Sendable {
        let runID: String
        let choice: ConversationApprovalChoice
    }

    enum EventResult {
        case disconnect
        case holdOpen
        case deltasThenWait([String], UInt64)
        case eventsThenWait([ConversationRunEvent], UInt64)
        case eventsAfterDelay([ConversationRunEvent], UInt64)
        case eventBatchesThenWait(
            [ConversationRunEvent],
            [ConversationRunEvent],
            UInt64,
            UInt64
        )
    }

    private let eventResult: EventResult
    private var statuses: [ConversationRunSnapshot]
    private(set) var startRequests: [ConversationRunStartRequest] = []
    private(set) var eventRunIDs: [String] = []
    private(set) var eventTerminationRunIDs: [String] = []
    private(set) var statusRunIDs: [String] = []
    private(set) var stopCallCount = 0
    private(set) var approvalRequests: [ApprovalRequest] = []
    private let stopError: ConversationRunServiceError?
    private let statusError: ConversationRunServiceError?
    private let approvalError: ConversationRunServiceError?
    private let holdsStartUntilReleased: Bool
    private let statusDelayNanoseconds: UInt64
    private let stopDelayNanoseconds: UInt64
    private let approvalDelayNanoseconds: UInt64
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var isStartReleased = false

    init(
        eventResult: EventResult,
        statuses: [ConversationRunSnapshot],
        statusError: ConversationRunServiceError? = nil,
        stopError: ConversationRunServiceError? = nil,
        approvalError: ConversationRunServiceError? = nil,
        holdsStartUntilReleased: Bool = false,
        statusDelayNanoseconds: UInt64 = 0,
        stopDelayNanoseconds: UInt64 = 0,
        approvalDelayNanoseconds: UInt64 = 0
    ) {
        self.eventResult = eventResult
        self.statuses = statuses
        self.statusError = statusError
        self.stopError = stopError
        self.approvalError = approvalError
        self.holdsStartUntilReleased = holdsStartUntilReleased
        self.statusDelayNanoseconds = statusDelayNanoseconds
        self.stopDelayNanoseconds = stopDelayNanoseconds
        self.approvalDelayNanoseconds = approvalDelayNanoseconds
    }

    func start(
        _ request: ConversationRunStartRequest
    ) async throws -> ConversationRunSnapshot {
        startRequests.append(request)
        if holdsStartUntilReleased, !isStartReleased {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        return ConversationRunSnapshot(
            runID: "run-1",
            state: .started,
            sessionID: request.sessionID,
            lastEvent: nil,
            output: nil,
            errorMessage: nil
        )
    }

    func releaseStart() {
        isStartReleased = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func status(runID: String) async throws -> ConversationRunSnapshot {
        statusRunIDs.append(runID)
        if statusDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: statusDelayNanoseconds)
        }
        if let statusError {
            throw statusError
        }
        guard !statuses.isEmpty else {
            throw ConversationRunServiceError.unexpectedResponse
        }
        return statuses.removeFirst()
    }

    func stop(runID: String) async throws -> ConversationRunSnapshot {
        stopCallCount += 1
        if stopDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: stopDelayNanoseconds)
        }
        if let stopError {
            throw stopError
        }
        return ConversationRunSnapshot(
            runID: runID,
            state: .stopping,
            sessionID: "session-1",
            lastEvent: "run.stopping",
            output: nil,
            errorMessage: nil
        )
    }

    func respondToApproval(
        runID: String,
        choice: ConversationApprovalChoice
    ) async throws -> ConversationApprovalResponse {
        approvalRequests.append(
            ApprovalRequest(runID: runID, choice: choice)
        )
        if approvalDelayNanoseconds > 0 {
            try? await Task.sleep(
                nanoseconds: approvalDelayNanoseconds
            )
        }
        if let approvalError {
            throw approvalError
        }
        return ConversationApprovalResponse(
            runID: runID,
            choice: choice,
            resolved: 1
        )
    }

    func events(
        runID: String
    ) async throws -> AsyncThrowingStream<ConversationRunEvent, Error> {
        eventRunIDs.append(runID)
        let result = eventResult
        return AsyncThrowingStream { continuation in
            switch result {
            case .disconnect:
                continuation.finish(
                    throwing: ConversationRunServiceError
                        .transportDisconnected
                )
            case .holdOpen:
                continuation.onTermination = { [weak self] _ in
                    Task {
                        await self?.recordEventTermination(runID)
                    }
                }
            case .deltasThenWait(let deltas, let delay):
                let task = Task {
                    for delta in deltas {
                        continuation.yield(
                            .data(
                                ConversationRunEventData(
                                    transportEvent: nil,
                                    event: "message.delta",
                                    runID: runID,
                                    delta: delta,
                                    output: nil,
                                    error: nil,
                                    timestamp: nil
                                )
                            )
                        )
                    }
                    try? await Task.sleep(nanoseconds: delay)
                    continuation.finish(
                        throwing: ConversationRunServiceError
                            .transportDisconnected
                    )
                }
                continuation.onTermination = { _ in task.cancel() }
            case .eventsThenWait(let events, let delay):
                let task = Task {
                    for event in events {
                        continuation.yield(event)
                    }
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            case .eventsAfterDelay(let events, let delay):
                let task = Task {
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            case .eventBatchesThenWait(
                let first,
                let second,
                let delayBetween,
                let closeDelay
            ):
                let task = Task {
                    for event in first {
                        continuation.yield(event)
                    }
                    try? await Task.sleep(
                        nanoseconds: delayBetween
                    )
                    for event in second {
                        continuation.yield(event)
                    }
                    try? await Task.sleep(
                        nanoseconds: closeDelay
                    )
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func recordEventTermination(_ runID: String) {
        eventTerminationRunIDs.append(runID)
    }
}

private actor ModelServiceStub: CompanionModelServing {
    private let inventory: CompanionModelInventory
    private(set) var lockedSelections: [CompanionModelSelection] = []
    private var lockDelayNanoseconds: UInt64 = 0

    init(inventory: CompanionModelInventory) {
        self.inventory = inventory
    }

    func fetchOptions(
        refresh: Bool
    ) async throws -> CompanionModelInventory {
        inventory
    }

    func setLockDelayNanoseconds(_ value: UInt64) {
        lockDelayNanoseconds = value
    }

    func lock(
        _ selection: CompanionModelSelection,
        sessionID: String
    ) async throws -> CompanionModelLockAcknowledgement {
        lockedSelections.append(selection)
        if lockDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: lockDelayNanoseconds)
        }
        return CompanionModelLockAcknowledgement(
            object: "hermes.session.model_lock",
            sessionID: sessionID,
            runtime: CompanionModelRuntime(
                provider: selection.provider,
                model: selection.model,
                modelLock: "accepted"
            )
        )
    }
}

private actor InMemoryModelSelectionStore:
    CompanionModelSelectionStoring
{
    private var selections: [String: CompanionModelSelection] = [:]

    func load(
        companionURL: URL,
        sessionID: String
    ) -> CompanionModelSelection? {
        selections[key(companionURL: companionURL, sessionID: sessionID)]
    }

    func save(
        _ selection: CompanionModelSelection,
        companionURL: URL,
        sessionID: String
    ) {
        selections[key(companionURL: companionURL, sessionID: sessionID)] =
            selection
    }

    private func key(companionURL: URL, sessionID: String) -> String {
        "\(companionURL.absoluteString)|\(sessionID)"
    }
}

private struct RunSSEChunk {
    let text: String
    let delayNanoseconds: UInt64
}

private final class RunJSONURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func configure(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        Self.lock.lock()
        handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RunSSEURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var chunks: [RunSSEChunk] = []
    private static var lastRequest: URLRequest?

    private var loadingTask: Task<Void, Never>?

    static func configure(chunks: [RunSSEChunk]) {
        lock.lock()
        self.chunks = chunks
        lastRequest = nil
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        chunks = []
        lastRequest = nil
        lock.unlock()
    }

    static func capturedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequest
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let configuredChunks: [RunSSEChunk]
        Self.lock.lock()
        Self.lastRequest = request
        configuredChunks = Self.chunks
        Self.lock.unlock()

        guard
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/event-stream; charset=utf-8",
                    "Cache-Control": "no-cache",
                ]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        loadingTask = Task { [weak self] in
            guard let self else { return }
            for chunk in configuredChunks {
                guard !Task.isCancelled else { return }
                if chunk.delayNanoseconds > 0 {
                    try? await Task.sleep(
                        nanoseconds: chunk.delayNanoseconds
                    )
                }
                guard !Task.isCancelled else { return }
                client?.urlProtocol(
                    self,
                    didLoad: Data(chunk.text.utf8)
                )
            }
            guard !Task.isCancelled else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}
