import Foundation

struct CompanionWorkspaceRoot: Decodable, Equatable, Sendable {
    let id: String?
    let name: String?
    let writable: Bool?
    let attachable: Bool?
}

struct CompanionWorkspaceEntry: Decodable, Equatable, Sendable {
    let name: String?
    let path: String?
    let kind: String?
    let size: Int?

    var isDirectory: Bool {
        kind == "directory"
    }
}

struct CompanionWorkspacePage: Decodable, Equatable, Sendable {
    let rootID: String?
    let path: String?
    let entries: [CompanionWorkspaceEntry]?
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case rootID = "root_id"
        case path
        case entries
        case nextCursor = "next_cursor"
    }
}

struct CompanionWorkspacePreview: Decodable, Equatable, Sendable {
    let rootID: String?
    let path: String?
    let name: String?
    let kind: String?
    let contentType: String?
    let size: Int?
    let truncated: Bool?
    let content: String?

    enum CodingKeys: String, CodingKey {
        case rootID = "root_id"
        case path
        case name
        case kind
        case contentType = "content_type"
        case size
        case truncated
        case content
    }
}

struct CompanionUpload: Decodable, Equatable, Sendable {
    let id: String?
    let rootID: String?
    let path: String?
    let name: String?
    let size: Int?
    let contentType: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case id
        case rootID = "root_id"
        case path
        case name
        case size
        case contentType = "content_type"
        case state
    }

    var messageAttachment: MessageAttachment {
        MessageAttachment(
            name: name,
            path: path,
            mime: contentType,
            size: size,
            isImage: contentType?.lowercased().hasPrefix("image/") == true
        )
    }
}

struct CompanionMemorySnapshot: Decodable, Equatable, Sendable {
    let target: String?
    let entries: [String]?
    let revision: String?
    let charCount: Int?
    let charLimit: Int?

    enum CodingKeys: String, CodingKey {
        case target
        case entries
        case revision
        case charCount = "char_count"
        case charLimit = "char_limit"
    }
}

struct CompanionMemoryOperation: Encodable, Equatable, Sendable {
    let action: String?
    let oldText: String?
    let content: String?

    enum CodingKeys: String, CodingKey {
        case action
        case oldText = "old_text"
        case content
    }
}

struct CompanionUploadDestination: Equatable, Sendable {
    let rootID: String
    let directory: String
}

protocol CompanionWorkspaceServing: Sendable {
    func roots() async throws -> [CompanionWorkspaceRoot]
    func entries(
        rootID: String,
        path: String,
        cursor: String?
    ) async throws -> CompanionWorkspacePage
    func preview(
        rootID: String,
        path: String
    ) async throws -> CompanionWorkspacePreview
    func download(rootID: String, path: String) async throws -> Data
    func upload(
        sessionID: String,
        destination: CompanionUploadDestination,
        filename: String,
        contentType: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CompanionUpload
    func uploads(sessionID: String) async throws -> [CompanionUpload]
    func deleteUpload(id: String) async throws
    func memory(target: String) async throws -> CompanionMemorySnapshot
    func mutateMemory(
        target: String,
        revision: String,
        operations: [CompanionMemoryOperation]
    ) async throws -> CompanionMemorySnapshot
    func resetMemory(
        target: String,
        revision: String,
        confirmation: String
    ) async throws -> CompanionMemorySnapshot
}

enum CompanionWorkspaceServiceError: LocalizedError, Equatable {
    case missingDeviceCredential
    case invalidRequest
    case invalidDeviceCredential
    case deviceRevoked
    case notConfigured
    case conflict(String?)
    case requestTooLarge
    case companionUnreachable
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .missingDeviceCredential:
            return String(localized: "Pair with Companion again.")
        case .invalidRequest:
            return String(localized: "The file or Memory request is invalid.")
        case .invalidDeviceCredential:
            return String(localized: "This device must pair with Companion again.")
        case .deviceRevoked:
            return String(localized: "This device was revoked.")
        case .notConfigured:
            return String(localized: "This feature is not enabled on the Hermes Agent host.")
        case .conflict(let message):
            return message ?? String(localized: "The server state changed. Refresh and try again.")
        case .requestTooLarge:
            return String(localized: "The selected file exceeds the 50 MiB upload limit.")
        case .companionUnreachable:
            return String(localized: "Companion is unreachable.")
        case .unexpectedResponse:
            return String(localized: "Companion returned an unexpected response.")
        }
    }
}

final class CompanionUploadProgressDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(
            min(
                1,
                max(
                    0,
                    Double(totalBytesSent) / Double(totalBytesExpectedToSend)
                )
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
