import Foundation

/// Read-only Keychain bridge for the out-of-process WebUI consumers retained
/// outside the personal-v1 App target. It never writes or migrates credentials.
enum PreservedWebUICredentialReader {
    static func customHeaders(
        for server: URL,
        loadScoped: (String) throws -> String?,
        loadGlobal: () throws -> String?
    ) -> [CustomHeader] {
        let stored: String?
        if let scoped = try? loadScoped(server.absoluteString) {
            stored = scoped
        } else {
            stored = try? loadGlobal()
        }
        return [CustomHeader].decodeFromStorage(stored)
    }
}
