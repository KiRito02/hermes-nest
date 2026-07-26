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
    @State private var viewModel: CompanionSessionListViewModel
    @State private var searchText = ""
    @State private var isConfirmingForget = false
    @State private var selectedSessionID: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
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

        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedSessionID) {
                if viewModel.isViewingCachedData {
                    OfflineCacheBanner()
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
        guard let selectedSessionID else { return nil }
        return viewModel.sessions.first { $0.id == selectedSessionID }
    }

    private func createSession() {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        Task {
            defer { isCreatingSession = false }
            if let created = await viewModel.createSession(
                modelContext: modelContext
            ) {
                selectedSessionID = created.id
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
    let runService: (any ConversationRunServing)?
    let modelService: (any CompanionModelServing)?
    let workspaceService: any CompanionWorkspaceServing
    let onUpdated: (SessionSummary) -> Void
    let onForked: () -> Void
    let onDeleted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
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
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var uploadDestination: CompanionUploadDestination?
    @State private var attachmentUploadTask: Task<Void, Never>?
    @State private var draftMessage = ""
    @State private var isUserInteractingWithScroll = false
    @FocusState private var composerIsFocused: Bool

    init(
        session: SessionSummary,
        repository: any SessionRepository,
        companionURL: URL,
        supportsRunApprovals: Bool,
        supportsModelSelection: Bool,
        supportsUploads: Bool = false,
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
                workspaceService: resolvedWorkspaceService
            )
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: HermesNestDesign.Spacing.medium
            ) {
                if viewModel.isViewingCachedData {
                    OfflineCacheBanner()
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

                ForEach(viewModel.visibleMessages) { message in
                    CompanionMessageRow(
                        message: message,
                        reasoningGroups: viewModel.durableReasoning(
                            anchoredTo: message
                        ),
                        toolCallGroups: viewModel.durableToolActivity(
                            anchoredTo: message
                        ),
                        transcriptMediaCacheNamespace: companionURL.absoluteString
                    )
                    .equatable()
                }

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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(
                maxWidth: HermesNestDesign.transcriptMaximumWidth,
                alignment: .leading
            )
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(HermesNestDesign.canvas)
        .background {
            ZStack {
                ChatScrollObserver(
                    isStreaming: viewModel.isRunActive
                ) { metrics in
                    isUserInteractingWithScroll = metrics.isUserInteracting
                }
                ChatVerticalScrollAxisGuard()
            }
            .accessibilityHidden(true)
        }
        .environment(
            \.chatIsUserInteractingWithScroll,
            isUserInteractingWithScroll
        )
        .defaultScrollAnchor(.bottom)
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
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Session actions")
                .disabled(viewModel.isRunActive)
            }
        }
        .task {
            if viewModel.allMessages.isEmpty {
                await viewModel.load(modelContext: modelContext)
            }
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
        .sheet(isPresented: $showsModelPicker) {
            CompanionModelPickerView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsUsage) {
            CompanionUsageView(viewModel: viewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsUploadDestination) {
            CompanionUploadDestinationPicker(
                service: workspaceService
            ) { destination in
                uploadDestination = destination
                showsUploadDestination = false
                Task { @MainActor in
                    await Task.yield()
                    showsAttachmentSourcePicker = true
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
            Button("Cancel", role: .cancel) {}
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
                viewModel.clearAttachmentError()
            }
        } message: {
            Text(viewModel.attachmentErrorMessage ?? "")
        }
    }

    private var companionComposer: some View {
        VStack(spacing: HermesNestDesign.Spacing.small) {
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
                || viewModel.isUploadingAttachment {
                attachmentStrip
            }

            modelControls

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
                .disabled(!viewModel.canSend)
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
                        ).isEmpty || !viewModel.canSend
                    )
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("companion.run.send")
                }
            }
            .padding(.horizontal, HermesNestDesign.Spacing.large)
            .padding(.vertical, HermesNestDesign.Spacing.medium)
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
        }
        .padding(.horizontal, HermesNestDesign.Spacing.large)
        .padding(.top, HermesNestDesign.Spacing.small)
        .padding(.bottom, HermesNestDesign.Spacing.xSmall)
        .frame(maxWidth: HermesNestDesign.transcriptMaximumWidth)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(
                    Array(viewModel.pendingUploads.enumerated()),
                    id: \.offset
                ) { _, upload in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
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
            }
        }
    }

    @ViewBuilder
    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            controlLayout {
                if !viewModel.modelGroups.isEmpty
                    || viewModel.isLoadingModelOptions {
                    Button {
                        showsModelPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            if viewModel.isLoadingModelOptions {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "cpu")
                            }
                            Text(viewModel.selectedModelDisplayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(HermesNestDesign.Typography.control)
                        .frame(minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !viewModel.canChangeModel
                            || viewModel.modelGroups.isEmpty
                    )
                    .accessibilityLabel("Choose model")
                    .accessibilityIdentifier("companion.model.picker")

                    if viewModel.selectedModelSupportsReasoning {
                        Menu {
                            ForEach(
                                CompanionReasoningEffort.allCases,
                                id: \.self
                            ) { effort in
                                Button {
                                    Task {
                                        await viewModel.selectReasoning(effort)
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
                            }
                        } label: {
                            Label(
                                viewModel.selectedReasoningDisplayName,
                                systemImage: "brain"
                            )
                            .font(HermesNestDesign.Typography.control)
                            .frame(minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.canChangeModel)
                        .accessibilityLabel("Choose reasoning effort")
                        .accessibilityIdentifier("companion.reasoning.picker")
                    }
                }

                Button {
                    showsUsage = true
                } label: {
                    Label(
                        usageControlLabel,
                        systemImage: "chart.bar.xaxis"
                    )
                    .font(HermesNestDesign.Typography.control)
                    .frame(minHeight: 32)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Model and token usage")
                .accessibilityHint(
                    "Shows exact run and session usage. Context occupancy is shown only when Hermes reports it."
                )
                .accessibilityIdentifier("companion.usage")

                Spacer(minLength: 0)
            }
        }
    }

    private var usageControlLabel: String {
        guard let tokens = viewModel.latestRunUsage?.totalTokens else {
            return String(localized: "Usage")
        }
        return String(
            localized:
                "\(ContextWindowFormatter.formatTokens(tokens)) tokens"
        )
    }

    private var composerInputLayout: AnyLayout {
        if dynamicTypeSize.isAccessibilitySize {
            return AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        }
        return AnyLayout(HStackLayout(alignment: .bottom, spacing: 10))
    }

    private var controlLayout: AnyLayout {
        if dynamicTypeSize.isAccessibilitySize {
            return AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        }
        return AnyLayout(HStackLayout(spacing: 8))
    }

    private func sendDraft() {
        let draft = draftMessage
        Task {
            if await viewModel.send(
                draft,
                modelContext: modelContext
            ) {
                draftMessage = ""
                composerIsFocused = false
            }
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
                        let data = try await Task.detached(
                            priority: .userInitiated
                        ) {
                            try Data(
                                contentsOf: url,
                                options: [.mappedIfSafe]
                            )
                        }.value
                        guard !Task.isCancelled else { return }
                        _ = await viewModel.uploadAttachment(
                            data: data,
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
                    _ = await viewModel.uploadAttachment(
                        data: data,
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
private struct CompanionMessageRow: View, Equatable {
    let message: ChatMessage
    let reasoningGroups: [ReasoningGroup]
    let toolCallGroups: [ToolCallGroup]
    let transcriptMediaCacheNamespace: String

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
                transcriptMediaCacheNamespace:
                    transcriptMediaCacheNamespace
            )

            if copyText != nil {
                ChatMessageActionsButton {
                    Button {
                        UIPasteboard.general.string = copyText
                    } label: {
                        Label("Copy Message", systemImage: "doc.on.doc")
                    }

                    if let copyText {
                        ShareLink(item: copyText) {
                            Label(
                                "Share Message",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                    }
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == "user" ? .trailing : .leading
        )
    }

    private var actionAlignment: HorizontalAlignment {
        message.role == "user" ? .trailing : .leading
    }

    private var copyText: String? {
        guard let content = message.content else { return nil }
        let trimmed = content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : content
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
                    value: viewModel.session.estimatedCost?
                        .formattedCost() ?? String(localized: "Unavailable")
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
        return ContextWindowFormatter.formatTokens(tokens)
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
                                        Text(option.model)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        HStack(spacing: 6) {
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
                $0.model.localizedCaseInsensitiveContains(query)
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
