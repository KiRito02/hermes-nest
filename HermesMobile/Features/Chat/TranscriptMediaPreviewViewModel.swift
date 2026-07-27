import AVFoundation
import AVKit
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class TranscriptMediaPreviewViewModel {
    private let sessionID: String?
    private let reference: TranscriptMediaReference
    private let apiClient: APIClient
    private var didLoad = false
    private var loadGeneration = 0
    private var originalData: Data?
    private var temporaryVideoURL: URL?

    private(set) var previewData: Data?
    private(set) var audioData: Data?
    private(set) var videoFileURL: URL?
    private(set) var originalByteCount: Int?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    init(
        server: URL,
        sessionID: String?,
        reference: TranscriptMediaReference,
        apiClient: APIClient? = nil
    ) {
        self.sessionID = sessionID
        self.reference = reference
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    var canSaveImageToPhotos: Bool {
        reference.isRasterImageCandidate && previewData != nil
    }

    var canSaveVideoToPhotos: Bool {
        videoFileURL != nil && originalData != nil
    }

    var canSaveMediaToPhotos: Bool {
        canSaveImageToPhotos || canSaveVideoToPhotos
    }

    var canExportMedia: Bool {
        originalData != nil
    }

    func load(force: Bool = false) async {
        guard force || !didLoad else { return }
        loadGeneration += 1
        let generation = loadGeneration
        didLoad = true
        previewData = nil
        audioData = nil
        videoFileURL = nil
        originalByteCount = nil
        originalData = nil
        removeTemporaryVideoFile()

        guard reference.isRasterImageCandidate || reference.isVideoCandidate else {
            errorMessage = String(localized: "Preview is not available for this media type.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        do {
            let data = try await transcriptMediaData()
            guard !Task.isCancelled, loadGeneration == generation else { return }
            originalData = data
            originalByteCount = data.count

            if reference.isVideoCandidate {
                let fileURL = try writeTemporaryVideoFile(data)
                guard !Task.isCancelled, loadGeneration == generation else {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                temporaryVideoURL = fileURL
                videoFileURL = fileURL
            } else {
                if let downsampled = await ImagePreviewDownsampler.previewDataAsync(
                    from: data,
                    maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                ) {
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    previewData = downsampled
                } else {
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    if reference.isExtensionlessRemoteMediaCandidate {
                        if Self.isAudioData(data) {
                            audioData = data
                        } else {
                            let fileURL = try writeTemporaryVideoFile(data)
                            temporaryVideoURL = fileURL
                            videoFileURL = fileURL
                        }
                    } else {
                        errorMessage = String(localized: "Could not decode this image.")
                    }
                }
            }
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    func originalImageData() async throws -> Data {
        try await originalMediaData()
    }

    func originalMediaData() async throws -> Data {
        if let originalData {
            return originalData
        }

        let data = try await transcriptMediaData()
        try Task.checkCancellation()
        originalData = data
        originalByteCount = data.count
        return data
    }

    func exportPayload() async throws -> FileExportPayload {
        let data = try await originalMediaData()
        return TranscriptMediaExportSupport.payload(
            for: reference,
            data: data,
            resolvedKind: resolvedExportKind
        )
    }

    private func transcriptMediaData() async throws -> Data {
        switch reference.source {
        case .localPath:
            guard let sessionID = resolvedSessionID else {
                throw TranscriptMediaPreviewError.missingSessionID
            }
            return try await apiClient.transcriptMediaData(for: reference, sessionID: sessionID)
        case .remoteURL:
            return try await apiClient.transcriptMediaData(for: reference, sessionID: resolvedSessionID ?? "")
        }
    }

    private var resolvedSessionID: String? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            return nil
        }
        return sessionID
    }

    func cleanupTemporaryFiles() {
        loadGeneration += 1
        isLoading = false
        audioData = nil
        removeTemporaryVideoFile()
        videoFileURL = nil
    }

    private func writeTemporaryVideoFile(_ data: Data) throws -> URL {
        let ext = reference.videoFileExtension
        let filename = "transcript-media-\(UUID().uuidString).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic])
        return url
    }

    private func removeTemporaryVideoFile() {
        if let temporaryVideoURL {
            try? FileManager.default.removeItem(at: temporaryVideoURL)
        }
        temporaryVideoURL = nil
    }

    private static func isAudioData(_ data: Data) -> Bool {
        (try? AVAudioPlayer(data: data)) != nil
    }

    private var resolvedExportKind: TranscriptMediaResolvedExportKind? {
        if previewData != nil {
            return .image
        }

        if audioData != nil {
            return .audio
        }

        if videoFileURL != nil {
            return .video
        }

        return nil
    }
}

private enum TranscriptMediaPreviewError: LocalizedError {
    case missingSessionID

    var errorDescription: String? {
        String(localized: "Preview is not available for this media without a server session.")
    }
}

private extension TranscriptMediaReference {
    var videoFileExtension: String {
        switch source {
        case let .remoteURL(url):
            let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            return ext.isEmpty ? "mp4" : ext
        case let .localPath(path):
            let ext = URL(fileURLWithPath: path).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            return ext.isEmpty ? "mp4" : ext
        }
    }
}

struct TranscriptMediaPreviewItem: Identifiable, Equatable {
    let reference: TranscriptMediaReference

    var id: String {
        reference.id
    }
}
struct TranscriptMediaPreviewView: View {
    let onAPIError: (Error) -> Void

    private let item: TranscriptMediaPreviewItem
    @State private var viewModel: TranscriptMediaPreviewViewModel
    @State private var exportDocument = ExportedFileDocument(data: Data())
    @State private var exportContentType = UTType.data
    @State private var exportFilename = String(localized: "Hermes Media")
    @State private var isFileExporterPresented = false
    @State private var isExportingMedia = false
    @State private var isSavingToPhotos = false
    @State private var saveConfirmationMessage: String?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(
        server: URL,
        sessionID: String?,
        item: TranscriptMediaPreviewItem,
        onAPIError: @escaping (Error) -> Void
    ) {
        self.item = item
        self.onAPIError = onAPIError
        _viewModel = State(
            initialValue: TranscriptMediaPreviewViewModel(
                server: server,
                sessionID: sessionID,
                reference: item.reference
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.previewData == nil {
                    ProgressView("Loading media...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.errorMessage, viewModel.previewData == nil {
                    ContentUnavailableView {
                        Label("Could Not Load Media", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadMedia(force: true) }
                        }
                    }
                } else if let data = viewModel.previewData, let image = UIImage(data: data) {
                    imageContent(image)
                } else if let audioData = viewModel.audioData {
                    audioContent(audioData)
                } else if let videoURL = viewModel.videoFileURL {
                    videoContent(videoURL)
                } else {
                    unavailableContent(String(localized: "Preview is not available for this media."))
                }
            }
            .navigationTitle(item.reference.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if viewModel.canSaveMediaToPhotos {
                        Button {
                            Task { await saveMediaToPhotos() }
                        } label: {
                            Image(systemName: "photo")
                        }
                        .disabled(exportActionsAreDisabled)
                        .accessibilityLabel("Save media to Photos")
                    }

                    if viewModel.canExportMedia {
                        Button {
                            Task { await exportMedia() }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(exportActionsAreDisabled)
                        .accessibilityLabel("Export media")
                    }
                }
            }
            .task {
                await loadMedia()
            }
            .refreshable {
                await loadMedia(force: true)
            }
            .fileExporter(
                isPresented: $isFileExporterPresented,
                document: exportDocument,
                contentType: exportContentType,
                defaultFilename: exportFilename
            ) { result in
                if case let .failure(error) = result {
                    errorMessage = error.localizedDescription
                }
            }
            .alert(
                "Saved",
                isPresented: Binding(
                    get: { saveConfirmationMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            saveConfirmationMessage = nil
                        }
                    }
                )
            ) {
                Button("OK") {
                    saveConfirmationMessage = nil
                }
            } message: {
                Text(saveConfirmationMessage ?? "")
            }
            .alert(
                "Media Action Failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            errorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
            .onDisappear {
                viewModel.cleanupTemporaryFiles()
            }
        }
        .adaptivePagePresentation()
    }

    private func imageContent(_ image: UIImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                mediaHeader

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(item.reference.displayName)
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }

    private func audioContent(_ data: Data) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            mediaHeader

            InlineAudioPlayerView(title: item.reference.displayName) {
                data
            }
            .frame(maxWidth: 360)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
    }

    private func videoContent(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            mediaHeader

            TranscriptVideoPreviewPlayerView(url: url)
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
    }

    private func unavailableContent(_ message: String) -> some View {
        ContentUnavailableView {
            Label("No Preview", systemImage: unavailableIconName)
        } description: {
            VStack(spacing: 8) {
                Text(message)
                Text(item.reference.rawReference)
                    .font(.footnote)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var unavailableIconName: String {
        switch item.reference.mediaKind {
        case .image:
            "photo"
        case .audio:
            "waveform"
        case .video:
            "play.rectangle"
        case .unsupported:
            "doc.questionmark"
        }
    }

    private var mediaHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.reference.rawReference)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let originalByteCount = viewModel.originalByteCount {
                Text(ByteCountFormatter.string(fromByteCount: Int64(originalByteCount), countStyle: .file))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadMedia(force: Bool = false) async {
        await viewModel.load(force: force)
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func exportMedia() async {
        isExportingMedia = true
        defer {
            isExportingMedia = false
        }

        do {
            let payload = try await viewModel.exportPayload()
            exportDocument = ExportedFileDocument(data: payload.data)
            exportContentType = payload.contentType
            exportFilename = payload.filename
            isFileExporterPresented = true
        } catch {
            errorMessage = error.localizedDescription
            onAPIError(error)
        }
    }

    private func saveMediaToPhotos() async {
        isSavingToPhotos = true
        defer {
            isSavingToPhotos = false
        }

        do {
            let payload = try await viewModel.exportPayload()
            if payload.isImage {
                guard UIImage(data: payload.data) != nil else {
                    throw PhotoLibrarySaveError.notImage
                }
                try await PhotoLibrarySaver.saveImageData(payload.data)
            } else if payload.isVideo {
                try await PhotoLibrarySaver.saveVideoData(payload.data, contentType: payload.contentType)
            } else {
                throw PhotoLibrarySaveError.notPhotosMedia
            }

            saveConfirmationMessage = String(localized: "Media saved to Photos.")
        } catch {
            errorMessage = error.localizedDescription
            onAPIError(error)
        }
    }

    private var exportActionsAreDisabled: Bool {
        viewModel.isLoading || isSavingToPhotos || isExportingMedia
    }
}

private struct TranscriptVideoPreviewPlayerView: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            player?.pause()
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}
