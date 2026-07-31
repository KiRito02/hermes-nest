import Foundation

struct CompanionActiveRunKey: Hashable, Sendable {
    let companionURL: String
    let sessionID: String

    init(companionURL: URL, sessionID: String) {
        self.companionURL = companionURL.absoluteString
        self.sessionID = sessionID
    }

    fileprivate var storageKey: String {
        Data("\(companionURL)\u{0}\(sessionID)".utf8).base64EncodedString()
    }
}

enum CompanionStopRecoveryState: String, Codable, Equatable, Sendable {
    case notRequested
    case deliveryUnknown
    case confirmedStopping
}

struct CompanionActiveRunRecord: Codable, Equatable, Sendable {
    let runID: String
    var stopState: CompanionStopRecoveryState
}

protocol CompanionActiveRunStoring: Sendable {
    func activeRun(for key: CompanionActiveRunKey) async
        -> CompanionActiveRunRecord?

    func store(
        _ record: CompanionActiveRunRecord,
        for key: CompanionActiveRunKey
    ) async

    func updateStopState(
        _ state: CompanionStopRecoveryState,
        runID: String,
        for key: CompanionActiveRunKey
    ) async

    func clear(
        runID: String,
        for key: CompanionActiveRunKey
    ) async
}

/// Keeps remote run recovery state independent of a transient chat view.
actor CompanionActiveRunStore: CompanionActiveRunStoring {
    static let shared = CompanionActiveRunStore(defaults: .standard)

    private static let defaultsKey =
        "com.kirito02.hermesnest.active-runs.v1"

    private let defaults: UserDefaults?
    private var records: [String: CompanionActiveRunRecord]

    /// A nil defaults value creates an isolated in-memory store for tests.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if
            let data = defaults?.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode(
                [String: CompanionActiveRunRecord].self,
                from: data
            )
        {
            records = decoded
        } else {
            records = [:]
        }
    }

    func activeRun(
        for key: CompanionActiveRunKey
    ) -> CompanionActiveRunRecord? {
        records[key.storageKey]
    }

    func store(
        _ record: CompanionActiveRunRecord,
        for key: CompanionActiveRunKey
    ) {
        records[key.storageKey] = record
        persist()
    }

    func updateStopState(
        _ state: CompanionStopRecoveryState,
        runID: String,
        for key: CompanionActiveRunKey
    ) {
        guard var record = records[key.storageKey] else { return }
        guard record.runID == runID else { return }
        record.stopState = state
        records[key.storageKey] = record
        persist()
    }

    func clear(
        runID: String,
        for key: CompanionActiveRunKey
    ) {
        guard records[key.storageKey]?.runID == runID else { return }
        records[key.storageKey] = nil
        persist()
    }

    private func persist() {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
