import Foundation

struct SessionCreateRequest: Encodable, Equatable, Sendable {
    let id: String?
    let title: String?
    let model: String?
    let systemPrompt: String?
    let source: String?

    init(
        id: String? = nil,
        title: String? = nil,
        model: String? = nil,
        systemPrompt: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.title = title
        self.model = model
        self.systemPrompt = systemPrompt
        self.source = source
    }
}

struct SessionUpdateRequest: Encodable, Equatable, Sendable {
    let title: String?
    let endReason: String?

    init(title: String? = nil, endReason: String? = nil) {
        self.title = title
        self.endReason = endReason
    }
}

struct SessionForkRequest: Encodable, Equatable, Sendable {
    let id: String?
    let title: String?

    init(id: String? = nil, title: String? = nil) {
        self.id = id
        self.title = title
    }
}

struct SessionHistory: Equatable, Sendable {
    let sessionID: String
    let messages: [ChatMessage]
}

extension LiveSessionRepository {
    func createSession(
        _ request: SessionCreateRequest
    ) async throws -> SessionSummary {
        try await sessionMutation(
            url: try sessionURL(),
            method: "POST",
            body: request,
            expectedStatusCodes: [201]
        )
    }

    func session(id: String) async throws -> SessionSummary {
        let data = try await sendJSONRequest(
            url: try sessionURL(id: id),
            method: "GET",
            expectedStatusCodes: [200]
        )
        return try decodeSession(data)
    }

    func updateSession(
        id: String,
        request: SessionUpdateRequest
    ) async throws -> SessionSummary {
        try await sessionMutation(
            url: try sessionURL(id: id),
            method: "PATCH",
            body: request,
            expectedStatusCodes: [200]
        )
    }

    func deleteSession(id: String) async throws -> Bool {
        let data = try await sendJSONRequest(
            url: try sessionURL(id: id),
            method: "DELETE",
            expectedStatusCodes: [200]
        )
        let payload: GatewaySessionDeletePayload
        do {
            payload = try decoder.decode(
                GatewaySessionDeletePayload.self,
                from: data
            )
        } catch {
            throw SessionRepositoryError.unexpectedResponse
        }
        guard
            payload.object == "hermes.session.deleted",
            payload.id == id,
            let deleted = payload.deleted
        else {
            throw SessionRepositoryError.unexpectedResponse
        }
        return deleted
    }

    func forkSession(
        id: String,
        request: SessionForkRequest
    ) async throws -> SessionSummary {
        try await sessionMutation(
            url: try sessionURL(id: id, action: "fork"),
            method: "POST",
            body: request,
            expectedStatusCodes: [201]
        )
    }

    func messageHistory(id: String) async throws -> SessionHistory {
        let data = try await sendJSONRequest(
            url: try sessionURL(id: id, action: "messages"),
            method: "GET",
            expectedStatusCodes: [200]
        )
        let payload: GatewaySessionHistoryPayload
        do {
            payload = try decoder.decode(
                GatewaySessionHistoryPayload.self,
                from: data
            )
        } catch {
            throw SessionRepositoryError.unexpectedResponse
        }
        guard
            payload.object == "list",
            let resolvedSessionID = Self.nonEmpty(payload.sessionID),
            let rows = payload.data
        else {
            throw SessionRepositoryError.unexpectedResponse
        }
        return SessionHistory(
            sessionID: resolvedSessionID,
            messages: rows.enumerated().map { index, row in
                row.chatMessage(
                    sessionID: resolvedSessionID,
                    fallbackIndex: index
                )
            }
        )
    }

    private func sessionMutation<Body: Encodable>(
        url: URL,
        method: String,
        body: Body,
        expectedStatusCodes: Set<Int>
    ) async throws -> SessionSummary {
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoded = try encoder.encode(body)
        } catch {
            throw SessionRepositoryError.invalidSessionMetadata
        }
        let data = try await sendJSONRequest(
            url: url,
            method: method,
            body: encoded,
            expectedStatusCodes: expectedStatusCodes
        )
        return try decodeSession(data)
    }

    private func decodeSession(_ data: Data) throws -> SessionSummary {
        let payload: GatewaySessionEnvelope
        do {
            payload = try decoder.decode(GatewaySessionEnvelope.self, from: data)
        } catch {
            throw SessionRepositoryError.unexpectedResponse
        }
        guard
            payload.object == "hermes.session",
            let session = payload.session?.sessionSummary
        else {
            throw SessionRepositoryError.unexpectedResponse
        }
        return session
    }

    private func sessionURL(
        id: String? = nil,
        action: String? = nil
    ) throws -> URL {
        var endpoint = companionURL
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: false)
        if let id {
            endpoint.appendPathComponent(try Self.validatedSessionID(id))
        } else if action != nil {
            throw SessionRepositoryError.invalidSessionID
        }
        if let action {
            endpoint.appendPathComponent(action)
        }
        return endpoint
    }

    private static func validatedSessionID(_ id: String) throws -> String {
        guard
            !id.isEmpty,
            id.count <= 256,
            !id.contains("/"),
            !id.contains("\\"),
            !id.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw SessionRepositoryError.invalidSessionID
        }
        return id
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

}

private struct GatewaySessionEnvelope: Decodable {
    let object: String?
    let session: GatewaySessionPayload?

    enum CodingKeys: String, CodingKey {
        case object
        case session
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try? container.decodeIfPresent(String.self, forKey: .object)
        session = try? container.decodeIfPresent(
            GatewaySessionPayload.self,
            forKey: .session
        )
    }
}

private struct GatewaySessionDeletePayload: Decodable {
    let object: String?
    let id: String?
    let deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case object
        case id
        case deleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try? container.decodeIfPresent(String.self, forKey: .object)
        id = container.decodeLossyStringIfPresent(forKey: .id)
        deleted = container.decodeLossyBoolIfPresent(forKey: .deleted)
    }
}

private struct GatewaySessionHistoryPayload: Decodable {
    let object: String?
    let sessionID: String?
    let data: [GatewayMessagePayload]?

    enum CodingKeys: String, CodingKey {
        case object
        case sessionID = "sessionId"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try? container.decodeIfPresent(String.self, forKey: .object)
        sessionID = container.decodeLossyStringIfPresent(forKey: .sessionID)
        data = try? container.decodeIfPresent(
            [GatewayMessagePayload].self,
            forKey: .data
        )
    }
}

private struct GatewayMessagePayload: Decodable {
    let id: String?
    let role: String?
    let content: JSONValue?
    let toolCallID: String?
    let toolCalls: [JSONValue]?
    let toolName: String?
    let timestamp: Double?
    let reasoning: String?
    let reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case toolCallID = "toolCallId"
        case toolCalls
        case toolName
        case timestamp
        case reasoning
        case reasoningContent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyStringIfPresent(forKey: .id)
        role = container.decodeLossyStringIfPresent(forKey: .role)
        content = try? container.decodeIfPresent(JSONValue.self, forKey: .content)
        toolCallID = container.decodeLossyStringIfPresent(forKey: .toolCallID)
        toolCalls = try? container.decodeIfPresent(
            [JSONValue].self,
            forKey: .toolCalls
        )
        toolName = container.decodeLossyStringIfPresent(forKey: .toolName)
        timestamp = container.decodeLossyDoubleIfPresent(forKey: .timestamp)
        reasoning = container.decodeLossyStringIfPresent(forKey: .reasoning)
        reasoningContent = container.decodeLossyStringIfPresent(
            forKey: .reasoningContent
        )
    }

    func chatMessage(
        sessionID: String,
        fallbackIndex: Int
    ) -> ChatMessage {
        let identity = id ?? "position-\(fallbackIndex)"
        return ChatMessage(
            role: role,
            content: textContent,
            timestamp: timestamp,
            messageId: "\(sessionID):message:\(identity)",
            name: toolName,
            toolCallId: toolCallID,
            toolCalls: toolCalls,
            contentParts: contentParts,
            reasoning: reasoning ?? reasoningContent
        )
    }

    private var contentParts: [JSONValue]? {
        guard case .array(let parts) = content else { return nil }
        return parts
    }

    private var textContent: String? {
        guard let content else { return nil }
        switch content {
        case .string(let value):
            return value
        case .array(let parts):
            let text = parts.compactMap { part -> String? in
                guard case .object(let object) = part else { return nil }
                return object["text"]?.stringValue
            }
            .joined()
            return text.isEmpty ? nil : text
        default:
            return content.compactJSONString
        }
    }
}

private extension JSONValue {
    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.formatted()
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array, .null:
            return nil
        }
    }

    var compactJSONString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
