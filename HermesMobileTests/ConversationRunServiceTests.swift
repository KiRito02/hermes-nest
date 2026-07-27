import XCTest
import SwiftData
@testable import HermesMobile

final class ConversationRunServiceTests: APIClientTestCase {
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
        XCTAssertEqual(100, viewModel.latestRunUsage?.totalTokens)
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
        let didSend = await viewModel.send("Stream")
        XCTAssertTrue(didSend)

        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual("", viewModel.streamedAssistantText)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual("ABC", viewModel.streamedAssistantText)

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
        await waitUntil { viewModel.activeRunID == nil }
    }

    func testProgressiveBufferDrainsWithABoundedPerTickBudget() {
        var buffer = ConversationRunDeltaBuffer()
        let expected = String(repeating: "x", count: 10_000)
        var reconstructed = buffer.append(expected)

        XCTAssertLessThanOrEqual(
            buffer.pendingText.count,
            ConversationRunDeltaBuffer.maximumPendingCharacters
        )

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

        await viewModel.stopRun()
        await waitUntil { viewModel.activeRunID == nil }
    }

    @MainActor
    func testTerminalOutputSurvivesAuthoritativeHistoryRefreshFailure() async throws {
        let session = try makeSessionSummary()
        let authoritativeReply = ChatMessage(
            role: "assistant",
            content: "Authoritative final answer",
            timestamp: 5,
            messageId: "assistant-1"
        )
        let repository = RunHistoryRepositoryStub(
            session: session,
            failHistoryCalls: [2],
            historyMessagesByCall: [3: [authoritativeReply]]
        )
        let terminal = ConversationRunEvent.data(
            ConversationRunEventData(
                transportEvent: "run.completed",
                event: nil,
                runID: "run-1",
                delta: nil,
                output: "Fallback final answer",
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
        await waitUntil { viewModel.needsTerminalHistoryRetry }

        XCTAssertEqual(.completed, viewModel.runState)
        XCTAssertEqual(
            "Fallback final answer",
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
                timestamp: 2
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
                    output: nil,
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

    private func makeSessionSummary() throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data(
                """
                {
                  "session_id": "session-1",
                  "title": "Run test",
                  "source": "api_server"
                }
                """.utf8
            )
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
    private(set) var statusRunIDs: [String] = []
    private(set) var stopCallCount = 0
    private(set) var approvalRequests: [ApprovalRequest] = []
    private let stopError: ConversationRunServiceError?
    private let approvalError: ConversationRunServiceError?
    private let statusDelayNanoseconds: UInt64
    private let stopDelayNanoseconds: UInt64
    private let approvalDelayNanoseconds: UInt64

    init(
        eventResult: EventResult,
        statuses: [ConversationRunSnapshot],
        stopError: ConversationRunServiceError? = nil,
        approvalError: ConversationRunServiceError? = nil,
        statusDelayNanoseconds: UInt64 = 0,
        stopDelayNanoseconds: UInt64 = 0,
        approvalDelayNanoseconds: UInt64 = 0
    ) {
        self.eventResult = eventResult
        self.statuses = statuses
        self.stopError = stopError
        self.approvalError = approvalError
        self.statusDelayNanoseconds = statusDelayNanoseconds
        self.stopDelayNanoseconds = stopDelayNanoseconds
        self.approvalDelayNanoseconds = approvalDelayNanoseconds
    }

    func start(
        _ request: ConversationRunStartRequest
    ) async throws -> ConversationRunSnapshot {
        startRequests.append(request)
        return ConversationRunSnapshot(
            runID: "run-1",
            state: .started,
            sessionID: request.sessionID,
            lastEvent: nil,
            output: nil,
            errorMessage: nil
        )
    }

    func status(runID: String) async throws -> ConversationRunSnapshot {
        statusRunIDs.append(runID)
        if statusDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: statusDelayNanoseconds)
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
        let result = eventResult
        return AsyncThrowingStream { continuation in
            switch result {
            case .disconnect:
                continuation.finish(
                    throwing: ConversationRunServiceError
                        .transportDisconnected
                )
            case .holdOpen:
                continuation.onTermination = { _ in }
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
