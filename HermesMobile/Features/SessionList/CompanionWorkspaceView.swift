import SwiftUI

@MainActor
struct CompanionWorkspaceView: View {
    let service: any CompanionWorkspaceServing

    @State private var roots: [CompanionWorkspaceRoot] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(
        companionURL: URL,
        service: (any CompanionWorkspaceServing)? = nil
    ) {
        self.service = service
            ?? CompanionWorkspaceService(companionURL: companionURL)
    }

    var body: some View {
        List(Array(roots.enumerated()), id: \.offset) { _, root in
            if let rootID = root.id?.nilIfEmpty {
                NavigationLink {
                    CompanionWorkspaceDirectoryView(
                        service: service,
                        rootID: rootID,
                        rootName: root.name ?? rootID,
                        path: ""
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(root.name?.nilIfEmpty ?? rootID)
                            HStack(spacing: 6) {
                                if root.writable == true {
                                    Text("Uploads")
                                }
                                if root.attachable == true {
                                    Text("Chat attachments")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
            }
        }
        .overlay {
            if isLoading && roots.isEmpty {
                ProgressView("Loading folders...")
            } else if let errorMessage, roots.isEmpty {
                ContentUnavailableView {
                    Label(
                        "Files unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") {
                        Task { await load() }
                    }
                }
            } else if roots.isEmpty {
                ContentUnavailableView(
                    "No folders shared",
                    systemImage: "folder.badge.questionmark",
                    description: Text(
                        "Authorize folder aliases in the Companion host configuration first."
                    )
                )
            }
        }
        .navigationTitle("Files")
        .refreshable { await load() }
        .task {
            if roots.isEmpty {
                await load()
            }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            roots = try await service.roots()
        } catch {
            guard !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct CompanionWorkspaceDirectoryView: View {
    let service: any CompanionWorkspaceServing
    let rootID: String
    let rootName: String
    let path: String

    @State private var entries: [CompanionWorkspaceEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var preview: CompanionFilePreview?

    var body: some View {
        List(Array(entries.enumerated()), id: \.offset) { _, entry in
            if entry.isDirectory, let childPath = entry.path?.nilIfEmpty {
                NavigationLink {
                    CompanionWorkspaceDirectoryView(
                        service: service,
                        rootID: rootID,
                        rootName: entry.name ?? rootName,
                        path: childPath
                    )
                } label: {
                    Label(entry.name ?? childPath, systemImage: "folder")
                }
            } else {
                Button {
                    guard let filePath = entry.path?.nilIfEmpty else { return }
                    Task {
                        await loadPreview(
                            path: filePath,
                            name: entry.name ?? filePath
                        )
                    }
                } label: {
                    HStack {
                        Label(
                            entry.name ?? entry.path ?? "File",
                            systemImage: "doc"
                        )
                        Spacer()
                        if let size = entry.size {
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(size),
                                countStyle: .file
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if isLoading && entries.isEmpty {
                ProgressView("Loading files...")
            } else if let errorMessage, entries.isEmpty {
                ContentUnavailableView {
                    Label(
                        "Folder unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "Empty folder",
                    systemImage: "folder"
                )
            }
        }
        .navigationTitle(path.isEmpty ? rootName : path)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $preview) { preview in
            CompanionFilePreviewSheet(
                preview: preview,
                service: service
            )
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var loaded: [CompanionWorkspaceEntry] = []
            var cursor: String?
            repeat {
                let page = try await service.entries(
                    rootID: rootID,
                    path: path,
                    cursor: cursor
                )
                loaded.append(contentsOf: page.entries ?? [])
                cursor = page.nextCursor?.nilIfEmpty
            } while cursor != nil && loaded.count < 2_000
            entries = loaded
        } catch {
            guard !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadPreview(path: String, name: String) async {
        do {
            let response = try await service.preview(
                rootID: rootID,
                path: path
            )
            preview = CompanionFilePreview(
                rootID: rootID,
                path: response.path?.nilIfEmpty ?? path,
                name: response.name?.nilIfEmpty ?? name,
                text: response.content,
                size: response.size,
                truncated: response.truncated == true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CompanionFilePreview: Identifiable {
    let id = UUID()
    let rootID: String
    let path: String
    let name: String
    let text: String?
    let size: Int?
    let truncated: Bool

    var sizeDescription: String {
        guard let size else {
            return String(localized: "Unknown size")
        }
        return ByteCountFormatter.string(
            fromByteCount: Int64(size),
            countStyle: .file
        )
    }
}

@MainActor
private struct CompanionFilePreviewSheet: View {
    let preview: CompanionFilePreview
    let service: any CompanionWorkspaceServing

    @State private var downloadData: Data?
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let text = preview.text {
                    VStack(alignment: .leading, spacing: 10) {
                        if preview.truncated {
                            Label(
                                "Preview limited to the first 256 KiB",
                                systemImage: "text.badge.ellipsis"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Text(text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                    }
                    .padding()
                } else {
                    ContentUnavailableView(
                        "Binary file",
                        systemImage: "doc",
                        description: Text(preview.sizeDescription)
                    )
                }
            }
            .navigationTitle(preview.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let downloadData {
                        ShareLink(
                            item: downloadData,
                            preview: SharePreview(preview.name)
                        )
                    } else {
                        Button {
                            Task { await prepareShare() }
                        } label: {
                            if isDownloading {
                                ProgressView()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .disabled(isDownloading)
                        .accessibilityLabel("Download for sharing")
                    }
                }
            }
            .alert(
                "Download failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func prepareShare() async {
        guard !isDownloading else { return }
        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }
        do {
            downloadData = try await service.download(
                rootID: preview.rootID,
                path: preview.path
            )
        } catch {
            guard !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct CompanionUploadDestinationPicker: View {
    let service: any CompanionWorkspaceServing
    let onSelect: (CompanionUploadDestination) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var roots: [CompanionWorkspaceRoot] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(Array(uploadRoots.enumerated()), id: \.offset) { _, root in
                if let rootID = root.id?.nilIfEmpty {
                    NavigationLink {
                        CompanionUploadDirectoryPicker(
                            service: service,
                            rootID: rootID,
                            title: root.name ?? rootID,
                            path: "",
                            onSelect: onSelect
                        )
                    } label: {
                        Label(root.name ?? rootID, systemImage: "folder")
                    }
                }
            }
            .overlay {
                if let errorMessage, roots.isEmpty {
                    ContentUnavailableView {
                        Label(
                            "Upload folders unavailable",
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(errorMessage)
                    }
                } else if roots.isEmpty {
                    ProgressView("Loading folders...")
                } else if uploadRoots.isEmpty {
                    ContentUnavailableView(
                        "No attachment folder",
                        systemImage: "folder.badge.minus",
                        description: Text(
                            "The host must authorize a writable folder inside the Agent working directory."
                        )
                    )
                }
            }
            .navigationTitle("Upload Destination")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                do {
                    roots = try await service.roots()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var uploadRoots: [CompanionWorkspaceRoot] {
        roots.filter { $0.writable == true && $0.attachable == true }
    }
}

@MainActor
private struct CompanionUploadDirectoryPicker: View {
    let service: any CompanionWorkspaceServing
    let rootID: String
    let title: String
    let path: String
    let onSelect: (CompanionUploadDestination) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [CompanionWorkspaceEntry] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    onSelect(
                        CompanionUploadDestination(
                            rootID: rootID,
                            directory: path
                        )
                    )
                    dismiss()
                } label: {
                    Label("Use This Folder", systemImage: "checkmark.circle")
                }
            }

            Section("Subfolders") {
                ForEach(
                    Array(entries.filter(\.isDirectory).enumerated()),
                    id: \.offset
                ) { _, entry in
                    if let childPath = entry.path?.nilIfEmpty {
                        NavigationLink {
                            CompanionUploadDirectoryPicker(
                                service: service,
                                rootID: rootID,
                                title: entry.name ?? childPath,
                                path: childPath,
                                onSelect: onSelect
                            )
                        } label: {
                            Label(
                                entry.name ?? childPath,
                                systemImage: "folder"
                            )
                        }
                    }
                }
            }
        }
        .overlay {
            if let errorMessage {
                ContentUnavailableView {
                    Label(
                        "Folder unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(errorMessage)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                entries = try await service.entries(
                    rootID: rootID,
                    path: path,
                    cursor: nil
                ).entries ?? []
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
