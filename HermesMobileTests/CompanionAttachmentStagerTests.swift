import Foundation
import XCTest
@testable import HermesMobile

final class CompanionAttachmentStagerTests: XCTestCase {
    func testStagesRegularFileAndDiscardsOwnedCopy() async throws {
        let sourceDirectory = try temporaryDirectory()
        let stagingDirectory = try temporaryDirectory()
        let sourceURL = sourceDirectory.appendingPathComponent("report.txt")
        let data = Data("bounded attachment".utf8)
        try data.write(to: sourceURL)
        let stager = CompanionAttachmentStager(
            stagingDirectory: stagingDirectory
        )

        let attachments = try await stager.stage(
            [sourceURL],
            maximumBytes: 1_024
        )

        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachment.filename, "report.txt")
        XCTAssertEqual(
            try Data(contentsOf: attachment.fileURL),
            data
        )
        XCTAssertTrue(
            attachment.fileURL.path.hasPrefix(stagingDirectory.path)
        )

        await stager.discard(attachments)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: attachment.fileURL.path)
        )
    }

    func testRejectsDirectoryWithoutRecursiveCopy() async throws {
        let sourceDirectory = try temporaryDirectory()
        let stagingDirectory = try temporaryDirectory()
        try Data("nested".utf8).write(
            to: sourceDirectory.appendingPathComponent("nested.txt")
        )
        let stager = CompanionAttachmentStager(
            stagingDirectory: stagingDirectory
        )

        do {
            _ = try await stager.stage(
                [sourceDirectory],
                maximumBytes: 1_024
            )
            XCTFail("Expected directory staging to fail.")
        } catch {
            XCTAssertEqual(
                error as? CompanionWorkspaceServiceError,
                .invalidRequest
            )
        }

        XCTAssertTrue(try stagedFiles(in: stagingDirectory).isEmpty)
    }

    func testRejectsFileLargerThanBoundBeforePublishingCopy() async throws {
        let sourceDirectory = try temporaryDirectory()
        let stagingDirectory = try temporaryDirectory()
        let sourceURL = sourceDirectory.appendingPathComponent("large.bin")
        try Data(repeating: 0xAB, count: 32).write(to: sourceURL)
        let stager = CompanionAttachmentStager(
            stagingDirectory: stagingDirectory
        )

        do {
            _ = try await stager.stage(
                [sourceURL],
                maximumBytes: 16
            )
            XCTFail("Expected an oversized file to fail.")
        } catch {
            XCTAssertEqual(
                error as? CompanionWorkspaceServiceError,
                .requestTooLarge
            )
        }

        XCTAssertTrue(try stagedFiles(in: stagingDirectory).isEmpty)
    }

    func testRejectsSymbolicLink() async throws {
        let sourceDirectory = try temporaryDirectory()
        let stagingDirectory = try temporaryDirectory()
        let targetURL = sourceDirectory.appendingPathComponent("target.txt")
        try Data("target".utf8).write(to: targetURL)
        let linkURL = sourceDirectory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )
        let stager = CompanionAttachmentStager(
            stagingDirectory: stagingDirectory
        )

        do {
            _ = try await stager.stage(
                [linkURL],
                maximumBytes: 1_024
            )
            XCTFail("Expected symbolic-link staging to fail.")
        } catch {
            XCTAssertEqual(
                error as? CompanionWorkspaceServiceError,
                .invalidRequest
            )
        }

        XCTAssertTrue(try stagedFiles(in: stagingDirectory).isEmpty)
    }

    func testPartialBatchFailureRemovesEarlierStagedFiles() async throws {
        let sourceDirectory = try temporaryDirectory()
        let stagingDirectory = try temporaryDirectory()
        let sourceURL = sourceDirectory.appendingPathComponent("first.txt")
        try Data("first".utf8).write(to: sourceURL)
        let rejectedDirectory =
            sourceDirectory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rejectedDirectory,
            withIntermediateDirectories: false
        )
        let stager = CompanionAttachmentStager(
            stagingDirectory: stagingDirectory
        )

        do {
            _ = try await stager.stage(
                [sourceURL, rejectedDirectory],
                maximumBytes: 1_024
            )
            XCTFail("Expected partial staging to fail.")
        } catch {
            XCTAssertEqual(
                error as? CompanionWorkspaceServiceError,
                .invalidRequest
            )
        }

        XCTAssertTrue(try stagedFiles(in: stagingDirectory).isEmpty)
    }

    func testCancelledBatchDoesNotLeaveStagedFiles() async throws {
        let sourceDirectory = try temporaryDirectory()
        let stagingDirectory = try temporaryDirectory()
        let sourceURL = sourceDirectory.appendingPathComponent("cancel.txt")
        try Data("cancel".utf8).write(to: sourceURL)
        let stager = CompanionAttachmentStager(
            stagingDirectory: stagingDirectory
        )

        let task = Task {
            try await stager.stage(
                [sourceURL],
                maximumBytes: 1_024
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertTrue(try stagedFiles(in: stagingDirectory).isEmpty)
    }

    @MainActor
    func testViewModelDismissalDiscardsUnclaimedDrop() async throws {
        let stagingDirectory = try temporaryDirectory()
        let stagedURL =
            stagingDirectory.appendingPathComponent("staged.txt")
        try Data("staged".utf8).write(to: stagedURL)
        let attachment = CompanionStagedAttachment(
            fileURL: stagedURL,
            filename: "staged.txt",
            contentType: "text/plain"
        )
        let stager = RecordingAttachmentStager(
            stagedAttachments: [attachment]
        )
        let viewModel = CompanionSessionHistoryViewModel(
            session: SessionSummary(
                sessionId: "drop-test",
                title: "Drop test"
            ),
            repository: AttachmentStagerSessionRepository(),
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            attachmentStager: stager
        )

        let prepared = await viewModel.prepareDroppedAttachments(
            [URL(fileURLWithPath: "/ignored-by-test-stager")],
            maximumCount: 1
        )
        XCTAssertTrue(prepared)
        XCTAssertTrue(viewModel.hasStagedDroppedAttachments)

        await viewModel.discardStagedDroppedAttachments()

        XCTAssertFalse(viewModel.hasStagedDroppedAttachments)
        let discarded = await stager.discardedAttachments()
        XCTAssertEqual(discarded, [attachment])
    }

    @MainActor
    func testUploadPreflightFailureDiscardsCurrentUnownedFile() async throws {
        let stagingDirectory = try temporaryDirectory()
        let stagedURL =
            stagingDirectory.appendingPathComponent("preflight.txt")
        try Data("staged".utf8).write(to: stagedURL)
        let attachment = CompanionStagedAttachment(
            fileURL: stagedURL,
            filename: "preflight.txt",
            contentType: "text/plain"
        )
        let stager = RecordingAttachmentStager(stagedAttachments: [])
        let viewModel = CompanionSessionHistoryViewModel(
            session: SessionSummary(title: "Missing identity"),
            repository: AttachmentStagerSessionRepository(),
            companionURL: try XCTUnwrap(
                URL(string: "https://companion.example.test")
            ),
            attachmentStager: stager
        )

        await viewModel.uploadDroppedAttachments(
            [attachment],
            destination: CompanionUploadDestination(
                rootID: "workspace",
                directory: ""
            )
        )

        let discarded = await stager.discardedAttachments()
        XCTAssertEqual(discarded, [attachment])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hermes-nest-stager-test-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func stagedFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
    }
}

private actor RecordingAttachmentStager: CompanionAttachmentStaging {
    private let stagedAttachments: [CompanionStagedAttachment]
    private var discarded: [CompanionStagedAttachment] = []

    init(stagedAttachments: [CompanionStagedAttachment]) {
        self.stagedAttachments = stagedAttachments
    }

    func stage(
        _ sourceURLs: [URL],
        maximumBytes: Int
    ) async throws -> [CompanionStagedAttachment] {
        stagedAttachments
    }

    func discard(
        _ attachments: [CompanionStagedAttachment]
    ) async {
        discarded.append(contentsOf: attachments)
    }

    func discardedAttachments() -> [CompanionStagedAttachment] {
        discarded
    }
}

private actor AttachmentStagerSessionRepository: SessionRepository {
    func listSessions(_ query: SessionListQuery) async throws -> SessionPage {
        throw SessionRepositoryError.unexpectedResponse
    }

    func createSession(
        _ request: SessionCreateRequest
    ) async throws -> SessionSummary {
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
