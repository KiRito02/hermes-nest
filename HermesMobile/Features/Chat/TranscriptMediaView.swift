import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TranscriptMediaContentView: View {
    let segments: [TranscriptMediaSegment]
    let cacheNamespace: String
    let loadMediaImage: ((TranscriptMediaReference) async -> Data?)?
    let loadMediaData: ((TranscriptMediaReference) async -> Data?)?
    let onPreviewMedia: ((TranscriptMediaReference) -> Void)?
    let isStreaming: Bool

    init(
        segments: [TranscriptMediaSegment],
        cacheNamespace: String,
        loadMediaImage: ((TranscriptMediaReference) async -> Data?)?,
        loadMediaData: ((TranscriptMediaReference) async -> Data?)?,
        onPreviewMedia: ((TranscriptMediaReference) -> Void)?,
        isStreaming: Bool = false
    ) {
        self.segments = segments
        self.cacheNamespace = cacheNamespace
        self.loadMediaImage = loadMediaImage
        self.loadMediaData = loadMediaData
        self.onPreviewMedia = onPreviewMedia
        self.isStreaming = isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownRenderer(content: text, isStreaming: isStreaming)
                    }
                case let .media(reference):
                    TranscriptMediaThumbnailView(
                        reference: reference,
                        cacheNamespace: cacheNamespace,
                        loadMediaImage: loadMediaImage,
                        loadMediaData: loadMediaData,
                        onPreviewMedia: onPreviewMedia
                    )
                    // Pin the image container LTR so media keeps its leading-edge
                    // anchor inside an RTL message (#259); the text segments above
                    // still follow the chat direction.
                    .forcedLeftToRight()
                }
            }
        }
    }
}

private struct TranscriptMediaThumbnailView: View {
    let reference: TranscriptMediaReference
    let cacheNamespace: String
    let loadMediaImage: ((TranscriptMediaReference) async -> Data?)?
    let loadMediaData: ((TranscriptMediaReference) async -> Data?)?
    let onPreviewMedia: ((TranscriptMediaReference) -> Void)?

    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    private let thumbnailWidth: CGFloat = 210
    private let thumbnailHeight: CGFloat = 132

    var body: some View {
        switch reference.mediaKind {
        case .image where reference.isExtensionlessRemoteMediaCandidate && loadMediaData != nil:
            if let loadMediaData {
                TranscriptMediaResolvedRemoteView(
                    reference: reference,
                    loadMediaData: loadMediaData,
                    onPreviewMedia: onPreviewMedia
                )
            } else {
                TranscriptMediaUnavailableChip(reference: reference)
            }

        case .image where loadMediaImage != nil:
            Button {
                onPreviewMedia?(reference)
            } label: {
                thumbnailContent
            }
            .buttonStyle(.chatTactile(.thumbnail))
            .accessibilityLabel(imageButtonAccessibilityLabel)
            .task(id: imageCacheKey) {
                guard let loadMediaImage else { return }
                image = nil
                didAttemptLoad = false
                let loadedImage = await TranscriptMediaImageCache.shared.image(
                    for: reference,
                    cacheNamespace: cacheNamespace,
                    loadMediaImage: loadMediaImage
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    image = loadedImage
                    didAttemptLoad = true
                }
            }
        case .audio where loadMediaData != nil:
            if let loadMediaData {
                TranscriptMediaAudioExportView(
                    reference: reference,
                    loadMediaData: {
                        await loadMediaData(reference)
                    }
                )
            } else {
                TranscriptMediaUnavailableChip(reference: reference)
            }

        case .video:
            Button {
                onPreviewMedia?(reference)
            } label: {
                TranscriptMediaVideoTile(reference: reference)
            }
            .buttonStyle(.chatTactile(.thumbnail))
            .accessibilityLabel(String(localized: "Open media video \(reference.displayName)"))

        case .unsupported where loadMediaData != nil:
            if let loadMediaData {
                TranscriptMediaFileExportView(
                    reference: reference,
                    loadMediaData: {
                        await loadMediaData(reference)
                    }
                )
            } else {
                TranscriptMediaUnavailableChip(reference: reference)
            }

        default:
            TranscriptMediaUnavailableChip(reference: reference)
        }
    }

    private var imageCacheKey: TranscriptMediaImageCacheKey {
        TranscriptMediaImageCacheKey(namespace: cacheNamespace, reference: reference)
    }

    private var imageButtonAccessibilityLabel: String {
        if image == nil, didAttemptLoad, reference.isExtensionlessRemoteMediaCandidate {
            return String(localized: "Open media video \(reference.displayName)")
        }

        return String(localized: "Open media image \(reference.displayName)")
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                )
        } else if didAttemptLoad {
            if reference.isExtensionlessRemoteMediaCandidate {
                TranscriptMediaVideoTile(reference: reference)
            } else {
                TranscriptMediaUnavailableChip(reference: reference)
            }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemFill))
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .overlay {
                    ProgressView()
                        .tint(Color(.tertiaryLabel))
                }
        }
    }
}

private struct TranscriptMediaResolvedRemoteView: View {
    let reference: TranscriptMediaReference
    let loadMediaData: (TranscriptMediaReference) async -> Data?
    let onPreviewMedia: ((TranscriptMediaReference) -> Void)?

    @State private var resolvedMedia: ResolvedMedia?

    var body: some View {
        Group {
            switch resolvedMedia {
            case let .image(image):
                Button {
                    onPreviewMedia?(reference)
                } label: {
                    thumbnailContent(image)
                }
                .buttonStyle(.chatTactile(.thumbnail))
                .accessibilityLabel(String(localized: "Open media image \(reference.displayName)"))

            case let .audio(data):
                TranscriptMediaAudioExportView(
                    reference: reference,
                    initialData: data,
                    loadMediaData: { data }
                )

            case .video:
                Button {
                    onPreviewMedia?(reference)
                } label: {
                    TranscriptMediaVideoTile(reference: reference)
                }
                .buttonStyle(.chatTactile(.thumbnail))
                .accessibilityLabel(String(localized: "Open media video \(reference.displayName)"))

            case .unavailable:
                TranscriptMediaUnavailableChip(reference: reference)

            case nil:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.systemFill))
                    .frame(width: 210, height: 132)
                    .overlay {
                        ProgressView()
                            .tint(Color(.tertiaryLabel))
                    }
            }
        }
        .task(id: reference.id) {
            resolvedMedia = nil
            guard let data = await loadMediaData(reference) else {
                guard !Task.isCancelled else { return }
                resolvedMedia = .unavailable
                return
            }

            guard !Task.isCancelled else { return }
            resolvedMedia = Self.resolve(data)
        }
    }

    private func thumbnailContent(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 210, height: 132)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
            )
    }

    private static func resolve(_ data: Data) -> ResolvedMedia {
        if let image = UIImage(data: data) {
            return .image(image)
        }

        if (try? AVAudioPlayer(data: data)) != nil {
            return .audio(data)
        }

        return .video
    }

    private enum ResolvedMedia {
        case image(UIImage)
        case audio(Data)
        case video
        case unavailable
    }
}

private struct TranscriptMediaAudioExportView: View {
    let reference: TranscriptMediaReference
    let loadMediaData: () async -> Data?

    @State private var cachedData: Data?
    @State private var exportDocument = ExportedFileDocument(data: Data())
    @State private var exportContentType = UTType.audio
    @State private var exportFilename = String(localized: "Hermes Media")
    @State private var isFileExporterPresented = false
    @State private var isExporting = false
    @State private var errorMessage: String?

    init(
        reference: TranscriptMediaReference,
        initialData: Data? = nil,
        loadMediaData: @escaping () async -> Data?
    ) {
        self.reference = reference
        self.loadMediaData = loadMediaData
        _cachedData = State(initialValue: initialData)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            InlineAudioPlayerView(title: reference.displayName) {
                await audioData()
            }
            .frame(maxWidth: 280)

            Button {
                Task { await exportAudio() }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.chatTactile(.icon))
            .disabled(isExporting)
            .accessibilityLabel(String(localized: "Export audio \(reference.displayName)"))
        }
        .accessibilityElement(children: .contain)
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
    }

    private func audioData() async -> Data? {
        if let cachedData {
            return cachedData
        }

        let data = await loadMediaData()
        guard !Task.isCancelled else { return nil }
        cachedData = data
        return data
    }

    private func exportAudio() async {
        isExporting = true
        defer {
            isExporting = false
        }

        guard let data = await audioData() else {
            errorMessage = String(localized: "Could not load media.")
            return
        }

        let payload = TranscriptMediaExportSupport.payload(for: reference, data: data, resolvedKind: .audio)
        exportDocument = ExportedFileDocument(data: payload.data)
        exportContentType = payload.contentType
        exportFilename = payload.filename
        isFileExporterPresented = true
    }
}

private struct TranscriptMediaFileExportView: View {
    let reference: TranscriptMediaReference
    let loadMediaData: () async -> Data?

    @State private var cachedData: Data?
    @State private var exportDocument = ExportedFileDocument(data: Data())
    @State private var exportContentType = UTType.data
    @State private var exportFilename = String(localized: "Hermes Media")
    @State private var isFileExporterPresented = false
    @State private var isExporting = false
    @State private var errorMessage: String?

    init(
        reference: TranscriptMediaReference,
        initialData: Data? = nil,
        loadMediaData: @escaping () async -> Data?
    ) {
        self.reference = reference
        self.loadMediaData = loadMediaData
        _cachedData = State(initialValue: initialData)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))

            VStack(alignment: .leading, spacing: 2) {
                Text(reference.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(isExporting
                     ? String(localized: "Loading…")
                     : String(localized: "Tap to download"))
                    .font(.caption2)
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                Task { await exportFile() }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.chatTactile(.icon))
            .disabled(isExporting)
            .accessibilityLabel(String(localized: "Download \(reference.displayName)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
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
            "Download Failed",
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
    }

    private func fileData() async -> Data? {
        if let cachedData {
            return cachedData
        }

        let data = await loadMediaData()
        guard !Task.isCancelled else { return nil }
        cachedData = data
        return data
    }

    private func exportFile() async {
        isExporting = true
        defer {
            isExporting = false
        }

        guard let data = await fileData() else {
            errorMessage = String(localized: "Could not load file.")
            return
        }

        let payload = TranscriptMediaExportSupport.payload(for: reference, data: data, resolvedKind: .data)
        exportDocument = ExportedFileDocument(data: payload.data)
        exportContentType = payload.contentType
        exportFilename = payload.filename
        isFileExporterPresented = true
    }
}

private struct TranscriptMediaVideoTile: View {
    let reference: TranscriptMediaReference

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 210, height: 132)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                )

            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text(reference.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 172)

                Text("Video")
                    .font(.caption2)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .padding(.horizontal, 14)
        }
    }
}

private struct TranscriptMediaUnavailableChip: View {
    let reference: TranscriptMediaReference

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))

            VStack(alignment: .leading, spacing: 2) {
                Text(reference.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Media unavailable")
                    .font(.caption2)
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Media unavailable \(reference.displayName)"))
    }

    private var iconName: String {
        switch reference.mediaKind {
        case .image:
            "photo"
        case .audio:
            "waveform"
        case .video:
            "play.rectangle"
        case .unsupported:
            "doc"
        }
    }
}

private actor TranscriptMediaImageCache {
    static let shared = TranscriptMediaImageCache()

    private var cache: [TranscriptMediaImageCacheKey: UIImage] = [:]
    private var inFlight: [TranscriptMediaImageCacheKey: Task<UIImage?, Never>] = [:]

    func image(
        for reference: TranscriptMediaReference,
        cacheNamespace: String,
        loadMediaImage: @escaping (TranscriptMediaReference) async -> Data?
    ) async -> UIImage? {
        let key = TranscriptMediaImageCacheKey(namespace: cacheNamespace, reference: reference)
        if let cached = cache[key] {
            return cached
        }

        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            guard let data = await loadMediaImage(reference) else {
                return nil
            }
            return UIImage(data: data)
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            cache[key] = image
        }
        return image
    }
}

struct TranscriptMediaImageCacheKey: Hashable {
    let namespace: String
    let referenceID: String

    init(namespace: String, reference: TranscriptMediaReference) {
        self.namespace = namespace
        referenceID = reference.id
    }
}
