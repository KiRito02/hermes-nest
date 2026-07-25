import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CompanionConnectionManager {
    enum State: Equatable {
        case restoring
        case unconfigured(savedURL: URL?)
        case connected(CompanionConnection)
        case disconnected(savedURL: URL?, message: String)
        case pairingRequired(savedURL: URL?, message: String)

        var companionURL: URL? {
            switch self {
            case .restoring:
                return nil
            case .unconfigured(let savedURL),
                 .disconnected(let savedURL, _),
                 .pairingRequired(let savedURL, _):
                return savedURL
            case .connected(let connection):
                return connection.companionURL
            }
        }
    }

    private(set) var state: State = .restoring
    private(set) var isWorking = false
    private(set) var lastErrorMessage: String?

    private let service: any CompanionConnectionServing
    private let deviceName: @MainActor () -> String
    private var didRestore = false

    init(
        service: any CompanionConnectionServing = LiveCompanionConnectionService(),
        deviceName: @escaping @MainActor () -> String = { UIDevice.current.name }
    ) {
        self.service = service
        self.deviceName = deviceName
    }

    func restoreIfNeeded() async {
        guard !didRestore else { return }
        didRestore = true
        await resume()
    }

    func checkLiveness(companionURLString: String) async throws -> CompanionHealth {
        try await service.checkLiveness(companionURLString: companionURLString)
    }

    @discardableResult
    func pair(
        companionURLString: String,
        secret: String
    ) async -> Bool {
        let previousState = state
        isWorking = true
        lastErrorMessage = nil
        defer { isWorking = false }

        do {
            let connection = try await service.pair(
                companionURLString: companionURLString,
                secret: secret,
                deviceName: deviceName()
            )
            state = .connected(connection)
            return true
        } catch {
            let savedURL = await service.savedCompanionURL()
            let message = error.localizedDescription
            lastErrorMessage = message
            if await service.hasStoredDeviceCredential() {
                state = .disconnected(savedURL: savedURL, message: message)
            } else {
                // A rejected/expired secret is an inline onboarding error. Keep
                // the current screen and its entered URL instead of replacing
                // it with a new root view and losing the form state.
                state = previousState
            }
            return false
        }
    }

    func resume() async {
        isWorking = true
        lastErrorMessage = nil
        defer { isWorking = false }

        do {
            if let connection = try await service.resume() {
                state = .connected(connection)
            } else {
                state = .unconfigured(savedURL: await service.savedCompanionURL())
            }
        } catch {
            await apply(error)
        }
    }

    func forgetConnection() async {
        await service.forget()
        lastErrorMessage = nil
        state = .unconfigured(savedURL: nil)
    }

    private func apply(_ error: Error) async {
        let savedURL = await service.savedCompanionURL()
        let message = error.localizedDescription
        lastErrorMessage = message

        switch error {
        case CompanionConnectionError.invalidDeviceCredential,
             CompanionConnectionError.deviceRevoked:
            state = .pairingRequired(savedURL: savedURL, message: message)
        default:
            state = .disconnected(savedURL: savedURL, message: message)
        }
    }
}
