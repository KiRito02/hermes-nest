import Foundation
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

/// Native Companion-backed session management and paged history presentation.
@MainActor
struct CompanionSessionListView: View {
    @Bindable var connectionManager: CompanionConnectionManager
    let connection: CompanionConnection

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: CompanionSessionListViewModel
    @State private var searchText = ""
    @State private var isConfirmingForget = false
    @State private var selectedSessionID: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sessionPendingDelete: SessionSummary?
    @State private var isCreatingSession = false
    @FocusState private var isSearchFocused: Bool
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

        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedSessionID) {
                if viewModel.isViewingCachedData {
                    CompanionOfflineCacheBanner()
                        .listRowSeparator(.hidden)
                }

                ForEach(displayedSessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRowView(
                            session: session,
                            showsMessageCount: true,
                            showsWorkspace: false,
                            isViewingCachedData: viewModel.isViewingCachedData
                        )
                    }
                    .tag(session.id)
                    .listRowInsets(
                        EdgeInsets(
                            top: 4,
                            leading: 10,
                            bottom: 4,
                            trailing: 10
                        )
                    )
                    .listRowBackground(Color.clear)
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
            .scrollContentBackground(.hidden)
            .background(HermesNestDesign.sidebar)
            .navigationTitle("Chats")
            .searchable(text: $searchText, prompt: "Search chats")
            .searchFocused($isSearchFocused)
            .refreshable {
                await viewModel.loadInitial(modelContext: modelContext)
            }
            .overlay {
                listOverlay
            }
            .navigationSplitViewColumnWidth(
                min: 280,
                ideal: HermesNestDesign.sidebarIdealWidth,
                max: 390
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CompanionDiscoveryView(
                            companionURL: connection.companionURL,
                            capabilities: connection.capabilities
                        )
                    } label: {
                        Image(systemName: "books.vertical")
                    }
                    .disabled(
                        !connection.capabilities
                            .supportsSkillsAndToolsetsDiscovery
                    )
                    .accessibilityLabel("Skills and Toolsets")
                    .accessibilityHint(Text(
                        connection.capabilities
                            .supportsSkillsAndToolsetsDiscovery
                            ? "Browses read-only Hermes capabilities"
                            : "Unavailable with this Gateway or Companion"
                    ))
                }

                if connection.capabilities.supportsFiles {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            CompanionWorkspaceView(
                                companionURL: connection.companionURL
                            )
                        } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityLabel("Files")
                    }
                }

                if connection.capabilities.supportsBuiltInMemory {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            CompanionMemoryView(
                                companionURL: connection.companionURL
                            )
                        } label: {
                            Image(systemName: "brain")
                        }
                        .accessibilityLabel("Memory")
                    }
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
                    .help("New Chat")
                    .accessibilityLabel("New chat")
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
        } detail: {
            if let selectedSession {
                historyView(for: selectedSession)
            } else {
                CompanionChatWelcomeView(
                    isCreatingSession: isCreatingSession,
                    canCreateSession: !viewModel.isViewingCachedData,
                    onCreateSession: createSession
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(
            \.hermexSceneActions,
            HermexSceneActions(
                canCreateNewChat:
                    !isCreatingSession
                        && !viewModel.isViewingCachedData,
                createNewChat: createSession,
                searchSessions: {
                    columnVisibility = .all
                    isSearchFocused = true
                }
            )
        )
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
                    let didDelete = await viewModel.deleteSession(
                        session,
                        modelContext: modelContext
                    )
                    if didDelete,
                       selectedSessionID == session.id {
                        selectedSessionID = nil
                    }
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

    private var selectedSession: SessionSummary? {
        viewModel.sessionForNavigation(id: selectedSessionID)
    }

    private func createSession() {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        Task {
            defer { isCreatingSession = false }
            if let created = await viewModel.createSession() {
                selectedSessionID = created.id
                if horizontalSizeClass != .regular {
                    columnVisibility = .detailOnly
                }
            }
        }
    }

    private func historyView(
        for session: SessionSummary
    ) -> some View {
        CompanionSessionHistoryView(
            session: session,
            repository: repository,
            companionURL: connection.companionURL,
            supportsRunApprovals:
                connection.capabilities.supportsRunApprovals,
            supportsModelSelection:
                connection.capabilities.supportsModelSelection,
            supportsUploads: connection.capabilities.supportsUploads,
            supportsServerFileAttachments:
                connection.capabilities.supportsServerFileAttachments,
            onUpdated: { session in
                selectedSessionID = session.id
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
                selectedSessionID = nil
                Task {
                    await viewModel.reconcileDeletedSession(
                        id: sessionID,
                        modelContext: modelContext
                    )
                }
            }
        )
        .id(session.sessionId)
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
private struct CompanionChatWelcomeView: View {
    let isCreatingSession: Bool
    let canCreateSession: Bool
    let onCreateSession: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Hermes Nest", systemImage: "sparkles")
        } description: {
            Text(
                "Choose a chat from the sidebar or start a new conversation with your Hermes Agent."
            )
        } actions: {
            Button(action: onCreateSession) {
                if isCreatingSession {
                    ProgressView()
                        .frame(minWidth: 92)
                } else {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCreatingSession || !canCreateSession)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesNestDesign.canvas)
    }
}

@MainActor
struct CompanionSessionHistoryView: View {
    let repository: any SessionRepository
    let companionURL: URL
    let supportsRunApprovals: Bool
    let supportsModelSelection: Bool
    let supportsUploads: Bool
    let supportsServerFileAttachments: Bool
    let runService: (any ConversationRunServing)?
    let modelService: (any CompanionModelServing)?
    let workspaceService: any CompanionWorkspaceServing
    let onUpdated: (SessionSummary) -> Void
    let onForked: () -> Void
    let onDeleted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CompanionSessionHistoryViewModel
    @State private var isRenaming = false
    @State private var renameTitle = ""
    @State private var isConfirmingDelete = false
    @State private var forkedSession: SessionSummary?
    @State private var showsModelPicker = false
    @State private var showsUsage = false
    @State private var showsAttachmentUnavailable = false
    @State private var showsUploadDestination = false
    @State private var showsFileImporter = false
    @State private var showsAttachmentSourcePicker = false
    @State private var showsPhotoPicker = false
    @State private var showsServerFilePicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var uploadDestination: CompanionUploadDestination?
    @State private var attachmentUploadTask: Task<Void, Never>?
    @State private var droppedAttachmentTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var draftMessage = ""
    @State private var shouldFollowLatestMessage = true
    @State private var isScrolledNearBottom = true
    @State private var isUserInteractingWithScroll = false
    @State private var userScrollCooldownUntil: Date?
    @State private var followScrollGeneration = 0
    @State private var pendingExplicitSendFollow = false
    @State private var restoresComposerFocusAfterPresentation = false
    @FocusState private var composerIsFocused: Bool

    private let transcriptBottomAnchorID = "companion-transcript-bottom"

    init(
        session: SessionSummary,
        repository: any SessionRepository,
        companionURL: URL,
        supportsRunApprovals: Bool,
        supportsModelSelection: Bool,
        supportsUploads: Bool = false,
        supportsServerFileAttachments: Bool = false,
        runService: (any ConversationRunServing)? = nil,
        modelService: (any CompanionModelServing)? = nil,
        workspaceService: (any CompanionWorkspaceServing)? = nil,
        onUpdated: @escaping (SessionSummary) -> Void,
        onForked: @escaping () -> Void,
        onDeleted: @escaping (String) -> Void
    ) {
        self.repository = repository
        self.companionURL = companionURL
        self.supportsRunApprovals = supportsRunApprovals
        self.supportsModelSelection = supportsModelSelection
        self.supportsUploads = supportsUploads
        self.supportsServerFileAttachments = supportsServerFileAttachments
        self.runService = runService
        self.modelService = modelService
        let resolvedWorkspaceService = workspaceService
            ?? CompanionWorkspaceService(companionURL: companionURL)
        self.workspaceService = resolvedWorkspaceService
        self.onUpdated = onUpdated
        self.onForked = onForked
        self.onDeleted = onDeleted
        _viewModel = State(
            initialValue: CompanionSessionHistoryViewModel(
                session: session,
                repository: repository,
                companionURL: companionURL,
                runService: runService,
                supportsRunApprovals: supportsRunApprovals,
                supportsModelSelection: supportsModelSelection,
                modelService: modelService,
                workspaceService: resolvedWorkspaceService,
                activeRunStore: CompanionActiveRunStore.shared
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: HermesNestDesign.Spacing.medium
                ) {
                    if viewModel.isViewingCachedData {
                        CompanionOfflineCacheBanner()
                    }

                    if viewModel.needsTerminalHistoryRetry {
                        VStack(
                            alignment: .leading,
                            spacing: HermesNestDesign.Spacing.small
                        ) {
                            Label(
                                "Final response is shown from the run stream.",
                                systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                            )
                            .font(HermesNestDesign.Typography.control)

                            Text(viewModel.terminalHistoryRetryMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Button("Retry History") {
                                Task {
                                    await viewModel.retryTerminalHistory(
                                        modelContext: modelContext
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            .orange.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .accessibilityIdentifier("companion.run.history-retry")
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

                    visibleTranscriptMessages
                    liveRunTranscriptContent

                    Color.clear
                        .frame(height: 1)
                        .id(transcriptBottomAnchorID)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(
                    maxWidth: HermesNestDesign.transcriptMaximumWidth,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background {
                HermesNestDesign.canvas
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissComposerKeyboard()
                    }
            }
            .background {
                ZStack {
                    ChatScrollObserver(
                        isStreaming: viewModel.isRunActive
                    ) { metrics in
                        updateScrollMetrics(metrics)
                    }
                    ChatVerticalScrollAxisGuard()
                }
                .accessibilityHidden(true)
            }
            .environment(
                \.chatIsUserInteractingWithScroll,
                isUserInteractingWithScroll
            )
            .defaultScrollAnchor(
                ChatScrollPolicy.initialTranscriptAnchor,
                for: .initialOffset
            )
            .defaultScrollAnchor(
                ChatScrollPolicy.sizeChangeAnchor(
                    shouldFollowLatestMessage: shouldFollowLatestMessage
                ),
                for: .sizeChanges
            )
            .onChange(of: viewModel.visibleMessages.last?.id) {
                let isExplicitSend = pendingExplicitSendFollow
                guard shouldFollowLatestMessage || isExplicitSend else {
                    return
                }
                pendingExplicitSendFollow = false
                scheduleFollowScroll(
                    proxy,
                    animated: true,
                    isUserInitiated: isExplicitSend
                )
            }
            .onChange(of: viewModel.streamingFollowTrigger) {
                guard shouldFollowLatestMessage else { return }
                scheduleFollowScroll(proxy, animated: true)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillShowNotification
                )
            ) { _ in
                guard isScrolledNearBottom else { return }
                scheduleFollowScroll(proxy, animated: false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            companionComposer
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
                supportsRunApprovals: supportsRunApprovals,
                supportsModelSelection: supportsModelSelection,
                supportsUploads: supportsUploads,
                supportsServerFileAttachments:
                    supportsServerFileAttachments,
                runService: runService,
                modelService: modelService,
                workspaceService: workspaceService,
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
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Session actions")
                .disabled(viewModel.isRunActive)
            }
        }
        .task {
            if viewModel.allMessages.isEmpty {
                await viewModel.load(modelContext: modelContext)
            }
            await viewModel.resumeRunObservation(
                modelContext: modelContext
            )
            await viewModel.loadModelOptions()
            if supportsUploads {
                await viewModel.restorePendingUploads()
            }
        }
        .refreshable {
            await viewModel.load(modelContext: modelContext)
            if supportsUploads {
                await viewModel.restorePendingUploads()
            }
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
        .sheet(
            isPresented: $showsModelPicker,
            onDismiss: restoreComposerFocusIfNeeded
        ) {
            CompanionModelPickerView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(
            isPresented: $showsUsage,
            onDismiss: restoreComposerFocusIfNeeded
        ) {
            CompanionUsageView(viewModel: viewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(
            isPresented: $showsUploadDestination,
            onDismiss: {
                Task {
                    await viewModel.discardStagedDroppedAttachments()
                }
            }
        ) {
            CompanionUploadDestinationPicker(
                companionURL: companionURL,
                service: workspaceService
            ) { destination in
                uploadDestination = destination
                if !viewModel.hasStagedDroppedAttachments {
                    showsUploadDestination = false
                    Task { @MainActor in
                        await Task.yield()
                        showsAttachmentSourcePicker = true
                    }
                } else {
                    let droppedAttachments =
                        viewModel.takeStagedDroppedAttachments()
                    showsUploadDestination = false
                    attachmentUploadTask?.cancel()
                    attachmentUploadTask = Task { @MainActor in
                        defer { attachmentUploadTask = nil }
                        await viewModel.uploadDroppedAttachments(
                            droppedAttachments,
                            destination: destination
                        )
                    }
                }
            }
        }
        .confirmationDialog(
            "Choose attachment source",
            isPresented: $showsAttachmentSourcePicker,
            titleVisibility: .visible
        ) {
            Button("Files") {
                showsFileImporter = true
            }
            Button("Photos") {
                showsPhotoPicker = true
            }
            if supportsServerFileAttachments {
                Button("Server Files") {
                    showsServerFilePicker = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    localized:
                        "Images are uploaded as secure file attachments. Hermes will try Vision analysis; native inline image input is not advertised by Runs."
                )
            )
        }
        .sheet(isPresented: $showsServerFilePicker) {
            if let destination = uploadDestination {
                CompanionServerFilePicker(
                    service: workspaceService
                ) { rootID, path in
                    showsServerFilePicker = false
                    Task {
                        _ = await viewModel.stageServerFile(
                            sourceRootID: rootID,
                            sourcePath: path,
                            destination: destination
                        )
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleSelectedFiles(result)
        }
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: max(
                1,
                10 - viewModel.pendingUploads.count
            ),
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            handleSelectedPhotos(items)
        }
        .alert(
            "Attachment failed",
            isPresented: Binding(
                get: { viewModel.attachmentErrorMessage != nil },
                set: { if !$0 { viewModel.clearAttachmentError() } }
            )
        ) {
            if viewModel.canRetryAttachmentUpload {
                Button("Retry") {
                    viewModel.clearAttachmentError()
                    attachmentUploadTask?.cancel()
                    attachmentUploadTask = Task { @MainActor in
                        defer { attachmentUploadTask = nil }
                        await viewModel.retryAttachmentUpload()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelAttachmentRetry()
            }
        } message: {
            Text(viewModel.attachmentErrorMessage ?? "")
        }
        .onDisappear {
            droppedAttachmentTask?.cancel()
            attachmentUploadTask?.cancel()
            viewModel.suspendRunObservation()
            viewModel.cancelAttachmentRetry()
            Task {
                await viewModel.discardStagedDroppedAttachments()
            }
        }
    }

    private var visibleTranscriptMessages: some View {
        ForEach(viewModel.visibleMessages) { message in
            CompanionMessageRow(
                message: message,
                reasoningGroups: viewModel.durableReasoning(
                    anchoredTo: message
                ),
                toolCallGroups: viewModel.durableToolActivity(
                    anchoredTo: message
                ),
                transcriptMediaCacheNamespace:
                    companionURL.absoluteString,
                loadAttachment: {
                    try? await workspaceService.downloadAttachment(
                        path: $0
                    )
                }
            )
            .equatable()
        }
    }

    @ViewBuilder
    private var liveRunTranscriptContent: some View {
        if !viewModel.reasoningText.isEmpty {
            DisclosureGroup("Reasoning") {
                Text(viewModel.reasoningText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            }
            .accessibilityIdentifier("companion.run.reasoning")
        }

        ForEach(viewModel.liveToolCalls) { toolCall in
            ToolCallCardView(toolCall: toolCall)
        }

        if let approval = viewModel.pendingApproval {
            CompanionRunApprovalCard(
                approval: approval,
                submissionChoice:
                    viewModel.approvalSubmissionChoice,
                errorMessage:
                    viewModel.approvalErrorMessage,
                canRespond: viewModel.canRespondToApproval
            ) { choice in
                Task {
                    await viewModel.respondToApproval(
                        choice,
                        modelContext: modelContext
                    )
                }
            }
        } else if viewModel.approvalContextUnavailable {
            CompanionRunApprovalUnavailableCard()
        }

        if let streamingMessage = viewModel.streamingMessage {
            MessageBubbleView(
                message: streamingMessage,
                transcriptMediaCacheNamespace: companionURL.absoluteString,
                isStreaming: viewModel.isRunActive
            )
            .accessibilityLabel("Streaming assistant response")
        }
    }

    private var companionComposer: some View {
        VStack(
            alignment: .leading,
            spacing: HermesNestDesign.Spacing.small
        ) {
            if let status = viewModel.runStatusText {
                Text(status)
                    .font(HermesNestDesign.Typography.metadata)
                    .foregroundStyle(
                        viewModel.runState == .transportDisconnected
                            ? Color.orange
                            : Color.secondary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("companion.run.status")
            }

            if !viewModel.pendingUploads.isEmpty
                || viewModel.isUploadingAttachment
                || viewModel.isPreparingDroppedAttachments {
                attachmentStrip
            }

            if let error = viewModel.modelSelectionErrorMessage {
                HStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if viewModel.modelGroups.isEmpty {
                        Button("Retry") {
                            Task {
                                await viewModel.loadModelOptions(refresh: true)
                            }
                        }
                        .font(HermesNestDesign.Typography.control)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            composerInputLayout {
                Button {
                    if supportsUploads {
                        viewModel.prepareAttachmentSelection()
                        showsUploadDestination = true
                    } else {
                        showsAttachmentUnavailable = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(
                    viewModel.pendingUploads.count >= 10
                        || viewModel.isUploadingAttachment
                        || viewModel.isPreparingDroppedAttachments
                )
                .accessibilityLabel("Add attachment")
                .accessibilityHint(
                    supportsUploads
                        ? "Choose an authorized upload folder, then select files."
                        : "Unavailable because Companion does not advertise uploads."
                )
                .accessibilityIdentifier(
                    "companion.attachment.unavailable"
                )
                .alert(
                    "Attachments unavailable",
                    isPresented: $showsAttachmentUnavailable
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(
                        "The connected Companion does not advertise the secure upload contract."
                    )
                }

                TextField(
                    "Message Hermes...",
                    text: $draftMessage,
                    axis: .vertical
                )
                .focused($composerIsFocused)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .disabled(
                    !viewModel.canSend
                        || viewModel.isPreparingDroppedAttachments
                )
                .submitLabel(.send)
                .onSubmit {
                    sendDraft()
                }

                if viewModel.isRunActive {
                    Button {
                        Task {
                            await viewModel.stopRun(
                                modelContext: modelContext
                            )
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!viewModel.canRequestStop)
                    .accessibilityLabel("Stop response")
                    .accessibilityIdentifier("companion.run.stop")
                } else {
                    Button {
                        sendDraft()
                    } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(CompanionSendButtonStyle())
                    .disabled(
                        draftMessage.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                            || !viewModel.canSend
                            || viewModel.isPreparingDroppedAttachments
                    )
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send message")
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("companion.run.send")
                }
            }

            compactComposerContextMenu
        }
        .padding(.horizontal, HermesNestDesign.Spacing.medium)
        .padding(.vertical, 10)
        .background(
            HermesNestDesign.sidebar,
            in: RoundedRectangle(
                cornerRadius: HermesNestDesign.composerCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: HermesNestDesign.composerCornerRadius,
                style: .continuous
            )
            .stroke(HermesNestDesign.subtleBorder, lineWidth: 0.5)
        }
        .shadow(
            color: .black.opacity(0.08),
            radius: 14,
            y: 4
        )
        .padding(.horizontal, HermesNestDesign.Spacing.large)
        .padding(.top, HermesNestDesign.Spacing.small)
        .padding(.bottom, HermesNestDesign.Spacing.xSmall)
        .frame(maxWidth: HermesNestDesign.transcriptMaximumWidth)
        .frame(maxWidth: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(
                    cornerRadius: HermesNestDesign.composerCornerRadius,
                    style: .continuous
                )
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(.horizontal, HermesNestDesign.Spacing.large)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedFiles(urls)
        } isTargeted: { isTargeted in
            isDropTargeted =
                isTargeted
                    && supportsUploads
                    && viewModel.pendingUploads.count < 10
                    && !viewModel.isUploadingAttachment
                    && !viewModel.isPreparingDroppedAttachments
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(
                    Array(viewModel.pendingUploads.enumerated()),
                    id: \.offset
                ) { _, upload in
                    HStack(spacing: 6) {
                        Image(systemName: upload.presentationSystemImage)
                        Text(upload.name?.nilIfEmpty ?? "Attachment")
                            .lineLimit(1)
                        Button {
                            Task {
                                await viewModel.removePendingUpload(upload)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment")
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color.secondary.opacity(0.12),
                        in: Capsule()
                    )
                }

                if viewModel.isUploadingAttachment {
                    HStack(spacing: 7) {
                        ProgressView(
                            value: viewModel.attachmentUploadProgress ?? 0
                        )
                        .frame(width: 54)
                            .controlSize(.small)
                        Text(
                            (viewModel.attachmentUploadProgress ?? 0)
                                .formatted(.percent.precision(.fractionLength(0)))
                        )
                        .monospacedDigit()
                        Button("Cancel") {
                            attachmentUploadTask?.cancel()
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                }

                if viewModel.isPreparingDroppedAttachments {
                    Label(
                        "Preparing dropped attachments...",
                        systemImage: "arrow.down.doc"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var compactComposerContextMenu: some View {
        Menu {
            if !viewModel.modelGroups.isEmpty
                || viewModel.isLoadingModelOptions {
                Button {
                    preserveComposerFocus()
                    showsModelPicker = true
                } label: {
                    Label("Choose model", systemImage: "cpu")
                }
                .disabled(
                    !viewModel.canChangeModel
                        || viewModel.modelGroups.isEmpty
                )
                .accessibilityIdentifier("companion.model.picker")
            }

            if viewModel.selectedModelSupportsReasoning {
                Section("Reasoning") {
                    ForEach(
                        CompanionReasoningEffort.allCases,
                        id: \.self
                    ) { effort in
                        Button {
                            preserveComposerFocus()
                            Task {
                                await viewModel.selectReasoning(effort)
                                restoreComposerFocusIfNeeded()
                            }
                        } label: {
                            if viewModel.selectedModel?
                                .reasoningEffort == effort {
                                Label(
                                    effort.displayName,
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(effort.displayName)
                            }
                        }
                        .disabled(!viewModel.canChangeModel)
                    }
                }
            }

            Divider()

            Button {
                preserveComposerFocus()
                showsUsage = true
            } label: {
                Label(usageControlLabel, systemImage: "chart.bar.xaxis")
            }
            .accessibilityIdentifier("companion.usage")
        } label: {
            HStack(spacing: 5) {
                if viewModel.isLoadingModelOptions {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "brain")
                }

                Text(composerContextLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(HermesNestDesign.Typography.control)
            .foregroundStyle(.secondary)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .help("Model and token usage")
        .accessibilityLabel("Model and token usage")
        .accessibilityValue(composerContextLabel)
        .accessibilityHint(
            "Choose the model or reasoning effort, or view exact token usage."
        )
    }

    private var composerContextLabel: String {
        guard viewModel.selectedModelSupportsReasoning else {
            return viewModel.selectedModelDisplayName
        }
        return [
            viewModel.selectedModelDisplayName,
            viewModel.selectedReasoningDisplayName
        ].joined(separator: " · ")
    }

    private var usageControlLabel: String {
        guard let tokens = viewModel.latestRunUsage?.totalTokens else {
            return String(localized: "Usage")
        }
        let exactTokens = CompanionTokenPresentation.exactCount(tokens)
        return String(
            localized:
                "\(exactTokens) tokens"
        )
    }

    private var composerInputLayout: AnyLayout {
        if dynamicTypeSize.isAccessibilitySize {
            return AnyLayout(
                VStackLayout(alignment: .leading, spacing: 10)
            )
        }
        return AnyLayout(HStackLayout(alignment: .bottom, spacing: 10))
    }

    private func sendDraft() {
        let draft = draftMessage
        prepareTranscriptForExplicitSend()
        Task {
            if await viewModel.send(
                draft,
                modelContext: modelContext
            ) {
                draftMessage = ""
                composerIsFocused = false
            } else {
                pendingExplicitSendFollow = false
            }
        }
    }

    private func updateScrollMetrics(_ metrics: ChatScrollMetrics) {
        let isNearBottom = ChatScrollPolicy.isNearBottom(
            distanceFromBottom: metrics.distanceFromBottom,
            isStreaming: viewModel.isRunActive
        )
        isScrolledNearBottom = isNearBottom
        isUserInteractingWithScroll = metrics.isUserInteracting

        if metrics.isUserInteracting {
            userScrollCooldownUntil = ChatScrollPolicy.cooldownDeadline()
        }

        if isNearBottom {
            shouldFollowLatestMessage = true
        } else if metrics.isUserInteracting {
            shouldFollowLatestMessage = false
        }
    }

    private var isAutoFollowScrollPaused: Bool {
        ChatScrollPolicy.isAutoScrollPaused(
            isUserInteracting: isUserInteractingWithScroll,
            cooldownUntil: userScrollCooldownUntil
        )
    }

    private func prepareTranscriptForExplicitSend() {
        shouldFollowLatestMessage = true
        userScrollCooldownUntil = nil
        pendingExplicitSendFollow = true
    }

    private func scheduleFollowScroll(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        isUserInitiated: Bool = false
    ) {
        guard isUserInitiated || !isAutoFollowScrollPaused else { return }

        if isUserInitiated {
            userScrollCooldownUntil = nil
        }

        followScrollGeneration += 1
        let generation = followScrollGeneration
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard
                !Task.isCancelled,
                generation == followScrollGeneration,
                isUserInitiated || !isAutoFollowScrollPaused
            else {
                return
            }

            if isUserInitiated {
                shouldFollowLatestMessage = true
            }

            if animated {
                withAnimation(
                    viewModel.isRunActive
                        ? ChatMotion.streamingFollow(reduceMotion: reduceMotion)
                        : ChatMotion.scrollToLatest(reduceMotion: reduceMotion)
                ) {
                    proxy.scrollTo(transcriptBottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(transcriptBottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func dismissComposerKeyboard() {
        composerIsFocused = false
    }

    private func preserveComposerFocus() {
        restoresComposerFocusAfterPresentation = composerIsFocused
    }

    private func restoreComposerFocusIfNeeded() {
        guard restoresComposerFocusAfterPresentation else { return }
        restoresComposerFocusAfterPresentation = false
        Task { @MainActor in
            await Task.yield()
            composerIsFocused = true
        }
    }

    private func handleSelectedFiles(
        _ result: Result<[URL], Error>
    ) {
        guard let destination = uploadDestination else { return }
        switch result {
        case .failure(let error):
            viewModel.setAttachmentError(error.localizedDescription)
        case .success(let urls):
            let remaining = max(
                0,
                10 - viewModel.pendingUploads.count
            )
            let selected = Array(urls.prefix(remaining))
            attachmentUploadTask?.cancel()
            attachmentUploadTask = Task { @MainActor in
                defer { attachmentUploadTask = nil }
                for url in selected {
                    guard !Task.isCancelled else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessed {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    do {
                        let values = try url.resourceValues(
                            forKeys: [.fileSizeKey, .contentTypeKey]
                        )
                        if let size = values.fileSize,
                           size > CompanionWorkspaceService.maximumUploadBytes {
                            viewModel.setAttachmentError(
                                String(
                                    localized:
                                        "\(url.lastPathComponent) exceeds the 50 MiB limit."
                                )
                            )
                            continue
                        }
                        let stagedURL = try await stageAttachmentFile(
                            from: url
                        )
                        guard !Task.isCancelled else {
                            try? FileManager.default.removeItem(at: stagedURL)
                            return
                        }
                        _ = await viewModel.uploadAttachment(
                            fileURL: stagedURL,
                            filename: url.lastPathComponent,
                            contentType:
                                values.contentType?.preferredMIMEType
                                ?? "application/octet-stream",
                            destination: destination
                        )
                    } catch {
                        guard !(error is CancellationError) else { return }
                        viewModel.setAttachmentError(
                            error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    private func handleSelectedPhotos(_ items: [PhotosPickerItem]) {
        guard let destination = uploadDestination else { return }
        attachmentUploadTask?.cancel()
        attachmentUploadTask = Task { @MainActor in
            defer {
                attachmentUploadTask = nil
                selectedPhotoItems = []
            }
            for item in items {
                guard !Task.isCancelled else { return }
                do {
                    guard
                        let data = try await item.loadTransferable(
                            type: Data.self
                        )
                    else {
                        continue
                    }
                    guard
                        data.count
                            <= CompanionWorkspaceService.maximumUploadBytes
                    else {
                        viewModel.setAttachmentError(
                            String(
                                localized:
                                    "The selected photo exceeds the 50 MiB limit."
                            )
                        )
                        continue
                    }
                    let type = item.supportedContentTypes.first
                        ?? UTType.image
                    let fileExtension =
                        type.preferredFilenameExtension ?? "jpg"
                    let stagedURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(
                            "hermes-nest-attachment-\(UUID().uuidString)",
                            isDirectory: false
                        )
                    try await Task.detached(
                        priority: .userInitiated
                    ) {
                        try data.write(to: stagedURL, options: [.atomic])
                    }.value
                    _ = await viewModel.uploadAttachment(
                        fileURL: stagedURL,
                        filename:
                            "photo-\(UUID().uuidString).\(fileExtension)",
                        contentType:
                            type.preferredMIMEType ?? "image/jpeg",
                        destination: destination
                    )
                } catch {
                    guard !(error is CancellationError) else { return }
                    viewModel.setAttachmentError(
                        error.localizedDescription
                    )
                }
            }
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) -> Bool {
        guard
            supportsUploads,
            !viewModel.isPreparingDroppedAttachments,
            !viewModel.isUploadingAttachment,
            viewModel.pendingUploads.count < 10
        else {
            return false
        }

        let remaining = 10 - viewModel.pendingUploads.count
        let selected = Array(urls.prefix(remaining))
        guard !selected.isEmpty else { return false }

        droppedAttachmentTask?.cancel()
        droppedAttachmentTask = Task { @MainActor in
            defer { droppedAttachmentTask = nil }
            if await viewModel.prepareDroppedAttachments(
                selected,
                maximumCount: remaining
            ) {
                showsUploadDestination = true
            }
        }
        return true
    }

    private func stageAttachmentFile(from sourceURL: URL) async throws -> URL {
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hermes-nest-attachment-\(UUID().uuidString)",
                isDirectory: false
            )
        return try await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: stagedURL
                )
                return stagedURL
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                throw error
            }
        }.value
    }
}

private struct CompanionSendButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let palette = ChatActionButtonPalette.resolve(
            colorScheme: colorScheme,
            isEnabled: isEnabled
        )

        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.foreground.color)
            .frame(width: 44, height: 44)
            .background(palette.background.color, in: Circle())
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && isEnabled ? 0.94 : 1)
            .animation(
                .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

@MainActor
struct CompanionMessageRow: View, Equatable {
    let message: ChatMessage
    let reasoningGroups: [ReasoningGroup]
    let toolCallGroups: [ToolCallGroup]
    let transcriptMediaCacheNamespace: String
    let loadAttachment: (String) async -> Data?
    @State private var attachmentShareItem: CompanionShareItem?
    @State private var attachmentPreviewError: String?

    static func == (
        lhs: CompanionMessageRow,
        rhs: CompanionMessageRow
    ) -> Bool {
        lhs.message == rhs.message
            && lhs.reasoningGroups == rhs.reasoningGroups
            && lhs.toolCallGroups == rhs.toolCallGroups
            && lhs.transcriptMediaCacheNamespace
                == rhs.transcriptMediaCacheNamespace
    }

    var body: some View {
        VStack(alignment: actionAlignment, spacing: 2) {
            if message.role == "assistant" {
                ForEach(reasoningGroups) { group in
                    ReasoningBlockView(text: group.text)
                }

                ForEach(toolCallGroups) { group in
                    ToolActivityGroupView(group: group)
                }
            }

            MessageBubbleView(
                message: message,
                loadAttachmentImage: loadAttachment,
                loadAttachmentData: loadAttachment,
                transcriptMediaCacheNamespace:
                    transcriptMediaCacheNamespace,
                onPreviewAttachment: { attachment, localData in
                    Task {
                        await prepareAttachmentShare(
                            attachment,
                            localData: localData
                        )
                    }
                }
            )

            if let copyText {
                CompanionMessageQuickActions(text: copyText) {
                    UIPasteboard.general.string = copyText
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == "user" ? .trailing : .leading
        )
        .sheet(
            item: $attachmentShareItem,
            onDismiss: clearAttachmentShareItem
        ) { item in
            CompanionShareSheet(fileURL: item.fileURL)
        }
        .alert(
            "Attachment failed",
            isPresented: Binding(
                get: { attachmentPreviewError != nil },
                set: { if !$0 { attachmentPreviewError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentPreviewError ?? "")
        }
    }

    private var actionAlignment: HorizontalAlignment {
        message.role == "user" ? .trailing : .leading
    }

    private func prepareAttachmentShare(
        _ attachment: MessageAttachment,
        localData: Data?
    ) async {
        let data: Data?
        if let localData {
            data = localData
        } else if let path = attachment.downloadPath?.nilIfEmpty {
            data = await loadAttachment(path)
        } else {
            data = nil
        }
        guard let data else {
            attachmentPreviewError = String(
                localized: "The attachment could not be downloaded."
            )
            return
        }
        let rawName = attachment.name?.nilIfEmpty ?? "attachment"
        let safeName = rawName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hermes-nest-preview-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent(
            safeName,
            isDirectory: false
        )
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: [.atomic])
            }.value
            attachmentShareItem = CompanionShareItem(fileURL: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            attachmentPreviewError = error.localizedDescription
        }
    }

    private func clearAttachmentShareItem() {
        guard let item = attachmentShareItem else { return }
        try? FileManager.default.removeItem(
            at: item.fileURL.deletingLastPathComponent()
        )
        attachmentShareItem = nil
    }

    private var copyText: String? {
        guard let content = message.content else { return nil }
        let trimmed = content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : content
    }
}

private extension CompanionUpload {
    var presentationSystemImage: String {
        contentType?.lowercased().hasPrefix("image/") == true
            ? "photo"
            : "doc"
    }
}

@MainActor
private struct CompanionUsageView: View {
    @Bindable var viewModel: CompanionSessionHistoryViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: HermesNestDesign.Spacing.large
                ) {
                    modelCard
                    runUsageCard
                    sessionUsageCard
                    contextCard
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(HermesNestDesign.Spacing.xLarge)
                .frame(maxWidth: .infinity)
            }
            .background(HermesNestDesign.canvas)
            .navigationTitle("Model & Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var modelCard: some View {
        usageCard(title: "Current model", systemImage: "cpu") {
            Text(viewModel.selectedModelDisplayName)
                .font(.headline)
                .textSelection(.enabled)

            if let identifier = viewModel.selectedModelIdentifier,
               identifier != viewModel.selectedModelDisplayName {
                Text(identifier)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let provider = viewModel.selectedModelProviderDisplayName {
                Text(provider)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let effort = viewModel.selectedModel?.reasoningEffort {
                Label(effort.displayName, systemImage: "brain")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runUsageCard: some View {
        usageCard(title: "Latest response", systemImage: "sparkles") {
            metricLayout {
                usageMetric(
                    title: "Input",
                    value: tokenLabel(viewModel.latestRunUsage?.inputTokens)
                )
                usageMetric(
                    title: "Output",
                    value: tokenLabel(viewModel.latestRunUsage?.outputTokens)
                )
                usageMetric(
                    title: "Total",
                    value: tokenLabel(viewModel.latestRunUsage?.totalTokens)
                )
            }

            Text("These are exact token counts reported by the completed Hermes Run.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sessionUsageCard: some View {
        usageCard(title: "Session totals", systemImage: "text.bubble") {
            metricLayout {
                usageMetric(
                    title: "Input",
                    value: tokenLabel(viewModel.session.inputTokens)
                )
                usageMetric(
                    title: "Output",
                    value: tokenLabel(viewModel.session.outputTokens)
                )
                usageMetric(
                    title: "Cost",
                    value: costLabel(viewModel.session.estimatedCost)
                )
            }
        }
    }

    private var metricLayout: AnyLayout {
        if dynamicTypeSize.isAccessibilitySize {
            return AnyLayout(VStackLayout(spacing: 10))
        }
        return AnyLayout(HStackLayout(spacing: 10))
    }

    private var contextCard: some View {
        usageCard(
            title: "Context window",
            systemImage: "rectangle.split.3x1"
        ) {
            Text("Unavailable")
                .font(.headline)

            Text(
                "Hermes Runs currently report token usage, but not the exact current prompt size together with this model's context limit. Hermes Nest will not estimate a percentage from cumulative session tokens."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    private func tokenLabel(_ tokens: Int?) -> String {
        guard let tokens else { return String(localized: "Unavailable") }
        return CompanionTokenPresentation.exactCount(tokens)
    }

    private func costLabel(_ cost: Double?) -> String {
        guard let cost else { return String(localized: "Unavailable") }
        return String(format: "$%.4f", cost)
    }

    private func usageMetric(
        title: LocalizedStringKey,
        value: String
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: HermesNestDesign.Spacing.xSmall
        ) {
            Text(title)
                .font(HermesNestDesign.Typography.metadata)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            HermesNestDesign.raisedSurface,
            in: RoundedRectangle(
                cornerRadius: HermesNestDesign.compactCornerRadius,
                style: .continuous
            )
        )
    }

    private func usageCard<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: HermesNestDesign.Spacing.medium
        ) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(HermesNestDesign.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            HermesNestDesign.sidebar,
            in: RoundedRectangle(
                cornerRadius: HermesNestDesign.cardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: HermesNestDesign.cardCornerRadius,
                style: .continuous
            )
            .stroke(HermesNestDesign.subtleBorder, lineWidth: 0.5)
        }
    }
}

@MainActor
private struct CompanionModelPickerView: View {
    @Bindable var viewModel: CompanionSessionHistoryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredGroups) { group in
                    Section(group.name) {
                        ForEach(group.models) { option in
                            Button {
                                Task {
                                    if await viewModel.selectModel(option) {
                                        dismiss()
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(
                                        systemName: isSelected(option)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        isSelected(option)
                                            ? Color.accentColor
                                            : Color.secondary
                                    )

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.presentationName)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        HStack(spacing: 6) {
                                            Text(option.model)
                                                .fontDesign(.monospaced)
                                            Text(option.provider)
                                            if option.supportsReasoning {
                                                Label(
                                                    "Reasoning",
                                                    systemImage: "brain"
                                                )
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!viewModel.canChangeModel)
                        }
                    }
                }
            }
            .overlay {
                if filteredGroups.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models")
            .refreshable {
                await viewModel.loadModelOptions(refresh: true)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var filteredGroups: [CompanionModelGroup] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return viewModel.modelGroups }
        return viewModel.modelGroups.compactMap { group in
            let models = group.models.filter {
                $0.presentationName.localizedCaseInsensitiveContains(query)
                    || $0.model.localizedCaseInsensitiveContains(query)
                    || $0.provider.localizedCaseInsensitiveContains(query)
                    || $0.providerName.localizedCaseInsensitiveContains(query)
            }
            guard !models.isEmpty else { return nil }
            return CompanionModelGroup(
                provider: group.provider,
                name: group.name,
                models: models
            )
        }
    }

    private func isSelected(_ option: CompanionModelOption) -> Bool {
        viewModel.selectedModel?.model == option.model
            && viewModel.selectedModel?.provider == option.provider
    }
}

@MainActor
private struct CompanionRunApprovalCard: View {
    let approval: ConversationApprovalRequest
    let submissionChoice: ConversationApprovalChoice?
    let errorMessage: String?
    let canRespond: (ConversationApprovalChoice) -> Bool
    let onChoice: (ConversationApprovalChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Approval required",
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.headline)
            .foregroundStyle(.orange)

            if let description = approval.description {
                Text(description)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }

            if let command = approval.commandPreview {
                Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
            }

            if !approval.contextIsComplete {
                Label(
                    "Approval context was missing or truncated. Allowing is disabled; deny or stop the run.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel(
                        "Approval failed. \(errorMessage)"
                    )
            }

            HStack(spacing: 10) {
                if approval.choices.contains(.deny) {
                    choiceButton(
                        .deny,
                        title: "Deny",
                        systemImage: "xmark",
                        role: .destructive,
                        prominent: false
                    )
                }
                if approval.choices.contains(.once) {
                    choiceButton(
                        .once,
                        title: "Allow Once",
                        systemImage: "checkmark",
                        prominent: true
                    )
                }
                if approval.choices.contains(.session)
                    || approval.choices.contains(.always) {
                    Menu {
                        if approval.choices.contains(.session) {
                            Button {
                                onChoice(.session)
                            } label: {
                                Label(
                                    "Allow for Session",
                                    systemImage: "clock"
                                )
                            }
                            .disabled(!canRespond(.session))
                        }
                        if approval.choices.contains(.always) {
                            Button {
                                onChoice(.always)
                            } label: {
                                Label(
                                    "Always Allow",
                                    systemImage: "infinity"
                                )
                            }
                            .disabled(!canRespond(.always))
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(submissionChoice != nil)
                    .accessibilityLabel("More approval choices")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 680, alignment: .leading)
        .background(
            .orange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.orange.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion.run.approval")
    }

    @ViewBuilder
    private func choiceButton(
        _ choice: ConversationApprovalChoice,
        title: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        prominent: Bool
    ) -> some View {
        let button = Button(role: role) {
            onChoice(choice)
        } label: {
            choiceLabel(
                choice,
                title: title,
                systemImage: systemImage
            )
        }
        .disabled(!canRespond(choice))
        .accessibilityIdentifier(
            "companion.run.approval.\(choice.rawValue)"
        )

        if prominent {
            button
            .buttonStyle(.borderedProminent)
        } else {
            button
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func choiceLabel(
        _ choice: ConversationApprovalChoice,
        title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        Group {
            if submissionChoice == choice {
                ProgressView()
                    .accessibilityLabel("Submitting approval")
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
private struct CompanionRunApprovalUnavailableCard: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Approval is waiting in Hermes")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "The live approval details disconnected, so this app will not submit a blind decision. You can stop the run or resolve it from another connected Hermes surface."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        }
        .padding(14)
        .frame(maxWidth: 680, alignment: .leading)
        .background(
            .orange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "companion.run.approval-context-unavailable"
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
