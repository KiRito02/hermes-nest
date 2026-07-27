import Foundation
import UniformTypeIdentifiers

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

struct CompanionStagedAttachment: Equatable, Sendable {
    let fileURL: URL
    let filename: String
    let contentType: String
}

protocol CompanionAttachmentStaging: Sendable {
    func stage(
        _ sourceURLs: [URL],
        maximumBytes: Int
    ) async throws -> [CompanionStagedAttachment]

    func discard(
        _ attachments: [CompanionStagedAttachment]
    ) async
}

actor CompanionAttachmentStager: CompanionAttachmentStaging {
    private let fileManager: FileManager
    private let stagingDirectory: URL
    private let chunkSize = 256 * 1_024

    init(
        fileManager: FileManager = .default,
        stagingDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.stagingDirectory = stagingDirectory
    }

    func stage(
        _ sourceURLs: [URL],
        maximumBytes: Int
    ) async throws -> [CompanionStagedAttachment] {
        guard maximumBytes > 0 else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }

        var staged: [CompanionStagedAttachment] = []
        do {
            for sourceURL in sourceURLs {
                try Task.checkCancellation()
                let accessed =
                    sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                staged.append(
                    try stageOne(
                        sourceURL,
                        maximumBytes: maximumBytes
                    )
                )
            }
            try Task.checkCancellation()
            return staged
        } catch {
            discardImmediately(staged)
            throw error
        }
    }

    func discard(
        _ attachments: [CompanionStagedAttachment]
    ) async {
        discardImmediately(attachments)
    }

    private func stageOne(
        _ sourceURL: URL,
        maximumBytes: Int
    ) throws -> CompanionStagedAttachment {
        let values = try sourceURL.resourceValues(
            forKeys: [
                .contentTypeKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize >= 0
        else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }
        guard fileSize <= maximumBytes else {
            throw CompanionWorkspaceServiceError.requestTooLarge
        }

        let filename = sourceURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }

        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let fileExtension = sourceURL.pathExtension
        let stagedName = fileExtension.isEmpty
            ? "hermes-nest-drop-\(UUID().uuidString)"
            : "hermes-nest-drop-\(UUID().uuidString).\(fileExtension)"
        let stagedURL = stagingDirectory.appendingPathComponent(
            stagedName,
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: stagedURL.path,
            contents: nil
        ) else {
            throw CompanionWorkspaceServiceError.invalidRequest
        }

        do {
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: stagedURL)
            defer { try? output.close() }

            var copiedBytes = 0
            while let data = try input.read(upToCount: chunkSize),
                  !data.isEmpty {
                try Task.checkCancellation()
                copiedBytes += data.count
                guard copiedBytes <= maximumBytes else {
                    throw CompanionWorkspaceServiceError.requestTooLarge
                }
                try output.write(contentsOf: data)
            }
            try Task.checkCancellation()
            try output.synchronize()

            let stagedSize = try stagedURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard
                stagedSize.isRegularFile == true,
                stagedSize.fileSize == copiedBytes,
                copiedBytes == fileSize
            else {
                throw CompanionWorkspaceServiceError.invalidRequest
            }

            return CompanionStagedAttachment(
                fileURL: stagedURL,
                filename: filename,
                contentType:
                    values.contentType?.preferredMIMEType
                    ?? "application/octet-stream"
            )
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
    }

    private func discardImmediately(
        _ attachments: [CompanionStagedAttachment]
    ) {
        for attachment in attachments {
            try? fileManager.removeItem(at: attachment.fileURL)
        }
    }
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
    func downloadAttachment(path: String) async throws -> Data
    func upload(
        sessionID: String,
        destination: CompanionUploadDestination,
        filename: String,
        contentType: String,
        fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CompanionUpload
    func stageServerFile(
        sessionID: String,
        sourceRootID: String,
        sourcePath: String,
        destination: CompanionUploadDestination
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
