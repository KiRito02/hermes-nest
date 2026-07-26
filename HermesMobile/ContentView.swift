import SwiftUI

struct ContentView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @State private var pendingSharedImport: SharedImport?
    @State private var pendingDeepLinkedSessionID: String?
    @State private var pendingNewChatRequest: NewChatRequest?
    @State private var didCheckInitialPendingShare = false
    @State private var intentRouter = AppIntentRouter.shared

    var body: some View {
        content
            .onOpenURL(perform: handleOpenURL)
            .task {
                guard !didCheckInitialPendingShare else { return }
                didCheckInitialPendingShare = true
                importPendingSharedDraftIfAvailable()
                // Cold launch: an App Intent may have queued a deep link before this
                // view appeared (e.g. Action button "New Chat"). Drain it now (#337).
                drainPendingIntentDeepLink()
            }
            .onChange(of: intentRouter.pendingDeepLink) {
                // Warm launch: the intent set the deep link after the view appeared.
                drainPendingIntentDeepLink()
            }
            .task {
                // #246: on cold launch, end any Live Activity left "running" by a
                // run that finished while the app was terminated. #248: this is also
                // the one pass allowed to fire a recent run's "response complete"
                // notification, since a relaunch means it finished while not active.
                await reconcileOrphanedLiveActivities(notifiesOnCompletion: true)
            }
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                importPendingSharedDraftIfAvailable()
                // #248: the foreground pass stays silent — the in-session completion
                // paths own notifications while the app is alive.
                Task { await reconcileOrphanedLiveActivities(notifiesOnCompletion: false) }
            }
    }

    private func reconcileOrphanedLiveActivities(notifiesOnCompletion: Bool) async {
        guard case let .loggedIn(server) = authManager.state else { return }
        await LiveActivityReconciler.reconcileOrphanedActivities(
            server: server,
            notifiesOnCompletion: notifiesOnCompletion,
            preferenceEnabled: isResponseCompletionNotificationsEnabled
        )
    }

    @ViewBuilder
    private var content: some View {
        switch authManager.state {
        case .unconfigured:
            Text("Legacy WebUI connection mode is disabled.")
        case .loggedOut:
            Text("Legacy WebUI connection mode is disabled.")
        case .loggedIn(let server):
            SessionListView(
                authManager: authManager,
                server: server,
                pendingSharedImport: $pendingSharedImport,
                pendingDeepLinkedSessionID: $pendingDeepLinkedSessionID,
                requestedNewChat: $pendingNewChatRequest
            )
            // Switching the active server keeps us in `.loggedIn`, so without a
            // per-server identity SwiftUI would reuse the same SessionListView (and
            // its server-bound view model), leaving stale sessions/chat on screen.
            // Keying on the server tears the whole stack down and rebuilds it
            // against the newly active server (#17).
            .id(server)
        }
    }

    private func handleOpenURL(_ url: URL) {
        // A fresh request each time (new `id`) so a repeat invocation re-triggers navigation
        // even if the previous one's value still lingers downstream. The voice variant carries
        // `autoStartsVoiceInput` so the composer begins dictation once it appears (#338).
        if HermesDeepLink.isNewChatVoiceURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: true)
            return
        }

        // The profile variant carries the chosen profile name, so the composer creates the
        // session pinned to it (#339). A malformed link with no profile falls back to a
        // plain new chat (server's active profile) rather than failing.
        if HermesDeepLink.isNewChatInProfileURL(url) {
            pendingNewChatRequest = NewChatRequest(
                profileName: HermesDeepLink.profileName(fromNewChatInProfile: url)
            )
            return
        }

        if HermesDeepLink.isNewChatURL(url) {
            pendingNewChatRequest = NewChatRequest(autoStartsVoiceInput: false)
            return
        }

        if let sessionID = HermesDeepLink.sessionID(from: url) {
            pendingDeepLinkedSessionID = sessionID
            return
        }

        guard HermesShareDraft.isShareOpenURL(url) else {
            return
        }

        importPendingSharedDraftIfAvailable()
    }

    /// Routes a deep link queued by an App Intent through the same `handleOpenURL` parser
    /// used for external URLs, then clears it so it routes exactly once (#337).
    private func drainPendingIntentDeepLink() {
        guard let url = intentRouter.pendingDeepLink else { return }
        intentRouter.pendingDeepLink = nil
        handleOpenURL(url)
    }

    private func importPendingSharedDraftIfAvailable() {
        guard let directory = HermesShareDraft.containerURL() else {
            return
        }

        do {
            if let sharedImport = try HermesShareDraft.loadPendingImport(from: directory) {
                pendingSharedImport = sharedImport
            }
        } catch {
            pendingSharedImport = nil
        }
    }
}

/// Companion-only root. Each production destination is enabled only after its
/// versioned Companion/Gateway contract has been verified.
struct CompanionRootView: View {
    @Bindable var connectionManager: CompanionConnectionManager

    var body: some View {
        Group {
            switch connectionManager.state {
            case .restoring:
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView("Restoring Companion connection...")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            case .unconfigured(let savedURL):
                OnboardingView(
                    connectionManager: connectionManager,
                    savedCompanionURL: savedURL
                )
            case .pairingRequired(let savedURL, let message):
                OnboardingView(
                    connectionManager: connectionManager,
                    savedCompanionURL: savedURL,
                    initialErrorMessage: message
                )
            case .disconnected(let savedURL, let message):
                CompanionFoundationStatusView(
                    connectionManager: connectionManager,
                    companionURL: savedURL,
                    title: String(localized: "Companion unavailable"),
                    message: message,
                    gatewayStatus: nil
                )
            case .connected(let connection):
                if connection.capabilities.gateway?.status == "ok" {
                    CompanionSessionListView(
                        connectionManager: connectionManager,
                        connection: connection
                    )
                } else {
                    CompanionFoundationStatusView(
                        connectionManager: connectionManager,
                        companionURL: connection.companionURL,
                        title: String(localized: "Companion connected"),
                        message: gatewayMessage(for: connection.capabilities.gateway?.status),
                        gatewayStatus: connection.capabilities.gateway?.status
                    )
                }
            }
        }
        .task {
            await connectionManager.restoreIfNeeded()
        }
    }

    private func gatewayMessage(for status: String?) -> String {
        switch status {
        case "ok":
            return String(localized: "Gateway discovery succeeded.")
        case "unavailable":
            return String(localized: "Companion is reachable, but Hermes Gateway is unavailable.")
        case "unauthorized":
            return String(localized: "Companion is reachable, but its NAS-local Gateway credential was rejected.")
        case "incompatible":
            return String(localized: "Companion is reachable, but this Hermes Gateway version is incompatible.")
        case "degraded":
            return String(localized: "Companion is reachable, but Hermes Gateway reports a degraded state.")
        default:
            return String(localized: "Companion is reachable. Gateway status is not available.")
        }
    }
}

private struct CompanionFoundationStatusView: View {
    @Bindable var connectionManager: CompanionConnectionManager
    let companionURL: URL?
    let title: String
    let message: String
    let gatewayStatus: String?
    @State private var isConfirmingForget = false

    var body: some View {
        NavigationStack {
            ZStack {
                HermesNestDesign.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Image("HermesMobileBanner")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240)
                            .accessibilityHidden(true)

                        Label(
                            title,
                            systemImage: gatewayStatus == "ok"
                                ? "checkmark.shield.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.title2.bold())

                        Text(message)
                            .foregroundStyle(.secondary)

                        if let companionURL {
                            LabeledContent("Companion") {
                                Text(companionURL.absoluteString)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                        }

                        if let gatewayStatus {
                            LabeledContent("Gateway status") {
                                Text(gatewayStatus)
                            }
                        }

                        Button {
                            Task { await connectionManager.resume() }
                        } label: {
                            Label("Retry discovery", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connectionManager.isWorking)

                        Button(role: .destructive) {
                            isConfirmingForget = true
                        } label: {
                            Text("Forget this Companion")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(connectionManager.isWorking)
                    }
                    .padding(24)
                    .frame(
                        maxWidth: HermesNestDesign.transcriptMaximumWidth,
                        alignment: .leading
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .alert("Forget this Companion?", isPresented: $isConfirmingForget) {
                Button("Cancel", role: .cancel) {}
                Button("Forget and revoke device", role: .destructive) {
                    Task { await connectionManager.forgetConnection() }
                }
            } message: {
                Text("Hermes Nest will ask Companion to revoke this device, then remove its local Keychain credential. Cached conversations are kept.")
            }
        }
    }
}

#Preview {
    ContentView(authManager: AuthManager())
}
