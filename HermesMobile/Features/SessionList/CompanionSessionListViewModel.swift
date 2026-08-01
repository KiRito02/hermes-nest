import Foundation
import Observation
import SwiftData

enum CompanionModelPresentation {
    static func friendlyName(for identifier: String) -> String {
        let leaf = identifier
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !leaf.isEmpty else {
            return String(localized: "Model")
        }

        let words = leaf.split { character in
            character == "-"
                || character == "_"
                || character == ":"
                || character.isWhitespace
        }
        return words.map(styledWord).joined(separator: " ")
    }

    private static func styledWord(_ word: Substring) -> String {
        let value = String(word)
        let lowercased = value.lowercased()
        switch lowercased {
        case "gpt":
            return "GPT"
        case "claude":
            return "Claude"
        case "sonnet":
            return "Sonnet"
        case "opus":
            return "Opus"
        case "haiku":
            return "Haiku"
        case "codex":
            return "Codex"
        case "gemini":
            return "Gemini"
        case "qwen":
            return "Qwen"
        case "llama":
            return "Llama"
        case "hermes":
            return "Hermes"
        case "mistral":
            return "Mistral"
        case "deepseek":
            return "DeepSeek"
        default:
            if lowercased.hasPrefix("gpt") {
                return "GPT" + String(value.dropFirst(3))
            }
            if lowercased.hasPrefix("qwen") {
                return "Qwen" + String(value.dropFirst(4))
            }
            if !lowercased.dropLast().isEmpty,
               lowercased.dropLast().allSatisfy(\.isNumber),
               lowercased.last == "b" {
                return String(lowercased.dropLast()) + "B"
            }
            return value.prefix(1).uppercased()
                + String(value.dropFirst())
        }
    }
}

enum CompanionTokenPresentation {
    static func exactCount(
        _ tokens: Int,
        locale: Locale = .current
    ) -> String {
        tokens.formatted(
            .number
                .locale(locale)
        )
    }
}

extension CompanionModelOption {
    var presentationName: String {
        CompanionModelPresentation.friendlyName(for: model)
    }
}

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
    private var pendingCreatedSession: SessionSummary?

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

    func createSession() async -> SessionSummary? {
        mutationErrorMessage = nil
        do {
            let created = try await repository.createSession(
                SessionCreateRequest()
            )
            pendingCreatedSession = created
            return created
        } catch {
            guard !(error is CancellationError) else { return nil }
            mutationErrorMessage = error.localizedDescription
            return nil
        }
    }

    func sessionForNavigation(id: String?) -> SessionSummary? {
        guard let id else { return nil }
        if let listed = sessions.first(where: { $0.id == id }) {
            return listed
        }
        guard pendingCreatedSession?.id == id else { return nil }
        return pendingCreatedSession
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
            clearPendingCreatedSession(id: sessionID)
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
        clearPendingCreatedSession(id: id)
        cacheCurrentList(in: modelContext)
    }

    func updateSessionSnapshot(
        _ session: SessionSummary,
        modelContext: ModelContext? = nil
    ) {
        sessions.removeAll { $0.sessionId == session.sessionId }
        sessions = Self.visibleUniqueSessions([session] + sessions)
        if sessions.contains(where: { $0.id == session.id }) {
            clearPendingCreatedSession(id: session.id)
        } else if pendingCreatedSession?.id == session.id {
            pendingCreatedSession = session
        }
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

    private func clearPendingCreatedSession(id: String) {
        guard pendingCreatedSession?.id == id else { return }
        pendingCreatedSession = nil
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
    /// Keep individual allocations bounded while retaining the complete
    /// presentation backlog. Dropping the oldest prefix or publishing it in
    /// one jump makes recovery snapshots look non-streaming.
    private static let maximumSegmentCharacters = 4_096
    private var segments: [String] = []

    var pendingText: String {
        segments.joined()
    }

    var isEmpty: Bool {
        segments.isEmpty
    }

    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        var remainder = text[...]
        while !remainder.isEmpty {
            let end = remainder.index(
                remainder.startIndex,
                offsetBy: Self.maximumSegmentCharacters,
                limitedBy: remainder.endIndex
            ) ?? remainder.endIndex
            segments.append(String(remainder[..<end]))
            remainder = remainder[end...]
        }
    }

    mutating func drain(maximumCharacters: Int?) -> String {
        guard !segments.isEmpty else { return "" }
        guard let maximumCharacters else {
            let output = segments.joined()
            segments.removeAll(keepingCapacity: true)
            return output
        }
        var remainingBudget = max(1, maximumCharacters)
        var output = ""
        while remainingBudget > 0, let first = segments.first {
            let end = first.index(
                first.startIndex,
                offsetBy: remainingBudget,
                limitedBy: first.endIndex
            ) ?? first.endIndex
            output += String(first[..<end])
            let drainedCount = first.distance(
                from: first.startIndex,
                to: end
            )
            remainingBudget -= drainedCount
            if end == first.endIndex {
                segments.removeFirst()
            } else {
                segments[0] = String(first[end...])
            }
        }
        return output
    }

    mutating func removeAll() {
        segments.removeAll(keepingCapacity: true)
    }
}

private struct FailedAttachmentUpload: Sendable {
    let fileURL: URL
    let filename: String
    let contentType: String
    let destination: CompanionUploadDestination
}

/// Keeps a session's presentation model alive while its run event stream is
/// active, even when compact navigation temporarily removes the detail view,
/// with four observed runs plus one bounded foreground browsing entry.
/// Gateway run event queues are single-use, so recreating the view model after
/// a pop can recover through status polling but cannot restore the live SSE.
@MainActor
final class CompanionSessionHistoryViewModelRegistry {
    private struct Entry {
        let viewModel: CompanionSessionHistoryViewModel
        var lastAccess: UInt64
    }

    /// Four entries may own run observations; one extra entry represents the
    /// currently browsed, non-running chat when every event slot is occupied.
    private let maximumEntries =
        CompanionSessionPool.maximumConcurrentEventStreams + 1
    private var entries: [String: Entry] = [:]
    private var accessSequence: UInt64 = 0

    func viewModel(
        for session: SessionSummary,
        make: () -> CompanionSessionHistoryViewModel
    ) -> CompanionSessionHistoryViewModel {
        accessSequence &+= 1
        if var existing = entries[session.id] {
            existing.lastAccess = accessSequence
            entries[session.id] = existing
            configureRunAdmission(
                for: existing.viewModel,
                sessionID: session.id
            )
            evictOverflow(keeping: session.id)
            return existing.viewModel
        }

        let viewModel = make()
        configureRunAdmission(for: viewModel, sessionID: session.id)
        entries[session.id] = Entry(
            viewModel: viewModel,
            lastAccess: accessSequence
        )
        evictOverflow(keeping: session.id)
        return viewModel
    }

    func remove(sessionID: String) {
        guard let entry = entries.removeValue(forKey: sessionID) else {
            return
        }
        entry.viewModel.revokeRunStartAdmission()
        entry.viewModel.suspendRunObservation()
    }

    func adopt(
        _ viewModel: CompanionSessionHistoryViewModel,
        sessionID: String
    ) {
        accessSequence &+= 1
        if let existing = entries[sessionID],
           existing.viewModel !== viewModel {
            existing.viewModel.revokeRunStartAdmission()
            existing.viewModel.suspendRunObservation()
        }
        configureRunAdmission(for: viewModel, sessionID: sessionID)
        entries[sessionID] = Entry(
            viewModel: viewModel,
            lastAccess: accessSequence
        )
        evictOverflow(keeping: sessionID)
    }

    func suspendObservations() {
        for entry in entries.values {
            entry.viewModel.suspendRunObservation()
        }
    }

    func removeAll() {
        for entry in entries.values {
            entry.viewModel.revokeRunStartAdmission()
            entry.viewModel.suspendRunObservation()
        }
        entries.removeAll()
    }

    private func evictOverflow(keeping retainedSessionID: String) {
        let candidates = entries
            .filter { key, _ in key != retainedSessionID }
            .sorted { lhs, rhs in
                let lhsPriority = evictionPriority(
                    for: lhs.value.viewModel
                )
                let rhsPriority = evictionPriority(
                    for: rhs.value.viewModel
                )
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.value.lastAccess < rhs.value.lastAccess
            }
        let removalCount = max(0, entries.count - maximumEntries)
        for (sessionID, _) in candidates.prefix(removalCount) {
            remove(sessionID: sessionID)
        }
    }

    private func evictionPriority(
        for viewModel: CompanionSessionHistoryViewModel
    ) -> Int {
        if !viewModel.isRunActive {
            return 0
        }
        // A started run has an authoritative ID and can recover through status
        // polling. A pending start has no discoverable identity yet, so retain
        // it until the start response is recorded.
        return viewModel.runState == .starting ? 2 : 1
    }

    private func configureRunAdmission(
        for viewModel: CompanionSessionHistoryViewModel,
        sessionID: String
    ) {
        viewModel.configureRunStartAdmission { [weak self] in
            guard let self else { return true }
            let occupiedSlots = self.entries.reduce(into: 0) {
                count, entry in
                guard entry.key != sessionID else { return }
                if entry.value.viewModel.isRunActive {
                    count += 1
                }
            }
            return occupiedSlots
                < CompanionSessionPool.maximumConcurrentEventStreams
        }
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

        var isTerminalPresentation: Bool {
            switch self {
            case .completed, .failed, .cancelled:
                return true
            case .idle, .starting, .streaming, .waitingForApproval,
                 .transportDisconnected, .stopping:
                return false
            }
        }
    }

    private(set) var session: SessionSummary
    private(set) var allMessages: [ChatMessage] = []
    private(set) var isLoading = true
    private(set) var isViewingCachedData = false
    private(set) var errorMessage: String?
    private(set) var mutationErrorMessage: String?
    private(set) var runState: RunPresentationState = .idle
    private(set) var activeRunID: String?
    private(set) var streamedAssistantText = ""
    private(set) var reasoningText = ""
    private(set) var liveToolCalls: [ToolCall] = []
    private(set) var isWaitingForVisibleRunProgress = false
    private(set) var streamingFollowTrigger = 0
    private(set) var durableReasoningGroups: [ReasoningGroup] = []
    private(set) var durableToolCallGroups: [ToolCallGroup] = []
    private(set) var needsTerminalHistoryRetry = false
    private(set) var pendingApproval: ConversationApprovalRequest?
    private(set) var approvalErrorMessage: String?
    private(set) var approvalSubmissionChoice: ConversationApprovalChoice?
    private(set) var modelGroups: [CompanionModelGroup] = []
    private(set) var selectedModel: CompanionModelSelection?
    private(set) var isLoadingModelOptions = false
    private(set) var isApplyingModelSelection = false
    private(set) var modelSelectionErrorMessage: String?
    private(set) var latestRunUsage: ConversationRunUsage?
    private(set) var pendingUploads: [CompanionUpload] = []
    private(set) var isUploadingAttachment = false
    private(set) var isPreparingDroppedAttachments = false
    private(set) var stagedDroppedAttachments:
        [CompanionStagedAttachment] = []
    private(set) var attachmentUploadProgress: Double?
    private(set) var attachmentErrorMessage: String?
    private(set) var hasLoadedAuthoritativeHistory = false
    private var failedAttachmentUpload: FailedAttachmentUpload?

    private let repository: any SessionRepository
    private let runService: any ConversationRunServing
    private let activeRunStore: any CompanionActiveRunStoring
    private let modelService: any CompanionModelServing
    private let modelSelectionStore: any CompanionModelSelectionStoring
    private let workspaceService: any CompanionWorkspaceServing
    private let attachmentStager: any CompanionAttachmentStaging
    private let companionURL: URL
    private let pageSize: Int
    private let reconciliationDelayNanoseconds: UInt64
    private let supportsRunApprovals: Bool
    private let supportsModelSelection: Bool
    private var visibleStartIndex = 0
    private var runTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var terminalUsageRefreshTask: Task<Void, Never>?
    private var terminalUsageRefreshRunID: String?
    private var deltaFlushTask: Task<Void, Never>?
    private var thinkingIndicatorTask: Task<Void, Never>?
    private var runObservationGeneration: UInt64 = 0
    private var isRunObservationRequested = true
    private var runStartAdmission: (() -> Bool)?
    @ObservationIgnored private var deltaBuffer =
        ConversationRunDeltaBuffer()
    private var liveRunAnchorMessageIDs: Set<String> = []
    private var isStopRequestInFlight = false
    private var stopRecoveryState: CompanionStopRecoveryState = .notRequested
    private var terminalOutputFallback: String?
    private var terminalPresentationRunID: String?
    private var nextToolOrdinal = 0
    private var isTerminalRefreshPending = false
    private var isHistoryRequestInFlight = false

    init(
        session: SessionSummary,
        repository: any SessionRepository,
        companionURL: URL,
        pageSize: Int = 50,
        runService: (any ConversationRunServing)? = nil,
        supportsRunApprovals: Bool = false,
        supportsModelSelection: Bool = false,
        modelService: (any CompanionModelServing)? = nil,
        workspaceService: (any CompanionWorkspaceServing)? = nil,
        attachmentStager: (any CompanionAttachmentStaging)? = nil,
        modelSelectionStore: (
            any CompanionModelSelectionStoring
        )? = nil,
        activeRunStore: (
            any CompanionActiveRunStoring
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
        self.activeRunStore = activeRunStore ?? CompanionActiveRunStore()
        self.modelService = modelService ?? CompanionModelService(
            companionURL: companionURL
        )
        self.modelSelectionStore =
            modelSelectionStore ?? CompanionModelSelectionStore()
        self.workspaceService = workspaceService
            ?? CompanionWorkspaceService(companionURL: companionURL)
        self.attachmentStager =
            attachmentStager ?? CompanionAttachmentStager()
        self.supportsRunApprovals = supportsRunApprovals
        self.supportsModelSelection = supportsModelSelection
        self.reconciliationDelayNanoseconds =
            reconciliationDelayNanoseconds
    }

    var visibleMessages: [ChatMessage] {
        guard visibleStartIndex < allMessages.count else { return [] }
        return allMessages[visibleStartIndex...].filter { message in
            message.role != "tool"
                && !TranscriptTurnClassifier.isToolResultOnlyMessage(message)
                && !isHiddenAssistantPlaceholder(message)
        }
    }

    private func isHiddenAssistantPlaceholder(
        _ message: ChatMessage
    ) -> Bool {
        guard message.role == "assistant",
              message.content?.trimmedNonEmptyValue == nil,
              message.attachments?.isEmpty != false,
              let anchorID = transcriptAnchorID(for: message) else {
            return false
        }
        if isLiveRunAnchor(anchorID) {
            return true
        }
        return durablePresentationAnchorIDsByAnchorID[anchorID] != anchorID
    }

    /// Primes cache-backed rows before a navigation transition completes. The
    /// network reconcile starts afterward so the first transcript layout owns
    /// a stable content height and bottom anchor.
    func prepareInitialMessageLoad(modelContext: ModelContext?) {
        guard
            !hasLoadedAuthoritativeHistory,
            !isHistoryRequestInFlight,
            let sessionID = session.sessionId
        else {
            return
        }

        isLoading = true
        guard allMessages.isEmpty else { return }
        let cached = cachedMessages(sessionID: sessionID, in: modelContext)
        guard !cached.isEmpty else { return }
        apply(cached)
        isViewingCachedData = true
    }

    func configureRunStartAdmission(_ admission: @escaping () -> Bool) {
        runStartAdmission = admission
    }

    func revokeRunStartAdmission() {
        runStartAdmission = { false }
    }

    func durableReasoning(
        anchoredTo message: ChatMessage
    ) -> [ReasoningGroup] {
        guard let messageAnchorID = transcriptAnchorID(for: message) else {
            return []
        }
        let groups = durableReasoningGroups.filter { group in
            guard let anchorID = group.anchorMessageID else { return false }
            return !isLiveRunAnchor(anchorID)
                && durablePresentationAnchorIDsByAnchorID[anchorID]
                    == messageAnchorID
        }
        guard let text = consolidatedReasoningText(from: groups) else {
            return []
        }
        return [
            ReasoningGroup(
                id: "turn-reasoning-\(messageAnchorID)",
                anchorMessageID: messageAnchorID,
                text: text
            )
        ]
    }

    func durableToolActivity(
        anchoredTo message: ChatMessage
    ) -> [ToolCallGroup] {
        guard let messageAnchorID = transcriptAnchorID(for: message) else {
            return []
        }
        let groups = durableToolCallGroups.filter { group in
            guard let anchorID = group.anchorMessageID else { return false }
            return !isLiveRunAnchor(anchorID)
                && durablePresentationAnchorIDsByAnchorID[anchorID]
                    == messageAnchorID
        }
        guard !groups.isEmpty else { return [] }
        let toolCalls = ToolCallGroup.coalescingByAssistantTurn(
            groups,
            messages: allMessages
        ).flatMap(\.toolCalls)
        return [
            ToolCallGroup(
                id: "turn-tools-\(messageAnchorID)",
                anchorMessageID: messageAnchorID,
                toolCalls: toolCalls
            )
        ]
    }

    var liveReasoningGroups: [ReasoningGroup] {
        var groups = durableReasoningGroups.filter {
            isLiveRunAnchor($0.anchorMessageID)
        }
        guard let liveText = reasoningText.trimmedNonEmptyValue else {
            return groups
        }
        if let compatibleIndex = groups.firstIndex(where: {
            $0.text.hasPrefix(liveText) || liveText.hasPrefix($0.text)
        }) {
            if liveText.count > groups[compatibleIndex].text.count {
                groups[compatibleIndex] = ReasoningGroup(
                    id: groups[compatibleIndex].id,
                    anchorMessageID: groups[compatibleIndex].anchorMessageID,
                    text: liveText
                )
            }
            return groups
        }
        groups.append(
            ReasoningGroup(
                id: "live-reasoning-\(presentationRunID ?? "pending")",
                anchorMessageID: nil,
                text: liveText
            )
        )
        return groups
    }

    /// Presents the current turn as one continuously updating thinking block,
    /// even when Hermes persists several reasoning checkpoints.
    var liveReasoningPresentationText: String? {
        consolidatedReasoningText(from: liveReasoningGroups)
    }

    private func consolidatedReasoningText(
        from groups: [ReasoningGroup]
    ) -> String? {
        var checkpoints: [String] = []
        for group in groups {
            guard let text = group.text.trimmedNonEmptyValue else { continue }
            if let last = checkpoints.last,
               text.hasPrefix(last) || last.hasPrefix(text) {
                if text.count > last.count {
                    checkpoints[checkpoints.count - 1] = text
                }
            } else if !checkpoints.contains(text) {
                checkpoints.append(text)
            }
        }
        guard !checkpoints.isEmpty else { return nil }
        return checkpoints.joined(separator: "\n\n")
    }

    var liveToolActivityGroup: ToolCallGroup? {
        let persistedGroups = durableToolCallGroups.filter {
            isLiveRunAnchor($0.anchorMessageID)
        }
        guard !persistedGroups.isEmpty || !liveToolCalls.isEmpty else {
            return nil
        }
        let anchorMessageID = persistedGroups.first?.anchorMessageID
        let persisted = ToolCallGroup(
            id: "live-tools-\(presentationRunID ?? "pending")",
            anchorMessageID: anchorMessageID,
            toolCalls: persistedGroups.flatMap(\.toolCalls)
        )
        let merged = ToolCallGroup.merging(
            primaryGroups: persistedGroups.isEmpty ? [] : [persisted],
            fallbackGroups: [
                ToolCallGroup.live(
                    anchorMessageID: anchorMessageID,
                    toolCalls: liveToolCalls
                )
            ]
        )
        return ToolCallGroup(
            id: "live-tools-\(presentationRunID ?? "pending")",
            anchorMessageID: anchorMessageID,
            toolCalls: merged.flatMap(\.toolCalls)
        )
    }

    var hasOlderMessages: Bool {
        visibleStartIndex > 0
    }

    var isRunActive: Bool {
        activeRunID != nil || runState == .starting
    }

    var isLiveThinkingPresentationActive: Bool {
        isRunActive || isTerminalRefreshPending
    }

    var hasLiveTranscriptContent: Bool {
        !liveReasoningGroups.isEmpty
            || liveToolActivityGroup != nil
            || pendingApproval != nil
            || approvalContextUnavailable
            || streamingMessage != nil
            || showsThinkingIndicator
    }

    var showsThinkingIndicator: Bool {
        guard isRunActive,
              isWaitingForVisibleRunProgress,
              liveReasoningPresentationText == nil,
              liveToolActivityGroup == nil,
              streamingMessage == nil else {
            return false
        }
        switch runState {
        case .starting, .streaming, .transportDisconnected:
            return true
        case .idle, .waitingForApproval, .stopping, .completed, .failed,
             .cancelled:
            return false
        }
    }

    private func isLiveRunAnchor(_ anchorMessageID: String?) -> Bool {
        guard isLiveThinkingPresentationActive,
              let anchorMessageID else { return false }
        return liveRunAnchorMessageIDs.contains(anchorMessageID)
    }

    private var presentationRunID: String? {
        activeRunID ?? terminalPresentationRunID
    }

    private var durablePresentationAnchorIDsByAnchorID: [String: String] {
        let turnKeys = TranscriptTurnClassifier
            .assistantTurnKeysByAnchorID(allMessages)
        var anchorsByTurnKey: [String: [String]] = [:]
        var visibleAnchorByTurnKey: [String: String] = [:]

        for (index, message) in allMessages.enumerated()
        where message.role == "assistant" {
            let anchorID = TranscriptTurnClassifier.anchorID(
                for: message,
                at: index
            )
            let turnKey = turnKeys[anchorID] ?? "message:\(anchorID)"
            anchorsByTurnKey[turnKey, default: []].append(anchorID)
            if message.content?.trimmedNonEmptyValue != nil
                || message.attachments?.isEmpty == false {
                visibleAnchorByTurnKey[turnKey] = anchorID
            }
        }

        return anchorsByTurnKey.reduce(into: [:]) { result, entry in
            guard let fallbackAnchor = entry.value.last else { return }
            let presentationAnchor =
                visibleAnchorByTurnKey[entry.key] ?? fallbackAnchor
            for anchorID in entry.value {
                result[anchorID] = presentationAnchor
            }
        }
    }

    private func transcriptAnchorID(
        for message: ChatMessage
    ) -> String? {
        guard let index = allMessages.firstIndex(where: {
            $0.id == message.id
        }) else {
            return message.messageId
        }
        return TranscriptTurnClassifier.anchorID(
            for: message,
            at: index
        )
    }

    private var activeRunKey: CompanionActiveRunKey? {
        session.sessionId.map {
            CompanionActiveRunKey(
                companionURL: companionURL,
                sessionID: $0
            )
        }
    }

    var canSend: Bool {
        !isRunActive
            && !isLoading
            && !isUploadingAttachment
            && !isPreparingDroppedAttachments
            && !isViewingCachedData
            && !isTerminalRefreshPending
            && !needsTerminalHistoryRetry
            && !isApplyingModelSelection
            && errorMessage == nil
    }

    func prepareDroppedAttachments(
        _ sourceURLs: [URL],
        maximumCount: Int
    ) async -> Bool {
        guard
            !isPreparingDroppedAttachments,
            !isUploadingAttachment,
            maximumCount > 0,
            stagedDroppedAttachments.isEmpty
        else {
            return false
        }

        let selected = Array(sourceURLs.prefix(maximumCount))
        guard !selected.isEmpty else { return false }

        prepareAttachmentSelection()
        isPreparingDroppedAttachments = true
        defer { isPreparingDroppedAttachments = false }
        do {
            stagedDroppedAttachments = try await attachmentStager.stage(
                selected,
                maximumBytes:
                    CompanionWorkspaceService.maximumUploadBytes
            )
            return !stagedDroppedAttachments.isEmpty
        } catch {
            guard !(error is CancellationError) else { return false }
            attachmentErrorMessage = error.localizedDescription
            return false
        }
    }

    var hasStagedDroppedAttachments: Bool {
        !stagedDroppedAttachments.isEmpty
    }

    func takeStagedDroppedAttachments() -> [CompanionStagedAttachment] {
        defer { stagedDroppedAttachments = [] }
        return stagedDroppedAttachments
    }

    func discardStagedDroppedAttachments() async {
        let attachments = takeStagedDroppedAttachments()
        await attachmentStager.discard(attachments)
    }

    func uploadDroppedAttachments(
        _ attachments: [CompanionStagedAttachment],
        destination: CompanionUploadDestination
    ) async {
        for (index, attachment) in attachments.enumerated() {
            guard !Task.isCancelled else {
                await attachmentStager.discard(
                    Array(attachments[index...])
                )
                return
            }
            let uploaded = await uploadAttachment(
                fileURL: attachment.fileURL,
                filename: attachment.filename,
                contentType: attachment.contentType,
                destination: destination
            )
            guard uploaded else {
                let firstUnownedIndex =
                    failedAttachmentUpload?.fileURL
                        == attachment.fileURL
                        ? index + 1
                        : index
                if firstUnownedIndex < attachments.endIndex {
                    await attachmentStager.discard(
                        Array(attachments[firstUnownedIndex...])
                    )
                }
                return
            }
        }
    }

    func uploadAttachment(
        fileURL: URL,
        filename: String,
        contentType: String,
        destination: CompanionUploadDestination,
        rememberFailure: Bool = true
    ) async -> Bool {
        guard
            let sessionID = session.sessionId,
            pendingUploads.count < 10,
            !isUploadingAttachment
        else {
            attachmentErrorMessage = String(
                localized: "A turn can include at most 10 attachments."
            )
            return false
        }
        isUploadingAttachment = true
        attachmentUploadProgress = 0
        attachmentErrorMessage = nil
        defer {
            isUploadingAttachment = false
            attachmentUploadProgress = nil
        }
        do {
            let upload = try await workspaceService.upload(
                sessionID: sessionID,
                destination: destination,
                filename: filename,
                contentType: contentType,
                fileURL: fileURL,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.attachmentUploadProgress = progress
                    }
                }
            )
            pendingUploads.append(upload)
            try? FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else {
                try? FileManager.default.removeItem(at: fileURL)
                return false
            }
            if rememberFailure {
                if let previous = failedAttachmentUpload,
                   previous.fileURL != fileURL {
                    try? FileManager.default.removeItem(
                        at: previous.fileURL
                    )
                }
                failedAttachmentUpload = FailedAttachmentUpload(
                    fileURL: fileURL,
                    filename: filename,
                    contentType: contentType,
                    destination: destination
                )
            }
            if !rememberFailure {
                try? FileManager.default.removeItem(at: fileURL)
            }
            attachmentErrorMessage = error.localizedDescription
            return false
        }
    }

    var canRetryAttachmentUpload: Bool {
        failedAttachmentUpload != nil && !isUploadingAttachment
    }

    func retryAttachmentUpload() async {
        guard let failedAttachmentUpload else { return }
        let succeeded = await uploadAttachment(
            fileURL: failedAttachmentUpload.fileURL,
            filename: failedAttachmentUpload.filename,
            contentType: failedAttachmentUpload.contentType,
            destination: failedAttachmentUpload.destination,
            rememberFailure: true
        )
        if succeeded
            || !FileManager.default.fileExists(
                atPath: failedAttachmentUpload.fileURL.path
            ) {
            self.failedAttachmentUpload = nil
        }
    }

    func prepareAttachmentSelection() {
        if let failedAttachmentUpload {
            try? FileManager.default.removeItem(
                at: failedAttachmentUpload.fileURL
            )
        }
        failedAttachmentUpload = nil
        attachmentErrorMessage = nil
    }

    func cancelAttachmentRetry() {
        if let failedAttachmentUpload {
            try? FileManager.default.removeItem(
                at: failedAttachmentUpload.fileURL
            )
        }
        failedAttachmentUpload = nil
        attachmentErrorMessage = nil
    }

    func stageServerFile(
        sourceRootID: String,
        sourcePath: String,
        destination: CompanionUploadDestination
    ) async -> Bool {
        guard
            let sessionID = session.sessionId,
            pendingUploads.count < 10,
            !isUploadingAttachment
        else {
            attachmentErrorMessage = String(
                localized: "A turn can include at most 10 attachments."
            )
            return false
        }
        isUploadingAttachment = true
        attachmentUploadProgress = nil
        attachmentErrorMessage = nil
        defer { isUploadingAttachment = false }
        do {
            let upload = try await workspaceService.stageServerFile(
                sessionID: sessionID,
                sourceRootID: sourceRootID,
                sourcePath: sourcePath,
                destination: destination
            )
            pendingUploads.append(upload)
            return true
        } catch {
            guard !(error is CancellationError) else { return false }
            attachmentErrorMessage = error.localizedDescription
            return false
        }
    }

    func restorePendingUploads() async {
        guard let sessionID = session.sessionId else { return }
        do {
            pendingUploads = try await workspaceService.uploads(
                sessionID: sessionID
            )
        } catch {
            guard !(error is CancellationError) else { return }
            attachmentErrorMessage = error.localizedDescription
        }
    }

    func removePendingUpload(_ upload: CompanionUpload) async {
        guard let id = upload.id?.trimmedNonEmptyValue else { return }
        do {
            try await workspaceService.deleteUpload(id: id)
            pendingUploads.removeAll { $0.id == id }
        } catch {
            guard !(error is CancellationError) else { return }
            attachmentErrorMessage = error.localizedDescription
        }
    }

    func clearAttachmentError() {
        attachmentErrorMessage = nil
    }

    func setAttachmentError(_ message: String) {
        attachmentErrorMessage = message
    }

    var canRequestStop: Bool {
        activeRunID != nil && stopRecoveryState == .notRequested
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
        CompanionModelPresentation.friendlyName(
            for: selectedModelIdentifier ?? ""
        )
    }

    var selectedModelIdentifier: String? {
        selectedModelOption?.model
            ?? selectedModel?.model
            ?? session.model
    }

    var selectedModelProviderDisplayName: String? {
        selectedModel?.provider ?? session.modelProvider
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
            && stopRecoveryState == .notRequested
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
            return nil
        case .streaming:
            return nil
        case .waitingForApproval:
            return String(localized: "Hermes is waiting for your approval")
        case .transportDisconnected:
            return String(localized: "Reconnecting to live updates…")
        case .stopping:
            return nil
        case .completed:
            return nil
        case .failed(let message):
            return message ?? String(localized: "Run failed")
        case .cancelled:
            return nil
        }
    }

    var streamingMessage: ChatMessage? {
        guard !streamedAssistantText.isEmpty else { return nil }
        return ChatMessage(
            role: "assistant",
            content: streamedAssistantText,
            timestamp: nil,
            messageId: presentationRunID.map { "stream-\($0)" }
        )
    }

    @discardableResult
    func load(modelContext: ModelContext? = nil) async -> Bool {
        guard
            let sessionID = session.sessionId,
            !isHistoryRequestInFlight
        else {
            return false
        }
        isHistoryRequestInFlight = true
        isLoading = true
        errorMessage = nil
        defer {
            isHistoryRequestInFlight = false
            isLoading = false
        }

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
            let preservedTerminalPresentation: Bool
            if let activeRunID, !runState.isTerminalPresentation {
                if let mergedMessages = mergeRunningHistory(
                    history.messages
                ) {
                    applyRunningHistory(mergedMessages)
                }
                guard self.activeRunID == activeRunID else {
                    return false
                }
                preservedTerminalPresentation = false
            } else if shouldPreserveTerminalPresentation(
                for: history.messages
            ) {
                // Status/event output can precede authoritative history by a
                // few polls. Keep the already-presented answer until the
                // matching turn reaches the history endpoint.
                preservedTerminalPresentation = true
            } else {
                apply(history.messages)
                preservedTerminalPresentation = false
            }
            hasLoadedAuthoritativeHistory = true
            isViewingCachedData = false
            cache(
                history.messages,
                sessionID: history.sessionID,
                in: modelContext
            )
            cacheSession(resolvedSession, in: modelContext)
            if needsTerminalHistoryRetry,
               !preservedTerminalPresentation {
                clearTerminalFallbackPresentation()
                needsTerminalHistoryRetry = false
            }
            return !preservedTerminalPresentation
        } catch {
            guard !(error is CancellationError) else { return false }
            if allMessages.isEmpty,
               shouldUseCache(for: error),
               !cached.isEmpty {
                apply(cached)
                isViewingCachedData = true
            } else if allMessages.isEmpty {
                allMessages = []
                visibleStartIndex = 0
                isViewingCachedData = false
                errorMessage = error.localizedDescription
            } else if !isRunActive && !isTerminalRefreshPending {
                // A transient refresh failure must never erase a transcript
                // that is already visible. Keep the last coherent snapshot.
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func resumeRunObservation(
        modelContext: ModelContext? = nil
    ) async {
        guard !Task.isCancelled else { return }
        isRunObservationRequested = true
        guard runTask == nil, reconciliationTask == nil else { return }
        ensureDeltaFlushScheduled()

        if let activeRunID {
            isWaitingForVisibleRunProgress = true
            if runState != .stopping {
                runState = .streaming
            }
            beginReconciliation(
                runID: activeRunID,
                modelContext: modelContext
            )
            return
        }

        guard let activeRunKey else { return }
        let storedRun = await activeRunStore.activeRun(for: activeRunKey)
        guard !Task.isCancelled, let storedRun else { return }

        activeRunID = storedRun.runID
        isWaitingForVisibleRunProgress = true
        stopRecoveryState = storedRun.stopState
        runState = storedRun.stopState == .confirmedStopping
            ? .stopping
            : .streaming
        beginReconciliation(
            runID: storedRun.runID,
            modelContext: modelContext
        )
    }

    func suspendRunObservation() {
        isRunObservationRequested = false
        runObservationGeneration &+= 1
        if activeRunID != nil {
            flushPendingDelta()
        }
        cancelRunTasks()
    }

    func loadOlderMessages() {
        visibleStartIndex = max(0, visibleStartIndex - pageSize)
    }

    func loadModelOptions(refresh: Bool = false) async {
        guard
            supportsModelSelection,
            !isLoadingModelOptions,
            refresh || modelGroups.isEmpty
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
            if let activeRunID, let activeRunKey {
                await activeRunStore.clear(
                    runID: activeRunID,
                    for: activeRunKey
                )
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
        guard runStartAdmission?() ?? true else {
            mutationErrorMessage =
                "\(CompanionSessionPool.maximumConcurrentEventStreams) "
                + "other conversations are already running. "
                + "Wait for one to finish before sending."
            return false
        }
        mutationErrorMessage = nil

        cancelRunTasks()
        let authoritativeHistory = allMessages
        let optimisticUser = ChatMessage(
            role: "user",
            content: trimmed,
            timestamp: Date().timeIntervalSince1970,
            messageId: "local-\(UUID().uuidString)",
            attachments: pendingUploads.map(\.messageAttachment)
        )
        apply(allMessages + [optimisticUser])
        streamedAssistantText = ""
        reasoningText = ""
        liveToolCalls = []
        liveRunAnchorMessageIDs = []
        pendingApproval = nil
        approvalErrorMessage = nil
        approvalSubmissionChoice = nil
        deltaBuffer.removeAll()
        stopRecoveryState = .notRequested
        terminalOutputFallback = nil
        terminalPresentationRunID = nil
        latestRunUsage = nil
        nextToolOrdinal = 0
        let observationGeneration = runObservationGeneration
        runState = .starting
        isWaitingForVisibleRunProgress = true
        errorMessage = nil

        let started: ConversationRunSnapshot
        do {
            started = try await runService.start(
                ConversationRunStartRequest(
                    input: trimmed,
                    sessionID: sessionID,
                    conversationHistory: authoritativeHistory,
                    selection: selectedModel,
                    attachmentIDs: pendingUploads.compactMap {
                        $0.id?.trimmedNonEmptyValue
                    }
                )
            )
        } catch {
            apply(authoritativeHistory)
            runState = .failed(error.localizedDescription)
            return false
        }

        activeRunID = started.runID
        await activeRunStore.store(
            CompanionActiveRunRecord(
                runID: started.runID,
                stopState: .notRequested
            ),
            for: CompanionActiveRunKey(
                companionURL: companionURL,
                sessionID: sessionID
            )
        )
        pendingUploads = []
        guard observationGeneration == runObservationGeneration
            || isRunObservationRequested
        else {
            runState = .transportDisconnected
            return true
        }
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
        let persistedSessionModel = session.model?.trimmedNonEmptyValue
        let persistedSessionProvider =
            session.modelProvider?.trimmedNonEmptyValue
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
        if let sessionModel = session.model?.trimmedNonEmptyValue {
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
            stopRecoveryState == .notRequested
        else {
            return
        }
        isStopRequestInFlight = true
        stopRecoveryState = .deliveryUnknown
        runState = .transportDisconnected
        defer { isStopRequestInFlight = false }

        if let activeRunKey {
            await activeRunStore.updateStopState(
                .deliveryUnknown,
                runID: runID,
                for: activeRunKey
            )
            if Task.isCancelled {
                stopRecoveryState = .notRequested
                runState = .streaming
                await activeRunStore.updateStopState(
                    .notRequested,
                    runID: runID,
                    for: activeRunKey
                )
                return
            }
        }

        do {
            let snapshot = try await runService.stop(runID: runID)
            guard canReceiveSnapshotResponse(for: runID) else { return }
            if absorbSnapshotAfterTerminal(snapshot) { return }
            terminalOutputFallback = snapshot.output
            applyRunSnapshot(snapshot)
            await persistStopStateIfNeeded(snapshot, runID: runID)
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
                        markStreamingTranscriptChanged()
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
                        if let usage = payload.usage {
                            latestRunUsage = usage
                        }
                        runState = terminal
                        terminalOutputFallback = payload.output
                        if payload.usage == nil {
                            beginTerminalUsageRefresh(runID: runID)
                        }
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
        ensureDeltaFlushScheduled()
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

    private func beginTerminalUsageRefresh(runID: String) {
        terminalUsageRefreshTask?.cancel()
        terminalUsageRefreshRunID = runID
        terminalUsageRefreshTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = try? await runService.status(runID: runID)
            guard !Task.isCancelled,
                  terminalUsageRefreshRunID == runID else {
                return
            }
            if let usage = snapshot?.usage {
                latestRunUsage = usage
            }
            terminalUsageRefreshRunID = nil
            terminalUsageRefreshTask = nil
        }
    }

    private func enqueue(_ delta: String) {
        deltaBuffer.append(delta)
        ensureDeltaFlushScheduled()
    }

    private func ensureDeltaFlushScheduled() {
        guard !deltaBuffer.isEmpty, deltaFlushTask == nil else { return }
        scheduleDeltaFlush()
    }

    private func scheduleDeltaFlush() {
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingDelta()
        }
    }

    private func flushPendingDelta() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        let drained = deltaBuffer.drain(
            maximumCharacters: 3
        )
        guard !drained.isEmpty else { return }
        streamedAssistantText += drained
        markStreamingTranscriptChanged()
        ensureDeltaFlushScheduled()
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
                    guard canReceiveSnapshotResponse(for: runID) else {
                        return
                    }
                    if absorbSnapshotAfterTerminal(snapshot) { return }
                    terminalOutputFallback = snapshot.output
                        ?? terminalOutputFallback
                    applyRunSnapshot(snapshot)
                    await persistStopStateIfNeeded(
                        snapshot,
                        runID: runID
                    )
                    if snapshot.state.isTerminal {
                        reconciliationTask = nil
                        await finishRun(
                            runID: runID,
                            modelContext: modelContext
                        )
                        return
                    }
                    await refreshHistoryDuringRun(
                        runID: runID,
                        modelContext: modelContext
                    )
                } catch is CancellationError {
                    return
                } catch let error as ConversationRunServiceError
                    where error == .runNotFound {
                    if let activeRunKey {
                        await activeRunStore.clear(
                            runID: runID,
                            for: activeRunKey
                        )
                    }
                    guard activeRunID == runID else { return }
                    activeRunID = nil
                    runState = .idle
                    clearRecoveredRunPresentation()
                    _ = await load(modelContext: modelContext)
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

    private func refreshHistoryDuringRun(
        runID: String,
        modelContext: ModelContext?
    ) async {
        guard
            let sessionID = session.sessionId,
            !isHistoryRequestInFlight
        else {
            return
        }

        do {
            let history = try await repository.messageHistory(id: sessionID)
            guard activeRunID == runID else { return }
            guard let mergedMessages = mergeRunningHistory(
                history.messages
            ) else {
                return
            }

            applyRunningHistory(mergedMessages)
            cache(
                mergedMessages,
                sessionID: history.sessionID,
                in: modelContext
            )
            markStreamingTranscriptChanged()
        } catch is CancellationError {
            return
        } catch {
            // Status remains authoritative. A later reconciliation pass can
            // retry transcript history without changing the run lifecycle.
        }
    }

    private func mergeRunningHistory(
        _ candidate: [ChatMessage]
    ) -> [ChatMessage]? {
        guard candidate.count >= allMessages.count else { return nil }
        var merged = candidate

        for (index, current) in allMessages.enumerated() {
            if current.messageId?.hasPrefix("local-") == true {
                let persisted = candidate.contains {
                    $0.role == current.role && $0.content == current.content
                }
                guard persisted else { return nil }
                continue
            }

            guard let message = mergeRunningMessage(
                current,
                candidate[index]
            ) else {
                return nil
            }
            merged[index] = message
        }

        return merged == allMessages ? nil : merged
    }

    private func mergeRunningMessage(
        _ current: ChatMessage,
        _ candidate: ChatMessage
    ) -> ChatMessage? {
        guard identitiesMatch(current.role, candidate.role) else { return nil }
        guard identitiesMatch(current.messageId, candidate.messageId) else {
            return nil
        }
        guard identitiesMatch(current.toolCallId, candidate.toolCallId) else {
            return nil
        }
        guard identitiesMatch(current.toolUseId, candidate.toolUseId) else {
            return nil
        }
        guard identitiesMatch(current.name, candidate.name) else { return nil }
        guard identitiesMatch(current.timestamp, candidate.timestamp) else {
            return nil
        }
        guard growingTextsAreCompatible(
            current.content,
            candidate.content
        ) else {
            return nil
        }
        guard growingTextsAreCompatible(
            current.reasoning,
            candidate.reasoning
        ) else {
            return nil
        }
        guard jsonCollectionsAreCompatible(
            current.toolCalls,
            candidate.toolCalls
        ) else {
            return nil
        }
        guard jsonCollectionsAreCompatible(
            current.contentParts,
            candidate.contentParts
        ) else {
            return nil
        }
        guard collectionsAreCompatible(
            current.attachments,
            candidate.attachments
        ) else {
            return nil
        }

        return ChatMessage(
            role: candidate.role ?? current.role,
            content: preferredGrowingText(current.content, candidate.content),
            timestamp: candidate.timestamp ?? current.timestamp,
            messageId: candidate.messageId ?? current.messageId,
            name: candidate.name ?? current.name,
            toolCallId: candidate.toolCallId ?? current.toolCallId,
            toolUseId: candidate.toolUseId ?? current.toolUseId,
            toolCalls: preferredJSONCollection(
                current.toolCalls,
                candidate.toolCalls
            ),
            contentParts: preferredJSONCollection(
                current.contentParts,
                candidate.contentParts
            ),
            reasoning: preferredGrowingText(
                current.reasoning,
                candidate.reasoning
            ),
            attachments: preferredCollection(
                current.attachments,
                candidate.attachments
            )
        )
    }

    private func identitiesMatch<T: Equatable>(
        _ current: T?,
        _ candidate: T?
    ) -> Bool {
        current == nil || candidate == nil || current == candidate
    }

    private func growingTextsAreCompatible(
        _ current: String?,
        _ candidate: String?
    ) -> Bool {
        guard let current, let candidate else { return true }
        return candidate.hasPrefix(current) || current.hasPrefix(candidate)
    }

    private func preferredGrowingText(
        _ current: String?,
        _ candidate: String?
    ) -> String? {
        guard let current else { return candidate }
        guard let candidate else { return current }
        if candidate.hasPrefix(current) { return candidate }
        return current
    }

    private func jsonCollectionsAreCompatible(
        _ current: [JSONValue]?,
        _ candidate: [JSONValue]?
    ) -> Bool {
        guard let current, let candidate else { return true }
        return jsonArray(candidate, contains: current)
            || jsonArray(current, contains: candidate)
    }

    private func preferredJSONCollection(
        _ current: [JSONValue]?,
        _ candidate: [JSONValue]?
    ) -> [JSONValue]? {
        guard let current else { return candidate }
        guard let candidate else { return current }
        return jsonArray(candidate, contains: current) ? candidate : current
    }

    private func jsonArray(
        _ superset: [JSONValue],
        contains subset: [JSONValue]
    ) -> Bool {
        guard superset.count >= subset.count else { return false }
        return zip(subset, superset).allSatisfy { pair in
            jsonValue(pair.1, contains: pair.0)
        }
    }

    private func jsonValue(
        _ superset: JSONValue,
        contains subset: JSONValue
    ) -> Bool {
        if superset == subset { return true }
        switch (superset, subset) {
        case (.object(let candidate), .object(let current)):
            return current.allSatisfy { pair in
                guard let candidateValue = candidate[pair.0] else {
                    return false
                }
                return jsonValue(candidateValue, contains: pair.1)
            }
        case (.array(let candidate), .array(let current)):
            return jsonArray(candidate, contains: current)
        default:
            return false
        }
    }

    private func collectionsAreCompatible<Element: Equatable>(
        _ current: [Element]?,
        _ candidate: [Element]?
    ) -> Bool {
        guard let current, let candidate else { return true }
        return collection(candidate, hasPrefix: current)
            || collection(current, hasPrefix: candidate)
    }

    private func collection<Element: Equatable>(
        _ collection: [Element],
        hasPrefix prefix: [Element]
    ) -> Bool {
        guard collection.count >= prefix.count else { return false }
        return zip(prefix, collection).allSatisfy { pair in
            pair.0 == pair.1
        }
    }

    private func preferredCollection<Element: Equatable>(
        _ current: [Element]?,
        _ candidate: [Element]?
    ) -> [Element]? {
        guard let current else { return candidate }
        guard let candidate else { return current }
        return collection(candidate, hasPrefix: current) ? candidate : current
    }

    private func stageRunningAssistantOutput(
        previousMessages: [ChatMessage],
        authoritativeMessages: [ChatMessage]
    ) -> [ChatMessage] {
        let currentTurnAnchorIDs = Set(
            TranscriptTurnClassifier.currentTurnAssistantAnchorIDs(
                in: authoritativeMessages
            )
        )
        return authoritativeMessages.enumerated().map { index, message in
            let anchorID = TranscriptTurnClassifier.anchorID(
                for: message,
                at: index
            )
            guard
                message.role == "assistant",
                currentTurnAnchorIDs.contains(anchorID)
            else {
                return message
            }

            if let content = message.content,
               content.trimmedNonEmptyValue != nil {
                enqueueAuthoritativeAssistantOutput(content)
            }

            let previousContent: String?
            if previousMessages.indices.contains(index),
               previousMessages[index].role == "assistant",
               identitiesMatch(
                   previousMessages[index].messageId,
                   message.messageId
               ) {
                previousContent = previousMessages[index].content
            } else {
                previousContent = nil
            }

            return ChatMessage(
                role: message.role,
                content: previousContent,
                timestamp: message.timestamp,
                messageId: message.messageId,
                name: message.name,
                toolCallId: message.toolCallId,
                toolUseId: message.toolUseId,
                toolCalls: message.toolCalls,
                contentParts: message.contentParts,
                reasoning: message.reasoning,
                attachments: message.attachments
            )
        }
    }

    private func applyRunningHistory(_ messages: [ChatMessage]) {
        let previousMessages = allMessages
        liveRunAnchorMessageIDs = Set(
            TranscriptTurnClassifier.currentTurnAssistantAnchorIDs(
                in: messages
            )
        )
        apply(
            stageRunningAssistantOutput(
                previousMessages: previousMessages,
                authoritativeMessages: messages
            ),
            preservesVisibleWindow: true
        )
    }

    private func enqueueAuthoritativeAssistantOutput(_ output: String) {
        let presentedAndQueued =
            streamedAssistantText + deltaBuffer.pendingText
        if output.hasPrefix(presentedAndQueued) {
            let suffix = output.dropFirst(presentedAndQueued.count)
            enqueue(String(suffix))
            return
        }
        // A shorter snapshot is stale relative to the presentation already
        // received from SSE. Preserve the newer prefix until the next poll.
        if presentedAndQueued.hasPrefix(output) {
            return
        }
        // Conflicting recovery text must not blank or replace content already
        // visible on screen. Only seed an empty presentation; terminal history
        // remains authoritative for a non-prefix conflict.
        guard presentedAndQueued.isEmpty else { return }
        enqueue(output)
    }

    private func reconcileApproval(
        runID: String,
        modelContext: ModelContext?
    ) async {
        do {
            let snapshot = try await runService.status(runID: runID)
            guard canReceiveSnapshotResponse(for: runID) else { return }
            if absorbSnapshotAfterTerminal(snapshot) { return }
            terminalOutputFallback = snapshot.output
                ?? terminalOutputFallback
            applyRunSnapshot(snapshot)
            await persistStopStateIfNeeded(snapshot, runID: runID)
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

    private func persistStopStateIfNeeded(
        _ snapshot: ConversationRunSnapshot,
        runID: String
    ) async {
        guard snapshot.state == .stopping else { return }
        stopRecoveryState = .confirmedStopping
        runState = .stopping
        guard let activeRunKey else { return }
        await activeRunStore.updateStopState(
            .confirmedStopping,
            runID: runID,
            for: activeRunKey
        )
    }

    private func applyRunSnapshot(_ snapshot: ConversationRunSnapshot) {
        if let usage = snapshot.usage {
            latestRunUsage = usage
        }
        // A delayed status or stop response must never regress an event-stream
        // terminal state while the final presentation/history reconciliation
        // is still finishing.
        guard !runState.isTerminalPresentation else { return }
        switch snapshot.state {
        case .started, .queued, .running:
            if runState != .stopping {
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

    private func canReceiveSnapshotResponse(for runID: String) -> Bool {
        activeRunID == runID
            || (
                activeRunID == nil
                    && runState.isTerminalPresentation
                    && terminalPresentationRunID == runID
                    && (isTerminalRefreshPending
                        || needsTerminalHistoryRetry)
            )
    }

    private func absorbSnapshotAfterTerminal(
        _ snapshot: ConversationRunSnapshot
    ) -> Bool {
        guard runState.isTerminalPresentation else { return false }
        guard snapshot.state.isTerminal else { return true }

        if latestRunUsage == nil, let usage = snapshot.usage {
            latestRunUsage = usage
        }
        if terminalOutputFallback?.trimmedNonEmptyValue == nil,
           let output = snapshot.output,
           output.trimmedNonEmptyValue != nil {
            terminalOutputFallback = output
            enqueueTerminalAssistantOutput(output)
        }
        return true
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
        terminalPresentationRunID = runID
        if let activeRunKey {
            await activeRunStore.clear(
                runID: runID,
                for: activeRunKey
            )
            guard activeRunID == runID else { return }
        }
        if let terminalOutputFallback,
           !terminalOutputFallback.isEmpty {
            enqueueTerminalAssistantOutput(terminalOutputFallback)
        }
        guard await drainPendingPresentation(runID: runID) else {
            return
        }
        let expectedTerminalOutput =
            terminalOutputFallback?.trimmedNonEmptyValue
            ?? streamedAssistantText.trimmedNonEmptyValue
        let messagesBeforeRefresh = allMessages
        isTerminalRefreshPending = true
        // Transport ownership ends once every pending presentation frame is
        // visible. Clearing the run identity here also makes late status/stop
        // responses harmless while authoritative history catches up.
        activeRunID = nil
        pendingApproval = nil
        approvalErrorMessage = nil
        approvalSubmissionChoice = nil
        runTask?.cancel()
        runTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        let loadedAuthoritativeHistory = await refreshHistoryAfterTerminal(
            modelContext: modelContext,
            expectsAssistantOutput:
                runState == .completed || expectedTerminalOutput != nil
        )
        if loadedAuthoritativeHistory {
            clearTerminalFallbackPresentation()
            needsTerminalHistoryRetry = false
        } else {
            apply(messagesBeforeRefresh)
            needsTerminalHistoryRetry = true
        }
        thinkingIndicatorTask?.cancel()
        thinkingIndicatorTask = nil
        isWaitingForVisibleRunProgress = false
        activeRunID = nil
        liveRunAnchorMessageIDs = []
        stopRecoveryState = .notRequested
        terminalOutputFallback = nil
        isTerminalRefreshPending = false
    }

    private func enqueueTerminalAssistantOutput(_ output: String) {
        let presentedAndQueued =
            streamedAssistantText + deltaBuffer.pendingText
        if output.hasPrefix(presentedAndQueued) {
            enqueue(String(output.dropFirst(presentedAndQueued.count)))
            return
        }
        if presentedAndQueued.hasPrefix(output) {
            return
        }

        // A terminal snapshot is the best available fallback when history is
        // unavailable. Replace a conflicting partial with one bounded frame,
        // then keep draining the remainder instead of jumping to a full block.
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        deltaBuffer.removeAll()
        streamedAssistantText = ""
        deltaBuffer.append(output)
        flushPendingDelta()
    }

    private func drainPendingPresentation(runID: String) async -> Bool {
        ensureDeltaFlushScheduled()
        while !deltaBuffer.isEmpty {
            guard
                activeRunID == runID,
                !Task.isCancelled
            else {
                return false
            }
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
            ensureDeltaFlushScheduled()
        }
        return true
    }

    private func refreshHistoryAfterTerminal(
        modelContext: ModelContext?,
        expectsAssistantOutput: Bool
    ) async -> Bool {
        while isLoading {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
        }
        for attempt in 0..<3 {
            let loaded = await load(modelContext: modelContext)
            if loaded,
               (!expectsAssistantOutput
                || hasVisibleAssistantOutputInCurrentTurn(allMessages)) {
                return true
            }
            guard attempt < 2 else { break }
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    private func shouldPreserveTerminalPresentation(
        for messages: [ChatMessage]
    ) -> Bool {
        guard runState.isTerminalPresentation else { return false }
        if messages.isEmpty, !allMessages.isEmpty {
            return true
        }
        return (terminalOutputFallback?.trimmedNonEmptyValue
            ?? streamedAssistantText.trimmedNonEmptyValue) != nil
            && !hasVisibleAssistantOutputInCurrentTurn(messages)
    }

    private func hasVisibleAssistantOutputInCurrentTurn(
        _ messages: [ChatMessage]
    ) -> Bool {
        let latestUserIndex = messages.lastIndex {
            TranscriptTurnClassifier.isUserTurnBoundary($0)
        }
        let startIndex = latestUserIndex.map {
            messages.index(after: $0)
        } ?? messages.startIndex
        guard startIndex < messages.endIndex else { return false }
        return messages[startIndex...].contains { message in
            message.role == "assistant"
                && message.content?.trimmedNonEmptyValue != nil
        }
    }

    private func clearTerminalFallbackPresentation() {
        thinkingIndicatorTask?.cancel()
        thinkingIndicatorTask = nil
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        deltaBuffer.removeAll()
        terminalPresentationRunID = nil
        streamedAssistantText = ""
        reasoningText = ""
        liveToolCalls = []
        liveRunAnchorMessageIDs = []
        isWaitingForVisibleRunProgress = false
    }

    private func clearRecoveredRunPresentation() {
        clearTerminalFallbackPresentation()
        deltaBuffer.removeAll()
        pendingApproval = nil
        approvalErrorMessage = nil
        approvalSubmissionChoice = nil
        terminalOutputFallback = nil
        stopRecoveryState = .notRequested
        markStreamingTranscriptChanged()
    }

    private func cancelRunTasks() {
        runTask?.cancel()
        runTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        terminalUsageRefreshTask?.cancel()
        terminalUsageRefreshTask = nil
        terminalUsageRefreshRunID = nil
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        thinkingIndicatorTask?.cancel()
        thinkingIndicatorTask = nil
    }

    private func applyToolStarted(
        _ payload: ConversationRunEventData,
        runID: String
    ) {
        let id = payload.toolCallID?.trimmedNonEmptyValue
            ?? "\(runID)-tool-\(nextToolOrdinal)"
        nextToolOrdinal += 1
        if let index = liveToolCalls.firstIndex(where: { $0.id == id }) {
            liveToolCalls[index].name = payload.tool
                ?? liveToolCalls[index].name
            liveToolCalls[index].preview = payload.preview
                ?? liveToolCalls[index].preview
            markStreamingTranscriptChanged()
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
        markStreamingTranscriptChanged()
    }

    private func applyToolCompleted(
        _ payload: ConversationRunEventData,
        runID: String
    ) {
        let index: Int?
        if let id = payload.toolCallID?.trimmedNonEmptyValue {
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
            markStreamingTranscriptChanged()
            return
        }

        let id = payload.toolCallID?.trimmedNonEmptyValue
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
        markStreamingTranscriptChanged()
    }

    private func markStreamingTranscriptChanged() {
        streamingFollowTrigger &+= 1
        thinkingIndicatorTask?.cancel()
        thinkingIndicatorTask = nil
        guard isRunActive, !runState.isTerminalPresentation else {
            isWaitingForVisibleRunProgress = false
            return
        }
        isWaitingForVisibleRunProgress = false
        thinkingIndicatorTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  isRunActive,
                  !runState.isTerminalPresentation else {
                return
            }
            isWaitingForVisibleRunProgress = true
            streamingFollowTrigger &+= 1
            thinkingIndicatorTask = nil
        }
    }

    private func apply(
        _ messages: [ChatMessage],
        preservesVisibleWindow: Bool = false
    ) {
        allMessages = messages
        if preservesVisibleWindow {
            visibleStartIndex = min(visibleStartIndex, messages.count)
        } else {
            visibleStartIndex = max(0, messages.count - pageSize)
        }
        durableReasoningGroups = CompanionReasoningPresentation.groups(
            messages: messages
        )
        durableToolCallGroups = ToolCallGroup.groups(
            persistedToolCalls: [],
            messages: messages,
            messageOffset: nil
        )
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
    var trimmedNonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
