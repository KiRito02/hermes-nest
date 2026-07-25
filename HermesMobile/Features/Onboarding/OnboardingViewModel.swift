import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    nonisolated static let emptyPairingSecretMessage =
        String(localized: "Enter the one-time pairing secret created on your NAS.")
    // Kept only for inherited AuthManager tests while the old WebUI stack
    // remains compiled but unreachable from the Companion-only App root.
    nonisolated static let emptyPasswordMessage =
        String(localized: "Enter the server password.")

    var companionURLString = ""
    var pairingSecret = ""
    var connectionMessage: String?
    var errorMessage: String?
    var isWorking = false

    init(
        savedCompanionURL: URL? = nil,
        initialErrorMessage: String? = nil
    ) {
        companionURLString = savedCompanionURL?.absoluteString ?? ""
        errorMessage = initialErrorMessage
    }

    func testConnection(connectionManager: CompanionConnectionManager) async {
        errorMessage = nil
        connectionMessage = nil
        isWorking = true
        defer { isWorking = false }

        do {
            let health = try await connectionManager.checkLiveness(
                companionURLString: companionURLString
            )
            let version = health.companionVersion ?? String(localized: "unknown version")
            connectionMessage = String(
                localized: "Companion is reachable (\(version)). Enter a pairing secret to continue."
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connect(connectionManager: CompanionConnectionManager) async {
        errorMessage = nil
        connectionMessage = nil

        if let validationMessage = Self.pairingValidationMessage(
            companionURL: companionURLString,
            pairingSecret: pairingSecret
        ) {
            errorMessage = validationMessage
            return
        }

        isWorking = true
        defer { isWorking = false }

        let paired = await connectionManager.pair(
            companionURLString: companionURLString,
            secret: pairingSecret
        )
        if paired {
            pairingSecret = ""
            connectionMessage = String(localized: "This device is paired with Hermex Companion.")
        } else {
            errorMessage = connectionManager.lastErrorMessage
        }
    }

    nonisolated static func pairingValidationMessage(
        companionURL: String,
        pairingSecret: String
    ) -> String? {
        if companionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Enter the Companion URL.")
        }
        if pairingSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return emptyPairingSecretMessage
        }
        return nil
    }
}
