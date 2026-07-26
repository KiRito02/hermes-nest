import SwiftData
import SwiftUI

@MainActor
struct CompanionSessionListView: View {
    @Bindable var connectionManager: CompanionConnectionManager
    let connection: CompanionConnection

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CompanionSessionListViewModel
    @State private var searchText = ""
    @State private var isConfirmingForget = false

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
        _viewModel = State(
            initialValue: CompanionSessionListViewModel(
                repository: resolvedRepository,
                companionURL: connection.companionURL
            )
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isViewingCachedData {
                    OfflineCacheBanner()
                        .listRowSeparator(.hidden)
                }

                ForEach(visibleSessions) { session in
                    SessionRowView(
                        session: session,
                        showsMessageCount: true,
                        showsWorkspace: false,
                        isViewingCachedData: viewModel.isViewingCachedData
                    )
                    .listRowInsets(
                        EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
                    )
                    .onAppear {
                        guard session.id == visibleSessions.last?.id else { return }
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image("HermesMobileBanner")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 112, height: 28, alignment: .leading)
                        .accessibilityLabel("Hermex")
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
    }

    private var visibleSessions: [SessionSummary] {
        viewModel.matchingSessions(searchText: searchText)
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
