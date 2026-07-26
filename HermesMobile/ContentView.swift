import SwiftUI

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
    CompanionRootView(
        connectionManager: CompanionConnectionManager()
    )
}
