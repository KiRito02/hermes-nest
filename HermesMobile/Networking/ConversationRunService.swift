import Foundation

struct ConversationRunStartRequest: Equatable, Sendable {
    let input: String
    let sessionID: String
    let conversationHistory: [ChatMessage]
    let model: String?

    init(
        input: String,
        sessionID: String,
        conversationHistory: [ChatMessage],
        model: String? = nil
    ) {
        self.input = input
        self.sessionID = sessionID
        self.conversationHistory = conversationHistory
        self.model = model
    }
}

enum ConversationRunState: Equatable, Sendable {
    case started
    case queued
    case running
    case waitingForApproval
    case stopping
    case completed
    case failed
    case cancelled
    case unknown(String)

    init(wireValue: String) {
        switch wireValue {
        case "started": self = .started
        case "queued": self = .queued
        case "running": self = .running
        case "waiting_for_approval": self = .waitingForApproval
        case "stopping": self = .stopping
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown(wireValue)
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}

struct ConversationRunSnapshot: Equatable, Sendable {
    let runID: String
    let state: ConversationRunState
    let sessionID: String?
    let lastEvent: String?
    let output: String?
    let errorMessage: String?
}

enum ConversationApprovalChoice:
    String,
    CaseIterable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case once
    case session
    case always
    case deny
}

struct ConversationApprovalRequest: Equatable, Sendable {
    static let maximumCommandCharacters = 2_000
    static let maximumDescriptionCharacters = 1_000

    let runID: String
    let commandPreview: String?
    let description: String?
    let choices: [ConversationApprovalChoice]
    let timestamp: Double?
    let contextIsComplete: Bool
}

struct ConversationApprovalResponse: Equatable, Sendable {
    let runID: String
    let choice: ConversationApprovalChoice
    let resolved: Int
}

struct ConversationRunEventData: Equatable, Sendable {
    let transportEvent: String?
    let event: String?
    let runID: String?
    let delta: String?
    let text: String?
    let output: String?
    let error: String?
    let tool: String?
    let preview: String?
    let toolCallID: String?
    let duration: Double?
    let isError: Bool?
    let timestamp: Double?
    let command: String?
    let description: String?
    let approvalChoices: [String]?

    init(
        transportEvent: String?,
        event: String?,
        runID: String?,
        delta: String?,
        text: String? = nil,
        output: String?,
        error: String?,
        tool: String? = nil,
        preview: String? = nil,
        toolCallID: String? = nil,
        duration: Double? = nil,
        isError: Bool? = nil,
        timestamp: Double?,
        command: String? = nil,
        description: String? = nil,
        approvalChoices: [String]? = nil
    ) {
        self.transportEvent = transportEvent
        self.event = event
        self.runID = runID
        self.delta = delta
        self.text = text
        self.output = output
        self.error = error
        self.tool = tool
        self.preview = preview
        self.toolCallID = toolCallID
        self.duration = duration
        self.isError = isError
        self.timestamp = timestamp
        self.command = command
        self.description = description
        self.approvalChoices = approvalChoices
    }

    var semanticEvent: String? {
        event?.nilIfEmpty ?? transportEvent?.nilIfEmpty
    }

    func approvalRequest(
        expectedRunID: String
    ) -> ConversationApprovalRequest? {
        guard
            semanticEvent == "approval.request",
            runID == expectedRunID,
            let approvalChoices
        else {
            return nil
        }
        let boundedCommand = Self.bounded(
            command,
            maximumCharacters:
                ConversationApprovalRequest.maximumCommandCharacters
        )
        let boundedDescription = Self.bounded(
            description,
            maximumCharacters:
                ConversationApprovalRequest.maximumDescriptionCharacters
        )
        let contextIsComplete = (
            boundedCommand.value != nil
                || boundedDescription.value != nil
        ) && !boundedCommand.wasTruncated
            && !boundedDescription.wasTruncated
        var seen: Set<ConversationApprovalChoice> = []
        let verifiedChoices = approvalChoices.compactMap {
            ConversationApprovalChoice(rawValue: $0)
        }.filter {
            seen.insert($0).inserted
        }.filter {
            contextIsComplete || $0 == .deny
        }
        guard !verifiedChoices.isEmpty else { return nil }
        return ConversationApprovalRequest(
            runID: expectedRunID,
            commandPreview: boundedCommand.value,
            description: boundedDescription.value,
            choices: verifiedChoices,
            timestamp: timestamp,
            contextIsComplete: contextIsComplete
        )
    }

    private static func bounded(
        _ value: String?,
        maximumCharacters: Int
    ) -> (value: String?, wasTruncated: Bool) {
        guard let value else { return (nil, false) }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return (nil, false) }
        return (
            String(trimmed.prefix(maximumCharacters)),
            trimmed.count > maximumCharacters
        )
    }
}

enum ConversationRunEvent: Equatable, Sendable {
    case comment(String)
    case data(ConversationRunEventData)
    case malformed
}

struct ConversationRunSSEParser {
    private var transportEvent: String?
    private var dataLines: [String] = []

    mutating func consume(line: String) -> [ConversationRunEvent] {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") {
            let comment = String(line.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            return [.comment(comment)]
        }
        if line == "event" {
            transportEvent = ""
            return []
        }
        if line.hasPrefix("event:") {
            transportEvent = String(line.dropFirst("event:".count))
                .trimmingCharacters(in: .whitespaces)
            return []
        }
        if line == "data" {
            dataLines.append("")
            return []
        }
        if line.hasPrefix("data:") {
            var data = String(line.dropFirst("data:".count))
            if data.first == " " {
                data.removeFirst()
            }
            dataLines.append(data)
        }
        return []
    }

    mutating func finish() -> [ConversationRunEvent] {
        flush()
    }

    private mutating func flush() -> [ConversationRunEvent] {
        defer {
            transportEvent = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return [] }

        let joined = dataLines.joined(separator: "\n")
        guard
            let object = try? JSONSerialization.jsonObject(
                with: Data(joined.utf8)
            ) as? [String: Any]
        else {
            return [.malformed]
        }
        return [
            .data(
                ConversationRunEventData(
                    transportEvent: transportEvent?.nilIfEmpty,
                    event: Self.string(object["event"]),
                    runID: Self.string(object["run_id"]),
                    delta: Self.string(object["delta"]),
                    text: Self.string(object["text"]),
                    output: Self.string(object["output"]),
                    error: Self.string(object["error"]),
                    tool: Self.string(object["tool"]),
                    preview: Self.string(object["preview"]),
                    toolCallID: Self.string(object["tool_call_id"])
                        ?? Self.string(object["tool_use_id"])
                        ?? Self.string(object["id"]),
                    duration: Self.double(object["duration"]),
                    isError: Self.bool(object["is_error"])
                        ?? Self.bool(object["error"]),
                    timestamp: Self.double(object["timestamp"]),
                    command: Self.string(object["command"]),
                    description: Self.string(object["description"]),
                    approvalChoices: Self.stringArray(object["choices"])
                )
            )
        ]
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        return values.compactMap { $0 as? String }
    }
}

struct ConversationRunSSELineDecoder {
    private var buffer: [UInt8] = []
    private var previousByteWasCarriageReturn = false
    private let maximumLineBytes: Int

    init(
        maximumLineBytes: Int = ConversationRunService.maximumResponseBytes
    ) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func consume(byte: UInt8) throws -> String? {
        switch byte {
        case 0x0D:
            previousByteWasCarriageReturn = true
            return drain()
        case 0x0A:
            if previousByteWasCarriageReturn {
                previousByteWasCarriageReturn = false
                return nil
            }
            return drain()
        default:
            previousByteWasCarriageReturn = false
            guard buffer.count < maximumLineBytes else {
                throw ConversationRunServiceError.gatewayResponseTooLarge
            }
            buffer.append(byte)
            return nil
        }
    }

    mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        return drain()
    }

    private mutating func drain() -> String {
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }
}

protocol ConversationRunServing: Sendable {
    func start(
        _ request: ConversationRunStartRequest
    ) async throws -> ConversationRunSnapshot
    func status(runID: String) async throws -> ConversationRunSnapshot
    func stop(runID: String) async throws -> ConversationRunSnapshot
    func respondToApproval(
        runID: String,
        choice: ConversationApprovalChoice
    ) async throws -> ConversationApprovalResponse
    func events(
        runID: String
    ) async throws -> AsyncThrowingStream<ConversationRunEvent, Error>
}

enum ConversationRunServiceError: LocalizedError, Equatable {
    case missingDeviceCredential
    case invalidDeviceCredential
    case deviceRevoked
    case companionUnreachable
    case invalidRequest
    case invalidRunID
    case runNotFound
    case approvalNotPending
    case rateLimited
    case requestTooLarge
    case gatewayUnauthorized
    case gatewayUnavailable
    case gatewayIncompatible
    case gatewayMalformedResponse
    case gatewayResponseTooLarge
    case gatewayTimeout
    case gatewayTransportFailure
    case transportDisconnected
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .missingDeviceCredential, .invalidDeviceCredential:
            return String(localized: "This device must pair with Companion again.")
        case .deviceRevoked:
            return String(localized: "This device was revoked and must pair with Companion again.")
        case .companionUnreachable:
            return String(localized: "Hermes Nest Companion is unreachable.")
        case .invalidRequest:
            return String(localized: "Hermes rejected the run request.")
        case .invalidRunID:
            return String(localized: "The Hermes run identity is invalid.")
        case .runNotFound:
            return String(localized: "This Hermes run is no longer available.")
        case .approvalNotPending:
            return String(localized: "This approval already changed or expired. Checking the existing run.")
        case .rateLimited:
            return String(localized: "Hermes is already handling the maximum number of runs.")
        case .requestTooLarge:
            return String(localized: "The conversation history exceeded Companion's size limit.")
        case .gatewayUnauthorized:
            return String(localized: "Companion's NAS-local Gateway credential was rejected.")
        case .gatewayUnavailable:
            return String(localized: "Hermes Gateway is temporarily unavailable.")
        case .gatewayIncompatible:
            return String(localized: "This Hermes Gateway Runs API is incompatible.")
        case .gatewayMalformedResponse:
            return String(localized: "Hermes Gateway returned malformed run data.")
        case .gatewayResponseTooLarge:
            return String(localized: "The run response exceeded Companion's response limit.")
        case .gatewayTimeout:
            return String(localized: "Hermes Gateway took too long to respond.")
        case .gatewayTransportFailure:
            return String(localized: "Companion could not reach Hermes Gateway.")
        case .transportDisconnected:
            return String(localized: "The live response disconnected. Checking the existing run.")
        case .unexpectedResponse:
            return String(localized: "Companion returned an unexpected run response.")
        }
    }
}

actor ConversationRunService: ConversationRunServing {
    static let maximumResponseBytes = 2 * 1024 * 1024

    private let companionURL: URL
    private let keychain: any KeychainStoring
    private let session: URLSession
    private let decoder: JSONDecoder

    init(
        companionURL: URL,
        keychain: any KeychainStoring = KeychainStore(),
        session: URLSession? = nil
    ) {
        self.companionURL = companionURL
        self.keychain = keychain
        self.session = session ?? Self.makeSession()

        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    func start(
        _ request: ConversationRunStartRequest
    ) async throws -> ConversationRunSnapshot {
        let input = request.input.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !input.isEmpty else {
            throw ConversationRunServiceError.invalidRequest
        }
        let sessionID = try Self.validatedID(
            request.sessionID,
            error: .invalidRequest
        )
        let body = RunStartBody(
            input: input,
            sessionID: sessionID,
            conversationHistory: request.conversationHistory.compactMap {
                guard let role = $0.role, let content = $0.content else {
                    return nil
                }
                return RunHistoryMessage(role: role, content: content)
            },
            model: request.model
        )
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoded = try encoder.encode(body)
        } catch {
            throw ConversationRunServiceError.invalidRequest
        }
        let data = try await sendJSON(
            url: runsURL(),
            method: "POST",
            body: encoded,
            expectedStatusCodes: [202]
        )
        return try snapshot(from: data)
    }

    func status(runID: String) async throws -> ConversationRunSnapshot {
        let data = try await sendJSON(
            url: try runURL(runID: runID),
            method: "GET",
            expectedStatusCodes: [200]
        )
        let snapshot = try snapshot(from: data)
        guard snapshot.runID == runID else {
            throw ConversationRunServiceError.unexpectedResponse
        }
        return snapshot
    }

    func stop(runID: String) async throws -> ConversationRunSnapshot {
        let data = try await sendJSON(
            url: try runURL(runID: runID, action: "stop"),
            method: "POST",
            expectedStatusCodes: [200]
        )
        let snapshot = try snapshot(from: data)
        guard snapshot.runID == runID else {
            throw ConversationRunServiceError.unexpectedResponse
        }
        return snapshot
    }

    func respondToApproval(
        runID: String,
        choice: ConversationApprovalChoice
    ) async throws -> ConversationApprovalResponse {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(
                RunApprovalBody(choice: choice)
            )
        } catch {
            throw ConversationRunServiceError.invalidRequest
        }
        let data = try await sendJSON(
            url: try runURL(runID: runID, action: "approval"),
            method: "POST",
            body: encoded,
            expectedStatusCodes: [200]
        )
        let payload: RunApprovalWireResponse
        do {
            payload = try decoder.decode(
                RunApprovalWireResponse.self,
                from: data
            )
        } catch {
            throw ConversationRunServiceError.unexpectedResponse
        }
        guard
            payload.object == "hermes.run.approval_response",
            payload.runID == runID,
            payload.choice == choice,
            let resolved = payload.resolved,
            resolved > 0
        else {
            throw ConversationRunServiceError.unexpectedResponse
        }
        return ConversationApprovalResponse(
            runID: runID,
            choice: choice,
            resolved: resolved
        )
    }

    func events(
        runID: String
    ) async throws -> AsyncThrowingStream<ConversationRunEvent, Error> {
        let credential = try deviceCredential()
        var request = URLRequest(
            url: try runURL(runID: runID, action: "events")
        )
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "text/event-stream",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "no-cache, no-transform",
            forHTTPHeaderField: "Cache-Control"
        )
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(
            "Bearer \(credential)",
            forHTTPHeaderField: "Authorization"
        )

        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ConversationRunServiceError.unexpectedResponse
                    }
                    guard httpResponse.statusCode == 200 else {
                        let data = try await Self.boundedData(from: bytes)
                        throw Self.mapHTTPError(
                            statusCode: httpResponse.statusCode,
                            data: data
                        )
                    }
                    guard httpResponse.mimeType == "text/event-stream" else {
                        throw ConversationRunServiceError.unexpectedResponse
                    }

                    var lineDecoder = ConversationRunSSELineDecoder()
                    var parser = ConversationRunSSEParser()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let line = try lineDecoder.consume(byte: byte)
                        else {
                            continue
                        }
                        for event in parser.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    if let finalLine = lineDecoder.finish() {
                        for event in parser.consume(line: finalLine) {
                            continuation.yield(event)
                        }
                    }
                    for event in parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as ConversationRunServiceError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: ConversationRunServiceError
                            .transportDisconnected
                    )
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func sendJSON(
        url: URL,
        method: String,
        body: Data? = nil,
        expectedStatusCodes: Set<Int>
    ) async throws -> Data {
        let credential = try deviceCredential()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "Bearer \(credential)",
            forHTTPHeaderField: "Authorization"
        )
        if body != nil {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ConversationRunServiceError.companionUnreachable
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConversationRunServiceError.unexpectedResponse
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw ConversationRunServiceError.gatewayResponseTooLarge
        }
        guard expectedStatusCodes.contains(httpResponse.statusCode) else {
            throw Self.mapHTTPError(
                statusCode: httpResponse.statusCode,
                data: data
            )
        }
        guard httpResponse.mimeType == "application/json" else {
            throw ConversationRunServiceError.unexpectedResponse
        }
        return data
    }

    private func snapshot(from data: Data) throws -> ConversationRunSnapshot {
        let payload: RunWireResponse
        do {
            payload = try decoder.decode(RunWireResponse.self, from: data)
        } catch {
            throw ConversationRunServiceError.unexpectedResponse
        }
        guard
            let runID = payload.runID?.nilIfEmpty,
            let status = payload.status?.nilIfEmpty
        else {
            throw ConversationRunServiceError.unexpectedResponse
        }
        return ConversationRunSnapshot(
            runID: runID,
            state: ConversationRunState(wireValue: status),
            sessionID: payload.sessionID?.nilIfEmpty,
            lastEvent: payload.lastEvent?.nilIfEmpty,
            output: payload.output,
            errorMessage: payload.error
        )
    }

    private func deviceCredential() throws -> String {
        guard
            let credential = try? keychain.load(
                .companionDeviceCredential
            ),
            !credential.isEmpty
        else {
            throw ConversationRunServiceError.missingDeviceCredential
        }
        return credential
    }

    private func runsURL() -> URL {
        companionURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: false)
    }

    private func runURL(
        runID: String,
        action: String? = nil
    ) throws -> URL {
        var url = runsURL().appendingPathComponent(
            try Self.validatedID(runID, error: .invalidRunID)
        )
        if let action {
            url.appendPathComponent(action)
        }
        return url
    }

    private static func validatedID(
        _ value: String,
        error: ConversationRunServiceError
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
            throw error
        }
        return value
    }

    private static func boundedData(
        from bytes: URLSession.AsyncBytes
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw ConversationRunServiceError.gatewayResponseTooLarge
            }
            data.append(byte)
        }
        return data
    }

    private static func mapHTTPError(
        statusCode: Int,
        data: Data
    ) -> ConversationRunServiceError {
        let decoder = JSONDecoder()
        let code = (
            try? decoder.decode(RunErrorEnvelope.self, from: data)
        )?.error?.code
        switch (statusCode, code) {
        case (401, "device_credential_invalid"):
            return .invalidDeviceCredential
        case (403, "device_revoked"):
            return .deviceRevoked
        case (400, "invalid_run_id"):
            return .invalidRunID
        case (400, _):
            return .invalidRequest
        case (404, "run_not_found"):
            return .runNotFound
        case (409, "approval_not_active"),
             (409, "approval_not_pending"):
            return .approvalNotPending
        case (429, _):
            return .rateLimited
        case (413, "request_too_large"):
            return .requestTooLarge
        case (502, "gateway_unauthorized"):
            return .gatewayUnauthorized
        case (503, "gateway_unavailable"):
            return .gatewayUnavailable
        case (502, "gateway_incompatible"):
            return .gatewayIncompatible
        case (502, "gateway_malformed_response"):
            return .gatewayMalformedResponse
        case (502, "gateway_response_too_large"):
            return .gatewayResponseTooLarge
        case (504, "gateway_timeout"):
            return .gatewayTimeout
        case (503, "gateway_transport_failure"):
            return .gatewayTransportFailure
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
}

private struct RunHistoryMessage: Encodable {
    let role: String
    let content: String
}

private struct RunStartBody: Encodable {
    let input: String
    let sessionID: String
    let conversationHistory: [RunHistoryMessage]
    let model: String?

    enum CodingKeys: String, CodingKey {
        case input
        case sessionID = "session_id"
        case conversationHistory = "conversation_history"
        case model
    }
}

private struct RunApprovalBody: Encodable {
    let choice: ConversationApprovalChoice
}

private struct RunApprovalWireResponse: Decodable {
    let object: String?
    let runID: String?
    let choice: ConversationApprovalChoice?
    let resolved: Int?

    enum CodingKeys: String, CodingKey {
        case object
        case runID = "run_id"
        case choice
        case resolved
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = container.decodeLossyStringIfPresent(forKey: .object)
        runID = container.decodeLossyStringIfPresent(forKey: .runID)
        choice = try? container.decodeIfPresent(
            ConversationApprovalChoice.self,
            forKey: .choice
        )
        resolved = container.decodeLossyIntIfPresent(forKey: .resolved)
    }
}

private struct RunWireResponse: Decodable {
    let runID: String?
    let status: String?
    let sessionID: String?
    let lastEvent: String?
    let output: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case status
        case sessionID = "session_id"
        case lastEvent = "last_event"
        case output
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = container.decodeLossyStringIfPresent(forKey: .runID)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        sessionID = container.decodeLossyStringIfPresent(forKey: .sessionID)
        lastEvent = container.decodeLossyStringIfPresent(forKey: .lastEvent)
        output = container.decodeLossyStringIfPresent(forKey: .output)
        error = container.decodeLossyStringIfPresent(forKey: .error)
    }
}

private struct RunErrorEnvelope: Decodable {
    let error: RunErrorBody?
}

private struct RunErrorBody: Decodable {
    let code: String?
    let message: String?
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
