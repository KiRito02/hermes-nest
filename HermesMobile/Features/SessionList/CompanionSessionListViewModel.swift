import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class CompanionSessionListViewModel {
    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var isLoadingNextPage = false
    private(set) var isViewingCachedData = false
    private(set) var errorMessage: String?
    private(set) var mutationErrorMessage: String?
    private(set) var hasMore = false

    private let repository: any SessionRepository
    private let companionURL: URL
    private var nextOffset = 0
    private let pageSize = 50

    init(repository: any SessionRepository, companionURL: URL) {
        self.repository = repository
        self.companionURL = companionURL
    }

    var sortedSessions: [SessionSummary] {
        sessions.sorted { left, right in
            sortTimestamp(left) > sortTimestamp(right)
        }
    }

    func matchingSessions(searchText: String) -> [SessionSummary] {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return sortedSessions }

        return sortedSessions.filter { session in
            [
                session.title,
                session.model,
                session.sessionSource,
                session.sessionId,
            ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
        }
    }

    func loadInitial(modelContext: ModelContext? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await repository.listSessions(
                SessionListQuery(
                    limit: pageSize,
                    offset: 0,
                    includeChildren: true
                )
            )
            sessions = Self.visibleUniqueSessions(page.sessions)
            nextOffset = resolvedNextOffset(for: page, fallback: sessions.count)
            hasMore = page.hasMore == true
            isViewingCachedData = false
            cache(page.sessions, completesList: !hasMore, in: modelContext)
        } catch {
            guard !(error is CancellationError) else { return }
            if let modelContext, shouldUseCache(for: error),
               let cached = try? CacheStore.cachedSessions(
                   serverURL: companionURL,
                   in: modelContext
               ),
               !cached.isEmpty {
                sessions = Self.visibleUniqueSessions(cached)
                nextOffset = sessions.count
                hasMore = false
                isViewingCachedData = true
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadNextPageIfNeeded(modelContext: ModelContext? = nil) async {
        guard
            hasMore,
            !isLoading,
            !isLoadingNextPage
        else {
            return
        }

        isLoadingNextPage = true
        defer { isLoadingNextPage = false }

        do {
            let page = try await repository.listSessions(
                SessionListQuery(
                    limit: pageSize,
                    offset: nextOffset,
                    includeChildren: true
                )
            )
            sessions = Self.visibleUniqueSessions(sessions + page.sessions)
            nextOffset = resolvedNextOffset(for: page, fallback: nextOffset + pageSize)
            hasMore = page.hasMore == true
            isViewingCachedData = false
            errorMessage = nil
            cache(page.sessions, completesList: !hasMore, in: modelContext)
        } catch {
            guard !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func createSession(modelContext: ModelContext? = nil) async -> SessionSummary? {
        mutationErrorMessage = nil
        do {
            let created = try await repository.createSession(
                SessionCreateRequest()
            )
            resetPagination()
            await loadInitial(modelContext: modelContext)
            return created
        } catch {
            guard !(error is CancellationError) else { return nil }
            mutationErrorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteSession(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        guard let sessionID = session.sessionId else { return false }
        mutationErrorMessage = nil
        do {
            guard try await repository.deleteSession(id: sessionID) else {
                throw SessionRepositoryError.unexpectedResponse
            }
            resetPagination()
            await loadInitial(modelContext: modelContext)
            sessions.removeAll { $0.sessionId == sessionID }
            cacheCurrentList(in: modelContext)
            return true
        } catch {
            guard !(error is CancellationError) else { return false }
            mutationErrorMessage = error.localizedDescription
            return false
        }
    }

    func reconcileDeletedSession(
        id: String,
        modelContext: ModelContext? = nil
    ) async {
        resetPagination()
        await loadInitial(modelContext: modelContext)
        sessions.removeAll { $0.sessionId == id }
        cacheCurrentList(in: modelContext)
    }

    func updateSessionSnapshot(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil
    ) {
        sessions.removeAll { $0.sessionId == session.sessionId }
        sessions = Self.visibleUniqueSessions([session] + sessions)
        cacheSession(session, in: modelContext)
    }

    func refreshAfterMembershipMutation(
        modelContext: ModelContext? = nil
    ) async {
        resetPagination()
        await loadInitial(modelContext: modelContext)
    }

    func clearMutationError() {
        mutationErrorMessage = nil
    }

    private func cache(
        _ pageSessions: [SessionSummary],
        completesList: Bool,
        in modelContext: ModelContext?
    ) {
        guard let modelContext else { return }
        do {
            if completesList {
                try CacheStore.cacheSessions(
                    sessions,
                    serverURL: companionURL,
                    in: modelContext
                )
            } else {
                for session in pageSessions {
                    try CacheStore.cacheSession(
                        session,
                        serverURL: companionURL,
                        in: modelContext
                    )
                }
            }
        } catch {
            // Cache is optional read-only support. A server-backed list remains
            // usable even when local persistence maintenance fails.
        }
    }

    private func cacheSession(
        _ session: SessionSummary,
        in modelContext: ModelContext?
    ) {
        guard let modelContext else { return }
        try? CacheStore.cacheSession(
            session,
            serverURL: companionURL,
            in: modelContext
        )
    }

    private func cacheCurrentList(in modelContext: ModelContext?) {
        guard let modelContext else { return }
        try? CacheStore.cacheSessions(
            sessions,
            serverURL: companionURL,
            in: modelContext
        )
    }

    private func resolvedNextOffset(for page: SessionPage, fallback: Int) -> Int {
        guard let offset = page.offset, let limit = page.limit else {
            return fallback
        }
        return offset + limit
    }

    private func resetPagination() {
        nextOffset = 0
        hasMore = false
    }

    private func shouldUseCache(for error: Error) -> Bool {
        switch error {
        case SessionRepositoryError.companionUnreachable,
             SessionRepositoryError.gatewayUnavailable,
             SessionRepositoryError.gatewayTimeout,
             SessionRepositoryError.gatewayTransportFailure:
            return true
        default:
            return false
        }
    }

    private func sortTimestamp(_ session: SessionSummary) -> Double {
        session.lastMessageAt ?? session.updatedAt ?? session.createdAt ?? 0
    }

    private static func visibleUniqueSessions(
        _ sessions: [SessionSummary]
    ) -> [SessionSummary] {
        var seen: Set<String> = []
        return sessions.filter { session in
            guard
                session.shouldAppearInSessionList,
                let sessionID = session.sessionId,
                !sessionID.isEmpty,
                seen.insert(sessionID).inserted
            else {
                return false
            }
            return true
        }
    }
}

struct ConversationRunDeltaBuffer: Equatable {
    static let maximumPendingCharacters = 4_096

    private(set) var pendingText = ""

    var isEmpty: Bool {
        pendingText.isEmpty
    }

    @discardableResult
    mutating func append(_ text: String) -> String {
        pendingText += text
        let overflowCount =
            pendingText.count - Self.maximumPendingCharacters
        guard overflowCount > 0 else { return "" }
        let overflowEnd = pendingText.index(
            pendingText.startIndex,
            offsetBy: overflowCount
        )
        let fastForwarded = String(pendingText[..<overflowEnd])
        pendingText.removeSubrange(..<overflowEnd)
        return fastForwarded
    }

    mutating func drain(maximumCharacters: Int?) -> String {
        guard !pendingText.isEmpty else { return "" }
        guard let maximumCharacters else {
            defer { pendingText = "" }
            return pendingText
        }
        let count = max(1, maximumCharacters)
        let end = pendingText.index(
            pendingText.startIndex,
            offsetBy: count,
            limitedBy: pendingText.endIndex
        ) ?? pendingText.endIndex
        let result = String(pendingText[..<end])
        pendingText.removeSubrange(..<end)
        return result
    }

    mutating func removeAll() {
        pendingText = ""
    }
}

@MainActor
@Observable
final class CompanionSessionHistoryViewModel {
    enum RunPresentationState: Equatable {
        case idle
        case starting
        case streaming
        case waitingForApproval
        case transportDisconnected
        case stopping
        case completed
        case failed(String?)
        case cancelled
    }

    private(set) var session: SessionSummary
    private(set) var allMessages: [ChatMessage] = []
    private(set) var isLoading = false
    private(set) var isViewingCachedData = false
    private(set) var errorMessage: String?
    private(set) var mutationErrorMessage: String?
    private(set) var runState: RunPresentationState = .idle
    private(set) var activeRunID: String?
    private(set) var streamedAssistantText = ""
    private(set) var reasoningText = ""
    private(set) var liveToolCalls: [ToolCall] = []
    private(set) var needsTerminalHistoryRetry = false
    private(set) var pendingApproval: ConversationApprovalRequest?
    private(set) var approvalErrorMessage: String?
    private(set) var approvalSubmissionChoice: ConversationApprovalChoice?
    private(set) var modelGroups: [CompanionModelGroup] = []
    private(set) var selectedModel: CompanionModelSelection?
    private(set) var isLoadingModelOptions = false
    private(set) var isApplyingModelSelection = false
    private(set) var modelSelectionErrorMessage: String?

    private let repository: any SessionRepository
    private let runService: any ConversationRunServing
    private let modelService: any CompanionModelServing
    private let modelSelectionStore: any CompanionModelSelectionStoring
    private let companionURL: URL
    private let pageSize: Int
    private let reconciliationDelayNanoseconds: UInt64
    private let supportsRunApprovals: Bool
    private let supportsModelSelection: Bool
    private var visibleStartIndex = 0
    private var runTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var deltaFlushTask: Task<Void, Never>?
    @ObservationIgnored private var deltaBuffer =
        ConversationRunDeltaBuffer()
    @ObservationIgnored private var fastForwardedDelta = ""
    private var isStopRequestInFlight = false
    private var hasRequestedStop = false
    private var terminalOutputFallback: String?
    private var nextToolOrdinal = 0
    private var isTerminalRefreshPending = false

    init(
        session: SessionSummary,
        repository: any SessionRepository,
        companionURL: URL,
        pageSize: Int = 50,
        runService: (any ConversationRunServing)? = nil,
        supportsRunApprovals: Bool = false,
        supportsModelSelection: Bool = false,
        modelService: (any CompanionModelServing)? = nil,
        modelSelectionStore: (
            any CompanionModelSelectionStoring
        )? = nil,
        reconciliationDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.session = session
        self.repository = repository
        self.companionURL = companionURL
        self.pageSize = max(1, pageSize)
        self.runService = runService ?? ConversationRunService(
            companionURL: companionURL
        )
        self.modelService = modelService ?? CompanionModelService(
            companionURL: companionURL
        )
        self.modelSelectionStore =
            modelSelectionStore ?? CompanionModelSelectionStore()
        self.supportsRunApprovals = supportsRunApprovals
        self.supportsModelSelection = supportsModelSelection
        self.reconciliationDelayNanoseconds =
            reconciliationDelayNanoseconds
    }

    var visibleMessages: [ChatMessage] {
        guard visibleStartIndex < allMessages.count else { return [] }
        return Array(allMessages[visibleStartIndex...])
    }

    var hasOlderMessages: Bool {
        visibleStartIndex > 0
    }

    var isRunActive: Bool {
        activeRunID != nil || runState == .starting
    }

    var canSend: Bool {
        !isRunActive
            && !isLoading
            && !isViewingCachedData
            && !isTerminalRefreshPending
            && !isApplyingModelSelection
            && errorMessage == nil
    }

    var canRequestStop: Bool {
        activeRunID != nil && !hasRequestedStop
    }

    var canChangeModel: Bool {
        supportsModelSelection
            && !isRunActive
            && !isLoadingModelOptions
            && !isApplyingModelSelection
            && !isViewingCachedData
    }

    var selectedModelOption: CompanionModelOption? {
        guard let selectedModel else { return nil }
        return modelGroups
            .flatMap(\.models)
            .first {
                $0.model == selectedModel.model
                    && $0.provider == selectedModel.provider
            }
    }

    var selectedModelDisplayName: String {
        selectedModelOption?.model
            ?? selectedModel?.model
            ?? String(localized: "Model")
    }

    var selectedModelSupportsReasoning: Bool {
        selectedModelOption?.supportsReasoning == true
    }

    var selectedReasoningDisplayName: String {
        selectedModel?.reasoningEffort?.displayName
            ?? String(localized: "Reasoning")
    }

    var isApprovalSubmissionInFlight: Bool {
        approvalSubmissionChoice != nil
    }

    var approvalContextUnavailable: Bool {
        supportsRunApprovals
            && isRunActive
            && runState == .waitingForApproval
            && pendingApproval == nil
    }

    func canRespondToApproval(
        _ choice: ConversationApprovalChoice
    ) -> Bool {
        guard
            let pendingApproval,
            pendingApproval.runID == activeRunID
        else {
            return false
        }
        return supportsRunApprovals
            && pendingApproval.choices.contains(choice)
            && !isApprovalSubmissionInFlight
            && !hasRequestedStop
    }

    var terminalHistoryRetryMessage: String {
        errorMessage ?? String(
            localized: "Could not refresh authoritative session history."
        )
    }

    var runStatusText: String? {
        switch runState {
        case .idle:
            return nil
        case .starting:
            return String(localized: "Starting...")
        case .streaming:
            return String(localized: "Hermes is responding")
        case .waitingForApproval:
            return String(localized: "Hermes is waiting for your approval")
        case .transportDisconnected:
            return String(localized: "Live response disconnected · checking run")
        case .stopping:
            return String(localized: "Stopping...")
        case .completed:
            return String(localized: "Completed")
        case .failed(let message):
            return message ?? String(localized: "Run failed")
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }

    var streamingMessage: ChatMessage? {
        guard !streamedAssistantText.isEmpty else { return nil }
        return ChatMessage(
            role: "assistant",
            content: streamedAssistantText,
            timestamp: nil,
            messageId: activeRunID.map { "stream-\($0)" }
        )
    }

    @discardableResult
    func load(modelContext: ModelContext? = nil) async -> Bool {
        guard let sessionID = session.sessionId, !isLoading else {
            return false
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let cached = cachedMessages(sessionID: sessionID, in: modelContext)
        if allMessages.isEmpty, !cached.isEmpty {
            apply(cached)
            isViewingCachedData = true
        }

        do {
            let history = try await repository.messageHistory(id: sessionID)
            let resolvedSession = try await repository.session(
                id: history.sessionID
            )
            session = resolvedSession
            apply(history.messages)
            isViewingCachedData = false
            cache(
                history.messages,
                sessionID: history.sessionID,
                in: modelContext
            )
            cacheSession(resolvedSession, in: modelContext)
            if needsTerminalHistoryRetry {
                clearTerminalFallbackPresentation()
                needsTerminalHistoryRetry = false
            }
            return true
        } catch {
            guard !(error is CancellationError) else { return false }
            if shouldUseCache(for: error), !cached.isEmpty {
                apply(cached)
                isViewingCachedData = true
            } else {
                allMessages = []
                visibleStartIndex = 0
                isViewingCachedData = false
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func loadOlderMessages() {
        visibleStartIndex = max(0, visibleStartIndex - pageSize)
    }

    func loadModelOptions(refresh: Bool = false) async {
        guard
            supportsModelSelection,
            !isLoadingModelOptions
        else {
            return
        }
        isLoadingModelOptions = true
        modelSelectionErrorMessage = nil
        defer { isLoadingModelOptions = false }

        do {
            let inventory = try await modelService.fetchOptions(
                refresh: refresh
            )
            modelGroups = inventory.catalogGroups
            if selectedModel == nil {
                let persistedSelection: CompanionModelSelection?
                if let sessionID = session.sessionId {
                    persistedSelection = await modelSelectionStore.load(
                        companionURL: companionURL,
                        sessionID: sessionID
                    )
                } else {
                    persistedSelection = nil
                }
                let resolvedSelection = resolvedSessionSelection(
                    inventory: inventory,
                    persistedSelection: persistedSelection
                )
                selectedModel = resolvedSelection
                if
                    let persistedSelection,
                    let resolvedSelection,
                    persistedSelection.model == resolvedSelection.model,
                    persistedSelection.provider == resolvedSelection.provider,
                    persistedSelection.reasoningEffort
                        != resolvedSelection.reasoningEffort,
                    let sessionID = session.sessionId
                {
                    await modelSelectionStore.save(
                        resolvedSelection,
                        companionURL: companionURL,
                        sessionID: sessionID
                    )
                }
            }
        } catch {
            guard !(error is CancellationError) else { return }
            modelSelectionErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func selectModel(_ option: CompanionModelOption) async -> Bool {
        let reasoning = option.supportsReasoning
            ? selectedModel?.reasoningEffort
            : nil
        return await lockModelSelection(
            CompanionModelSelection(
                model: option.model,
                provider: option.provider,
                reasoningEffort: reasoning
            )
        )
    }

    @discardableResult
    func selectReasoning(
        _ effort: CompanionReasoningEffort
    ) async -> Bool {
        guard
            selectedModelSupportsReasoning,
            let selectedModel
        else {
            return false
        }
        return await lockModelSelection(
            CompanionModelSelection(
                model: selectedModel.model,
                provider: selectedModel.provider,
                reasoningEffort: effort
            )
        )
    }

    @discardableResult
    func retryTerminalHistory(
        modelContext: ModelContext? = nil
    ) async -> Bool {
        guard needsTerminalHistoryRetry else { return false }
        return await load(modelContext: modelContext)
    }

    func rename(
        to title: String,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        guard let sessionID = session.sessionId else { return false }
        mutationErrorMessage = nil
        do {
            session = try await repository.updateSession(
                id: sessionID,
                request: SessionUpdateRequest(title: title)
            )
            cacheSession(session, in: modelContext)
            return true
        } catch {
            guard !(error is CancellationError) else { return false }
            mutationErrorMessage = error.localizedDescription
            return false
        }
    }

    func fork(modelContext: ModelContext? = nil) async -> SessionSummary? {
        guard let sessionID = session.sessionId else { return nil }
        mutationErrorMessage = nil
        do {
            let forked = try await repository.forkSession(
                id: sessionID,
                request: SessionForkRequest()
            )
            cacheSession(forked, in: modelContext)
            return forked
        } catch {
            guard !(error is CancellationError) else { return nil }
            mutationErrorMessage = error.localizedDescription
            return nil
        }
    }

    func delete() async -> Bool {
        guard let sessionID = session.sessionId else { return false }
        mutationErrorMessage = nil
        do {
            guard try await repository.deleteSession(id: sessionID) else {
                throw SessionRepositoryError.unexpectedResponse
            }
            return true
        } catch {
            guard !(error is CancellationError) else { return false }
            mutationErrorMessage = error.localizedDescription
            return false
        }
    }

    func clearMutationError() {
        mutationErrorMessage = nil
    }

    @discardableResult
    func send(
        _ input: String,
        modelContext: ModelContext? = nil
    ) async -> Bool {
        guard
            canSend,
            let sessionID = session.sessionId,
            !sessionID.isEmpty
        else {
            return false
        }
        let trimmed = input.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return false }

        cancelRunTasks()
        let authoritativeHistory = allMessages
        let optimisticUser = ChatMessage(
            role: "user",
            content: trimmed,
            timestamp: Date().timeIntervalSince1970,
            messageId: "local-\(UUID().uuidString)"
        )
        apply(allMessages + [optimisticUser])
        streamedAssistantText = ""
        reasoningText = ""
        liveToolCalls = []
        pendingApproval = nil
        approvalErrorMessage = nil
        approvalSubmissionChoice = nil
        deltaBuffer.removeAll()
        fastForwardedDelta = ""
        hasRequestedStop = false
        terminalOutputFallback = nil
        nextToolOrdinal = 0
        runState = .starting
        errorMessage = nil

        let started: ConversationRunSnapshot
        do {
            started = try await runService.start(
                ConversationRunStartRequest(
                    input: trimmed,
                    sessionID: sessionID,
                    conversationHistory: authoritativeHistory,
                    selection: selectedModel
                )
            )
        } catch {
            apply(authoritativeHistory)
            runState = .failed(error.localizedDescription)
            return false
        }

        activeRunID = started.runID
        runState = .streaming
        runTask = Task { [weak self] in
            await self?.consumeEvents(
                runID: started.runID,
                modelContext: modelContext
            )
        }
        return true
    }

    private func lockModelSelection(
        _ selection: CompanionModelSelection
    ) async -> Bool {
        guard
            canChangeModel,
            let sessionID = session.sessionId
        else {
            return false
        }
        isApplyingModelSelection = true
        modelSelectionErrorMessage = nil
        defer { isApplyingModelSelection = false }
        do {
            _ = try await modelService.lock(
                selection,
                sessionID: sessionID
            )
            await modelSelectionStore.save(
                selection,
                companionURL: companionURL,
                sessionID: sessionID
            )
            selectedModel = selection
            return true
        } catch {
            guard !(error is CancellationError) else { return false }
            modelSelectionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func resolvedSessionSelection(
        inventory: CompanionModelInventory,
        persistedSelection: CompanionModelSelection?
    ) -> CompanionModelSelection? {
        let options = inventory.catalogGroups.flatMap(\.models)
        let persistedSessionModel = session.model?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty
        let persistedSessionProvider =
            session.modelProvider?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nilIfEmpty
        if
            let persistedSelection,
            let persistedOption = options.first(where: {
                $0.model == persistedSelection.model
                    && $0.provider == persistedSelection.provider
            }),
            persistedSessionModel == nil
                || persistedSessionModel == persistedSelection.model,
            persistedSessionProvider == nil
                || persistedSessionProvider == persistedSelection.provider
        {
            return CompanionModelSelection(
                model: persistedSelection.model,
                provider: persistedSelection.provider,
                reasoningEffort: persistedOption.supportsReasoning
                    ? persistedSelection.reasoningEffort
                    : nil
            )
        }
        if let sessionModel = session.model?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty {
            let matches = options.filter {
                $0.model == sessionModel
                    && (
                        session.modelProvider == nil
                            || $0.provider == session.modelProvider
                    )
            }
            if matches.count == 1, let match = matches.first {
                return CompanionModelSelection(
                    model: match.model,
                    provider: match.provider,
                    reasoningEffort: nil
                )
            }
            if inventory.currentSelection?.model == sessionModel {
                return inventory.currentSelection
            }
        }
        return inventory.currentSelection
    }

    func stopRun(modelContext: ModelContext? = nil) async {
        guard
            let runID = activeRunID,
            !isStopRequestInFlight,
            !hasRequestedStop
        else {
            return
        }
        isStopRequestInFlight = true
        hasRequestedStop = true
        runState = .stopping
        defer { isStopRequestInFlight = false }

        do {
            let snapshot = try await runService.stop(runID: runID)
            guard activeRunID == runID else { return }
            terminalOutputFallback = snapshot.output
            applyRunSnapshot(snapshot)
            if snapshot.state.isTerminal {
                await finishRun(
                    runID: runID,
                    modelContext: modelContext
                )
            } else {
                beginReconciliation(
                    runID: runID,
                    modelContext: modelContext
                )
            }
        } catch {
            guard !(error is CancellationError) else { return }
            guard activeRunID == runID else { return }
            runState = .transportDisconnected
            beginReconciliation(
                runID: runID,
                modelContext: modelContext
            )
        }
    }

    func respondToApproval(
        _ choice: ConversationApprovalChoice,
        modelContext: ModelContext? = nil
    ) async {
        guard
            canRespondToApproval(choice),
            let runID = activeRunID,
            let approval = pendingApproval
        else {
            return
        }
        approvalSubmissionChoice = choice
        approvalErrorMessage = nil

        do {
            _ = try await runService.respondToApproval(
                runID: runID,
                choice: choice
            )
            guard activeRunID == runID else { return }
            guard pendingApproval == approval else {
                approvalSubmissionChoice = nil
                approvalErrorMessage = String(
                    localized: "Approval changed while the decision was in flight. Checking the existing run."
                )
                await reconcileApproval(
                    runID: runID,
                    modelContext: modelContext
                )
                return
            }
            pendingApproval = nil
            approvalSubmissionChoice = nil
            if runState != .stopping {
                runState = .streaming
            }
        } catch is CancellationError {
            guard activeRunID == runID else { return }
            pendingApproval = nil
            approvalSubmissionChoice = nil
            approvalErrorMessage = String(
                localized: "Approval submission was cancelled. Checking the existing run."
            )
            if runState != .stopping {
                runState = .transportDisconnected
            }
            beginReconciliation(
                runID: runID,
                modelContext: modelContext
            )
        } catch {
            guard activeRunID == runID else { return }
            pendingApproval = nil
            approvalSubmissionChoice = nil
            approvalErrorMessage = error.localizedDescription
            guard
                let serviceError =
                    error as? ConversationRunServiceError
            else {
                return
            }
            switch serviceError {
            case .approvalNotPending:
                await reconcileApproval(
                    runID: runID,
                    modelContext: modelContext
                )
            case .runNotFound:
                runState = .failed(error.localizedDescription)
                await finishRun(
                    runID: runID,
                    modelContext: modelContext
                )
            default:
                await reconcileApproval(
                    runID: runID,
                    modelContext: modelContext
                )
            }
        }
    }

    private func consumeEvents(
        runID: String,
        modelContext: ModelContext?
    ) async {
        var observedTerminal = false
        do {
            let events = try await runService.events(runID: runID)
            for try await event in events {
                guard activeRunID == runID else { return }
                switch event {
                case .comment:
                    break
                case .malformed:
                    continue
                case .data(let payload):
                    guard payload.runID == nil || payload.runID == runID else {
                        continue
                    }
                    let event = payload.semanticEvent
                    if event == "approval.request" {
                        let submissionWasInFlight =
                            approvalSubmissionChoice != nil
                        pendingApproval = nil
                        approvalErrorMessage = submissionWasInFlight
                            ? String(
                                localized: "Approval changed while the decision was in flight. Checking the existing run."
                            )
                            : nil
                        if !submissionWasInFlight {
                            approvalSubmissionChoice = nil
                        }
                        if runState != .stopping {
                            runState = .waitingForApproval
                        }
                        if !submissionWasInFlight,
                           runState != .stopping,
                           supportsRunApprovals,
                           let approval = payload.approvalRequest(
                               expectedRunID: runID
                           ) {
                            pendingApproval = approval
                        }
                    }
                    if event == "approval.responded" {
                        pendingApproval = nil
                        approvalErrorMessage = nil
                        approvalSubmissionChoice = nil
                        if runState != .stopping {
                            runState = .streaming
                        }
                    }
                    if event == "message.delta",
                       let delta = payload.delta {
                        enqueue(delta)
                    }
                    if event == "reasoning.available",
                       let text = payload.text {
                        reasoningText = text
                    }
                    if event == "tool.started" {
                        applyToolStarted(payload, runID: runID)
                    }
                    if event == "tool.completed" {
                        applyToolCompleted(payload, runID: runID)
                    }
                    if let terminal = terminalState(
                        for: event,
                        error: payload.error
                    ) {
                        observedTerminal = true
                        runState = terminal
                        terminalOutputFallback = payload.output
                        runTask = nil
                        await finishRun(
                            runID: runID,
                            modelContext: modelContext
                        )
                        return
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeRunID == runID else { return }
        }

        guard !observedTerminal, activeRunID == runID else { return }
        runTask = nil
        flushPendingDelta(forceAll: true)
        pendingApproval = nil
        approvalSubmissionChoice = nil
        approvalErrorMessage = String(
            localized: "Live approval details disconnected. Checking the existing run."
        )
        if runState != .stopping {
            runState = .transportDisconnected
        }
        beginReconciliation(
            runID: runID,
            modelContext: modelContext
        )
    }

    private func enqueue(_ delta: String) {
        fastForwardedDelta += deltaBuffer.append(delta)
        guard deltaFlushTask == nil else { return }
        scheduleDeltaFlush()
    }

    private func scheduleDeltaFlush() {
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingDelta()
        }
    }

    private func flushPendingDelta(forceAll: Bool = false) {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        let drained = deltaBuffer.drain(
            maximumCharacters: forceAll ? nil : 192
        )
        let published = fastForwardedDelta + drained
        fastForwardedDelta = ""
        guard !published.isEmpty else { return }
        streamedAssistantText += published
        if !deltaBuffer.isEmpty {
            scheduleDeltaFlush()
        }
    }

    private func beginReconciliation(
        runID: String,
        modelContext: ModelContext?
    ) {
        guard reconciliationTask == nil else { return }
        reconciliationTask = Task { [weak self] in
            guard let self else { return }
            defer { reconciliationTask = nil }
            while !Task.isCancelled, activeRunID == runID {
                do {
                    let snapshot = try await runService.status(runID: runID)
                    guard activeRunID == runID else { return }
                    terminalOutputFallback = snapshot.output
                        ?? terminalOutputFallback
                    applyRunSnapshot(snapshot)
                    if snapshot.state.isTerminal {
                        reconciliationTask = nil
                        await finishRun(
                            runID: runID,
                            modelContext: modelContext
                        )
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard activeRunID == runID else { return }
                    runState = .transportDisconnected
                }
                try? await Task.sleep(
                    nanoseconds: reconciliationDelayNanoseconds
                )
            }
        }
    }

    private func reconcileApproval(
        runID: String,
        modelContext: ModelContext?
    ) async {
        do {
            let snapshot = try await runService.status(runID: runID)
            guard activeRunID == runID else { return }
            terminalOutputFallback = snapshot.output
                ?? terminalOutputFallback
            applyRunSnapshot(snapshot)
            if snapshot.state.isTerminal {
                await finishRun(
                    runID: runID,
                    modelContext: modelContext
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeRunID == runID else { return }
            runState = .transportDisconnected
            beginReconciliation(
                runID: runID,
                modelContext: modelContext
            )
        }
    }

    private func applyRunSnapshot(_ snapshot: ConversationRunSnapshot) {
        switch snapshot.state {
        case .started, .queued, .running:
            if runState != .transportDisconnected,
               runState != .stopping {
                runState = .streaming
            }
        case .waitingForApproval:
            if runState != .stopping {
                runState = .waitingForApproval
            }
        case .stopping:
            runState = .stopping
        case .completed:
            runState = .completed
        case .failed:
            runState = .failed(snapshot.errorMessage)
        case .cancelled:
            runState = .cancelled
        case .unknown:
            runState = .transportDisconnected
        }
    }

    private func terminalState(
        for event: String?,
        error: String?
    ) -> RunPresentationState? {
        switch event {
        case "run.completed":
            return .completed
        case "run.failed":
            return .failed(error)
        case "run.cancelled":
            return .cancelled
        default:
            return nil
        }
    }

    private func finishRun(
        runID: String,
        modelContext: ModelContext?
    ) async {
        guard activeRunID == runID else { return }
        flushPendingDelta(forceAll: true)
        if let terminalOutputFallback,
           !terminalOutputFallback.isEmpty {
            streamedAssistantText = terminalOutputFallback
        }
        let messagesBeforeRefresh = allMessages
        isTerminalRefreshPending = true
        activeRunID = nil
        pendingApproval = nil
        approvalErrorMessage = nil
        approvalSubmissionChoice = nil
        runTask?.cancel()
        runTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        let loadedAuthoritativeHistory = await refreshHistoryAfterTerminal(
            modelContext: modelContext
        )
        if loadedAuthoritativeHistory {
            clearTerminalFallbackPresentation()
            needsTerminalHistoryRetry = false
        } else {
            apply(messagesBeforeRefresh)
            needsTerminalHistoryRetry = true
        }
        hasRequestedStop = false
        terminalOutputFallback = nil
        isTerminalRefreshPending = false
    }

    private func refreshHistoryAfterTerminal(
        modelContext: ModelContext?
    ) async -> Bool {
        while isLoading {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
        }
        return await load(modelContext: modelContext)
    }

    private func clearTerminalFallbackPresentation() {
        streamedAssistantText = ""
        reasoningText = ""
        liveToolCalls = []
    }

    private func cancelRunTasks() {
        runTask?.cancel()
        runTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
    }

    private func applyToolStarted(
        _ payload: ConversationRunEventData,
        runID: String
    ) {
        let id = payload.toolCallID?.nonEmptyRunValue
            ?? "\(runID)-tool-\(nextToolOrdinal)"
        nextToolOrdinal += 1
        if let index = liveToolCalls.firstIndex(where: { $0.id == id }) {
            liveToolCalls[index].name = payload.tool
                ?? liveToolCalls[index].name
            liveToolCalls[index].preview = payload.preview
                ?? liveToolCalls[index].preview
            return
        }
        liveToolCalls.append(
            ToolCall(
                id: id,
                name: payload.tool,
                preview: payload.preview,
                args: nil,
                startedAt: payload.timestamp
                    ?? Date().timeIntervalSince1970
            )
        )
    }

    private func applyToolCompleted(
        _ payload: ConversationRunEventData,
        runID: String
    ) {
        let index: Int?
        if let id = payload.toolCallID?.nonEmptyRunValue {
            index = liveToolCalls.firstIndex(where: { $0.id == id })
        } else {
            index = liveToolCalls.lastIndex(where: {
                !$0.isCompleted
                    && (payload.tool == nil || $0.name == payload.tool)
            })
        }
        if let index {
            liveToolCalls[index].name = payload.tool
                ?? liveToolCalls[index].name
            liveToolCalls[index].duration = payload.duration
            liveToolCalls[index].isError = payload.isError
            liveToolCalls[index].isCompleted = true
            return
        }

        let id = payload.toolCallID?.nonEmptyRunValue
            ?? "\(runID)-tool-\(nextToolOrdinal)"
        nextToolOrdinal += 1
        liveToolCalls.append(
            ToolCall(
                id: id,
                name: payload.tool,
                preview: payload.preview,
                args: nil,
                duration: payload.duration,
                isError: payload.isError,
                isCompleted: true,
                startedAt: payload.timestamp
                    ?? Date().timeIntervalSince1970
            )
        )
    }

    private func apply(_ messages: [ChatMessage]) {
        allMessages = messages
        visibleStartIndex = max(0, messages.count - pageSize)
    }

    private func cachedMessages(
        sessionID: String,
        in modelContext: ModelContext?
    ) -> [ChatMessage] {
        guard let modelContext else { return [] }
        return (try? CacheStore.cachedMessages(
            serverURL: companionURL,
            sessionID: sessionID,
            in: modelContext
        )) ?? []
    }

    private func cache(
        _ messages: [ChatMessage],
        sessionID: String,
        in modelContext: ModelContext?
    ) {
        guard let modelContext else { return }
        try? CacheStore.cacheMessages(
            messages,
            serverURL: companionURL,
            sessionID: sessionID,
            in: modelContext
        )
    }

    private func cacheSession(
        _ session: SessionSummary,
        in modelContext: ModelContext?
    ) {
        guard let modelContext else { return }
        try? CacheStore.cacheSession(
            session,
            serverURL: companionURL,
            in: modelContext
        )
    }

    private func shouldUseCache(for error: Error) -> Bool {
        switch error {
        case SessionRepositoryError.companionUnreachable,
             SessionRepositoryError.gatewayUnavailable,
             SessionRepositoryError.gatewayTimeout,
             SessionRepositoryError.gatewayTransportFailure:
            return true
        default:
            return false
        }
    }
}

private extension String {
    var nonEmptyRunValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
