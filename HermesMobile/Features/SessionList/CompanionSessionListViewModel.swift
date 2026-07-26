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

@MainActor
@Observable
final class CompanionSessionHistoryViewModel {
    private(set) var session: SessionSummary
    private(set) var allMessages: [ChatMessage] = []
    private(set) var isLoading = false
    private(set) var isViewingCachedData = false
    private(set) var errorMessage: String?
    private(set) var mutationErrorMessage: String?

    private let repository: any SessionRepository
    private let companionURL: URL
    private let pageSize: Int
    private var visibleStartIndex = 0

    init(
        session: SessionSummary,
        repository: any SessionRepository,
        companionURL: URL,
        pageSize: Int = 50
    ) {
        self.session = session
        self.repository = repository
        self.companionURL = companionURL
        self.pageSize = max(1, pageSize)
    }

    var visibleMessages: [ChatMessage] {
        guard visibleStartIndex < allMessages.count else { return [] }
        return Array(allMessages[visibleStartIndex...])
    }

    var hasOlderMessages: Bool {
        visibleStartIndex > 0
    }

    func load(modelContext: ModelContext? = nil) async {
        guard let sessionID = session.sessionId, !isLoading else { return }
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
        } catch {
            guard !(error is CancellationError) else { return }
            if shouldUseCache(for: error), !cached.isEmpty {
                apply(cached)
                isViewingCachedData = true
            } else {
                allMessages = []
                visibleStartIndex = 0
                isViewingCachedData = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadOlderMessages() {
        visibleStartIndex = max(0, visibleStartIndex - pageSize)
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
