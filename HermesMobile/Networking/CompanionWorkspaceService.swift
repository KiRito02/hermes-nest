import Foundation

actor CompanionWorkspaceService: CompanionWorkspaceServing {
    static let maximumUploadBytes = 50 * 1_024 * 1_024
    static let maximumResponseBytes = 50 * 1_024 * 1_024

    private let companionURL: URL
    private let keychain: any KeychainStoring
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(
        companionURL: URL,
        keychain: any KeychainStoring = KeychainStore(),
        session: URLSession? = nil
    ) {
        self.companionURL = companionURL
        self.keychain = keychain
        self.session = session ?? Self.makeSession()
    }

    func roots() async throws -> [CompanionWorkspaceRoot] {
        let data = try await send(
            path: "/companion/v1/files/roots",
            method: "GET"
        )
        let envelope = try decode(
            CompanionWorkspaceRootsEnvelope.self,
            from: data
        )
        return envelope.roots ?? []
    }

    func entries(
        rootID: String,
        path: String,
        cursor: String? = nil
    ) async throws -> CompanionWorkspacePage {
        let rootID = try Self.validatedPathComponent(rootID)
        var components = URLComponents(
            url: url(
                for: "/companion/v1/files/roots/\(rootID)/entries"
            ),
            resolvingAgainstBaseURL: false
        )
        var query = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "limit", value: "100"),
        ]
        if let cursor {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components?.queryItems = query
        guard let url = components?.url else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }
        let data = try await send(url: url, method: "GET")
        return try decode(CompanionWorkspacePage.self, from: data)
    }

    func download(rootID: String, path: String) async throws -> Data {
        let rootID = try Self.validatedPathComponent(rootID)
        var components = URLComponents(
            url: url(
                for: "/companion/v1/files/roots/\(rootID)/download"
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }
        return try await send(url: url, method: "GET")
    }

    func preview(
        rootID: String,
        path: String
    ) async throws -> CompanionWorkspacePreview {
        let rootID = try Self.validatedPathComponent(rootID)
        var components = URLComponents(
            url: url(
                for: "/companion/v1/files/roots/\(rootID)/preview"
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }
        let data = try await send(url: url, method: "GET")
        return try decode(CompanionWorkspacePreview.self, from: data)
    }

    func upload(
        sessionID: String,
        destination: CompanionUploadDestination,
        filename: String,
        contentType: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> CompanionUpload {
        guard
            !sessionID.isEmpty,
            sessionID.count <= 256,
            !destination.rootID.isEmpty,
            !filename.isEmpty,
            data.count <= Self.maximumUploadBytes
        else {
            throw data.count > Self.maximumUploadBytes
                ? CompanionWorkspaceServiceError.requestTooLarge
                : CompanionWorkspaceServiceError.invalidRequest
        }
        let metadata = try JSONSerialization.data(
            withJSONObject: [
                "root_id": destination.rootID,
                "directory": destination.directory,
                "session_id": sessionID,
            ],
            options: [.sortedKeys]
        )
        let boundary = "HermesNest-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"metadata\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: application/json\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        let safeFilename = filename
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let response = try await sendUpload(
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            progress: progress
        )
        let envelope = try decode(
            CompanionUploadEnvelope.self,
            from: response
        )
        guard
            let upload = envelope.upload,
            upload.id?.nilIfEmpty != nil,
            upload.state == "ready"
        else {
            throw CompanionWorkspaceServiceError.unexpectedResponse
        }
        return upload
    }

    private func sendUpload(
        body: Data,
        contentType: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        var request = URLRequest(url: url(for: "/companion/v1/uploads"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Bearer \(try deviceCredential())",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let delegate = CompanionUploadProgressDelegate(progress: progress)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(
                for: request,
                from: body,
                delegate: delegate
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CompanionWorkspaceServiceError.companionUnreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw CompanionWorkspaceServiceError.unexpectedResponse
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw CompanionWorkspaceServiceError.requestTooLarge
        }
        guard http.statusCode == 201 else {
            throw Self.mapHTTPError(status: http.statusCode, data: data)
        }
        progress(1)
        return data
    }

    func deleteUpload(id: String) async throws {
        let id = try Self.validatedPathComponent(id)
        _ = try await send(
            path: "/companion/v1/uploads/\(id)",
            method: "DELETE",
            expectedStatus: 204
        )
    }

    func uploads(sessionID: String) async throws -> [CompanionUpload] {
        guard !sessionID.isEmpty, sessionID.count <= 256 else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }
        var components = URLComponents(
            url: url(for: "/companion/v1/uploads"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "session_id", value: sessionID)
        ]
        guard let url = components?.url else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }
        let data = try await send(url: url, method: "GET")
        let envelope = try decode(
            CompanionUploadsEnvelope.self,
            from: data
        )
        return (envelope.uploads ?? []).filter {
            $0.id?.nilIfEmpty != nil && $0.state == "ready"
        }
    }

    func memory(target: String) async throws -> CompanionMemorySnapshot {
        let target = try Self.validatedMemoryTarget(target)
        let data = try await send(
            path: "/companion/v1/memory/\(target)",
            method: "GET"
        )
        return try decode(CompanionMemorySnapshot.self, from: data)
    }

    func mutateMemory(
        target: String,
        revision: String,
        operations: [CompanionMemoryOperation]
    ) async throws -> CompanionMemorySnapshot {
        let target = try Self.validatedMemoryTarget(target)
        let body = try JSONEncoder().encode(
            CompanionMemoryOperationsRequest(
                revision: revision,
                operations: operations
            )
        )
        let data = try await send(
            path: "/companion/v1/memory/\(target)/operations",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        return try decode(CompanionMemorySnapshot.self, from: data)
    }

    func resetMemory(
        target: String,
        revision: String,
        confirmation: String
    ) async throws -> CompanionMemorySnapshot {
        let target = try Self.validatedMemoryTarget(target)
        let body = try JSONEncoder().encode(
            CompanionMemoryResetRequest(
                revision: revision,
                confirmation: confirmation
            )
        )
        let data = try await send(
            path: "/companion/v1/memory/\(target)/reset",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        return try decode(CompanionMemorySnapshot.self, from: data)
    }

    private func send(
        path: String,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        expectedStatus: Int = 200
    ) async throws -> Data {
        try await send(
            url: url(for: path),
            method: method,
            body: body,
            contentType: contentType,
            expectedStatus: expectedStatus
        )
    }

    private func url(for path: String) -> URL {
        path.split(separator: "/").reduce(companionURL) { partial, segment in
            partial.appendingPathComponent(String(segment))
        }
    }

    private func send(
        url: URL,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        expectedStatus: Int = 200
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Bearer \(try deviceCredential())",
            forHTTPHeaderField: "Authorization"
        )
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CompanionWorkspaceServiceError.companionUnreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw CompanionWorkspaceServiceError.unexpectedResponse
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw CompanionWorkspaceServiceError.requestTooLarge
        }
        guard http.statusCode == expectedStatus else {
            throw Self.mapHTTPError(status: http.statusCode, data: data)
        }
        return data
    }

    private func deviceCredential() throws -> String {
        guard
            let credential = try? keychain.load(
                .companionDeviceCredential
            ),
            !credential.isEmpty
        else {
            throw CompanionWorkspaceServiceError.missingDeviceCredential
        }
        return credential
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw CompanionWorkspaceServiceError.unexpectedResponse
        }
    }

    private static func validatedPathComponent(
        _ value: String
    ) throws -> String {
        guard
            !value.isEmpty,
            value.count <= 128,
            !value.contains("/"),
            !value.contains("\\"),
            !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }
        return value
    }

    private static func validatedMemoryTarget(
        _ value: String
    ) throws -> String {
        guard value == "memory" || value == "user" else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }
        return value
    }

    private static func mapHTTPError(
        status: Int,
        data: Data
    ) -> CompanionWorkspaceServiceError {
        let envelope = try? JSONDecoder().decode(
            CompanionWorkspaceErrorEnvelope.self,
            from: data
        )
        let code = envelope?.error?.code
        let message = envelope?.error?.message
        switch (status, code) {
        case (401, "device_credential_invalid"):
            return .invalidDeviceCredential
        case (403, "device_revoked"):
            return .deviceRevoked
        case (409, "memory_not_configured"):
            return .notConfigured
        case (409, _):
            return .conflict(message)
        case (413, _):
            return .requestTooLarge
        case (400, _), (404, _):
            return .invalidRequest
        default:
            return .unexpectedResponse
        }
    }

    private static func makeSession() -> URLSession {
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

private struct CompanionWorkspaceRootsEnvelope: Decodable {
    let roots: [CompanionWorkspaceRoot]?
}

private struct CompanionUploadEnvelope: Decodable {
    let upload: CompanionUpload?
}

private struct CompanionUploadsEnvelope: Decodable {
    let uploads: [CompanionUpload]?
}

private struct CompanionMemoryOperationsRequest: Encodable {
    let revision: String?
    let operations: [CompanionMemoryOperation]?
}

private struct CompanionMemoryResetRequest: Encodable {
    let revision: String?
    let confirmation: String?
}

private struct CompanionWorkspaceErrorEnvelope: Decodable {
    let error: CompanionWorkspaceErrorBody?
}

private struct CompanionWorkspaceErrorBody: Decodable {
    let code: String?
    let message: String?
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
