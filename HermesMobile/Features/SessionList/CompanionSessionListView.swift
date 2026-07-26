import SwiftData
import SwiftUI

/// Native Companion-backed session management and paged history presentation.
@MainActor
struct CompanionSessionListView: View {
    @Bindable var connectionManager: CompanionConnectionManager
    let connection: CompanionConnection

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CompanionSessionListViewModel
    @State private var searchText = ""
    @State private var isConfirmingForget = false
    @State private var navigationPath = NavigationPath()
    @State private var sessionPendingDelete: SessionSummary?
    @State private var isCreatingSession = false
    private let repository: any SessionRepository

    init(
        connectionManager: CompanionConnectionManager,
        connection: CompanionConnection,
        repository: (any SessionRepository)? = nil
    ) {
        self.connectionManager = connectionManager
        self.connection = connection
        let resolvedRepository = repository ?? LiveSessionRepository(
            companionURL: connection.companionURL
        )
        self.repository = resolvedRepository
        _viewModel = State(
            initialValue: CompanionSessionListViewModel(
                repository: resolvedRepository,
                companionURL: connection.companionURL
            )
        )
    }

    var body: some View {
        let displayedSessions = viewModel.matchingSessions(searchText: searchText)

        NavigationStack(path: $navigationPath) {
            List {
                if viewModel.isViewingCachedData {
                    OfflineCacheBanner()
                        .listRowSeparator(.hidden)
                }

                ForEach(displayedSessions) { session in
                    NavigationLink(value: session) {
                        SessionRowView(
                            session: session,
                            showsMessageCount: true,
                            showsWorkspace: false,
                            isViewingCachedData: viewModel.isViewingCachedData
                        )
                    }
                    .listRowInsets(
                        EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            sessionPendingDelete = session
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .onAppear {
                        guard session.id == displayedSessions.last?.id else { return }
                        Task {
                            await viewModel.loadNextPageIfNeeded(
                                modelContext: modelContext
                            )
                        }
                    }
                }

                if viewModel.isLoadingNextPage {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Sessions")
            .searchable(text: $searchText, prompt: "Search sessions")
            .refreshable {
                await viewModel.loadInitial(modelContext: modelContext)
            }
            .overlay {
                listOverlay
            }
            .navigationDestination(for: SessionSummary.self) { session in
                CompanionSessionHistoryView(
                    session: session,
                    repository: repository,
                    companionURL: connection.companionURL,
                    onUpdated: { session in
                        viewModel.updateSessionSnapshot(
                            session,
                            modelContext: modelContext
                        )
                    },
                    onForked: {
                        Task {
                            await viewModel.refreshAfterMembershipMutation(
                                modelContext: modelContext
                            )
                        }
                    },
                    onDeleted: { sessionID in
                        Task {
                            await viewModel.reconcileDeletedSession(
                                id: sessionID,
                                modelContext: modelContext
                            )
                        }
                    }
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image("HermesMobileBanner")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 112, height: 28, alignment: .leading)
                        .accessibilityLabel("Hermes Nest")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        createSession()
                    } label: {
                        if isCreatingSession {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                    .disabled(isCreatingSession || viewModel.isViewingCachedData)
                    .accessibilityLabel("New session")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task {
                                await viewModel.loadInitial(modelContext: modelContext)
                            }
                        } label: {
                            Label("Refresh sessions", systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive) {
                            isConfirmingForget = true
                        } label: {
                            Label("Forget Companion", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                    .accessibilityLabel("Connection actions")
                }
            }
        }
        .task {
            if viewModel.sessions.isEmpty {
                await viewModel.loadInitial(modelContext: modelContext)
            }
        }
        .alert("Forget this Companion?", isPresented: $isConfirmingForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget and revoke device", role: .destructive) {
                Task { await connectionManager.forgetConnection() }
            }
        } message: {
            Text("Cached conversations are kept on this device.")
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(
                get: { sessionPendingDelete != nil },
                set: { if !$0 { sessionPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                guard let session = sessionPendingDelete else { return }
                sessionPendingDelete = nil
                Task {
                    _ = await viewModel.deleteSession(
                        session,
                        modelContext: modelContext
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDelete = nil
            }
        } message: {
            Text("This removes the session from Hermes. Deletion cannot be undone.")
        }
        .alert(
            "Session action failed",
            isPresented: Binding(
                get: { viewModel.mutationErrorMessage != nil },
                set: { if !$0 { viewModel.clearMutationError() } }
            )
        ) {
            Button("OK") {
                viewModel.clearMutationError()
            }
        } message: {
            Text(viewModel.mutationErrorMessage ?? "")
        }
    }

    private func createSession() {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        Task {
            defer { isCreatingSession = false }
            if let created = await viewModel.createSession(
                modelContext: modelContext
            ) {
                navigationPath.append(created)
            }
        }
    }

    @ViewBuilder
    private var listOverlay: some View {
        if viewModel.isLoading && viewModel.sessions.isEmpty {
            ProgressView("Loading sessions...")
        } else if let errorMessage = viewModel.errorMessage,
                  viewModel.sessions.isEmpty {
            ContentUnavailableView {
                Label("Sessions unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") {
                    Task {
                        await connectionManager.resume()
                        await viewModel.loadInitial(modelContext: modelContext)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if viewModel.sessions.isEmpty {
            ContentUnavailableView(
                "No sessions yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Existing Hermes sessions will appear here.")
            )
        }
    }
}

@MainActor
private struct CompanionSessionHistoryView: View {
    let repository: any SessionRepository
    let companionURL: URL
    let onUpdated: (SessionSummary) -> Void
    let onForked: () -> Void
    let onDeleted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CompanionSessionHistoryViewModel
    @State private var isRenaming = false
    @State private var renameTitle = ""
    @State private var isConfirmingDelete = false
    @State private var forkedSession: SessionSummary?

    init(
        session: SessionSummary,
        repository: any SessionRepository,
        companionURL: URL,
        onUpdated: @escaping (SessionSummary) -> Void,
        onForked: @escaping () -> Void,
        onDeleted: @escaping (String) -> Void
    ) {
        self.repository = repository
        self.companionURL = companionURL
        self.onUpdated = onUpdated
        self.onForked = onForked
        self.onDeleted = onDeleted
        _viewModel = State(
            initialValue: CompanionSessionHistoryViewModel(
                session: session,
                repository: repository,
                companionURL: companionURL
            )
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if viewModel.isViewingCachedData {
                    OfflineCacheBanner()
                }

                if let mutationErrorMessage = viewModel.mutationErrorMessage {
                    Label(
                        mutationErrorMessage,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.hasOlderMessages {
                    Button {
                        viewModel.loadOlderMessages()
                    } label: {
                        Label("Load earlier messages", systemImage: "arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }

                ForEach(viewModel.visibleMessages) { message in
                    MessageBubbleView(
                        message: message,
                        transcriptMediaCacheNamespace: companionURL.absoluteString
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .overlay {
            if viewModel.isLoading && viewModel.allMessages.isEmpty {
                ProgressView("Loading messages...")
            } else if let errorMessage = viewModel.errorMessage,
                      viewModel.allMessages.isEmpty {
                ContentUnavailableView {
                    Label(
                        "Could Not Load Messages",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.load(modelContext: modelContext) }
                    }
                }
            } else if !viewModel.isLoading && viewModel.allMessages.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("This Hermes session has no message history.")
                )
            }
        }
        .navigationTitle(
            viewModel.session.title?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nilIfEmpty ?? "Chat"
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $forkedSession) { session in
            CompanionSessionHistoryView(
                session: session,
                repository: repository,
                companionURL: companionURL,
                onUpdated: onUpdated,
                onForked: onForked,
                onDeleted: onDeleted
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameTitle = viewModel.session.title ?? ""
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button {
                        Task {
                            let fork = await viewModel.fork(
                                modelContext: modelContext
                            )
                            if let fork {
                                onForked()
                                forkedSession = fork
                            }
                        }
                    } label: {
                        Label("Fork Session", systemImage: "arrow.triangle.branch")
                    }

                    Divider()

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Session actions")
            }
        }
        .task {
            if viewModel.allMessages.isEmpty {
                await viewModel.load(modelContext: modelContext)
            }
        }
        .refreshable {
            await viewModel.load(modelContext: modelContext)
        }
        .alert("Rename Session", isPresented: $isRenaming) {
            TextField("Session name", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    if await viewModel.rename(
                        to: renameTitle,
                        modelContext: modelContext
                    ) {
                        onUpdated(viewModel.session)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                Task {
                    guard
                        await viewModel.delete(),
                        let sessionID = viewModel.session.sessionId
                    else {
                        return
                    }
                    onDeleted(sessionID)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the session from Hermes. Deletion cannot be undone.")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
