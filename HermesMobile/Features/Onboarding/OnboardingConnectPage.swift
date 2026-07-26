import SwiftUI

enum OnboardingConnectField: Hashable {
    case companionURL
    case pairingSecret
}

struct OnboardingConnectPage: View {
    @Bindable var viewModel: OnboardingViewModel
    @Bindable var connectionManager: CompanionConnectionManager
    @FocusState.Binding var focusedField: OnboardingConnectField?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var canSubmit: Bool {
        !viewModel.companionURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitConnection() {
        guard canSubmit else { return }
        Task { await viewModel.connect(connectionManager: connectionManager) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)

                    Text("Enter the HTTPS URL that Lucky or Tailscale proxies to Hermes Nest Companion, then enter a one-time pairing secret created on your Hermes Agent host.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    OnboardingField(systemImage: "link", title: String(localized: "Companion URL")) {
                        ZStack(alignment: .leading) {
                            if viewModel.companionURLString.isEmpty {
                                Text(verbatim: "https://hermes-nest.example.com")
                                    .foregroundStyle(.white.opacity(0.38))
                                    .allowsHitTesting(false)
                            }

                            TextField("", text: $viewModel.companionURLString)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .foregroundStyle(.white)
                                .submitLabel(.go)
                                .tint(Color(red: 1.0, green: 0.74, blue: 0.10))
                                .focused($focusedField, equals: .companionURL)
                                .onSubmit {
                                    focusedField = .pairingSecret
                                }
                        }
                    }

                    OnboardingField(systemImage: "key.fill", title: String(localized: "Pairing Secret")) {
                        SecureField(
                            "",
                            text: $viewModel.pairingSecret,
                            prompt: Text("One-time secret")
                                .foregroundStyle(.white.opacity(0.38))
                        )
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focusedField, equals: .pairingSecret)
                        .onSubmit(submitConnection)
                    }
                }

                if viewModel.isWorking {
                    OnboardingStatusBanner(
                        text: String(localized: "Contacting Companion..."),
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: .white.opacity(0.7),
                        showsProgress: true
                    )
                }

                if let connectionMessage = viewModel.connectionMessage {
                    OnboardingStatusBanner(
                        text: connectionMessage,
                        systemImage: "checkmark.circle.fill",
                        tint: Color(red: 0.45, green: 0.92, blue: 0.56)
                    )
                }

                if let errorMessage = viewModel.errorMessage {
                    OnboardingStatusBanner(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Color(red: 1.0, green: 0.47, blue: 0.34)
                    )
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 18 : 24)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
