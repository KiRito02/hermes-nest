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
                SessionListQuery(limit: pageSize, offset: 0)
            )
            sessions = Self.visibleUniqueSessions(page.sessions)
            nextOffset = resolvedNextOffset(for: page, fallback: sessions.count)
            hasMore = page.hasMore == true
            isViewingCachedData = false
            cache(page.sessions, completesList: !hasMore, in: modelContext)
        } catch {
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
                SessionListQuery(limit: pageSize, offset: nextOffset)
            )
            sessions = Self.visibleUniqueSessions(sessions + page.sessions)
            nextOffset = resolvedNextOffset(for: page, fallback: nextOffset + pageSize)
            hasMore = page.hasMore == true
            isViewingCachedData = false
            errorMessage = nil
            cache(page.sessions, completesList: !hasMore, in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
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

    private func resolvedNextOffset(for page: SessionPage, fallback: Int) -> Int {
        guard let offset = page.offset, let limit = page.limit else {
            return fallback
        }
        return offset + limit
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
