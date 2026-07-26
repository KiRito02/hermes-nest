import SwiftUI
import SwiftData

struct HermexSceneActions {
    let canCreateNewChat: Bool
    let createNewChat: () -> Void
    let searchSessions: () -> Void
}

private struct HermexSceneActionsKey: FocusedValueKey {
    typealias Value = HermexSceneActions
}

extension FocusedValues {
    var hermexSceneActions: HermexSceneActions? {
        get { self[HermexSceneActionsKey.self] }
        set { self[HermexSceneActionsKey.self] = newValue }
    }
}

struct HermexCommands: Commands {
    @FocusedValue(\.hermexSceneActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                actions?.createNewChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions?.canCreateNewChat != true)
        }

        CommandGroup(after: .newItem) {
            Button("Search Sessions") {
                actions?.searchSessions()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions == nil)
        }
    }
}

@main
struct HermesMobileApp: App {
    @State private var connectionManager = CompanionConnectionManager()
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Debug launch hooks let CI and local simulator diagnostics open
            // deterministic, server-free UI fixtures without navigating or
            // reading credentials.
            if ProcessInfo.processInfo.arguments.contains("--streaming-lab") {
                NavigationStack {
                    StreamingLabView()
                }
            } else if ProcessInfo.processInfo.arguments.contains("--core-chat-lab") {
                NavigationStack {
                    CoreChatLabView()
                }
            } else if ProcessInfo.processInfo.arguments.contains("--long-chat-lab") {
                NavigationStack {
                    LongChatLabView()
                }
            } else if ProcessInfo.processInfo.arguments.contains("--kanban-lab") {
                NavigationStack {
                    KanbanLabView()
                }
            } else {
                CompanionRootView(connectionManager: connectionManager)
                    .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            }
            #else
            CompanionRootView(connectionManager: connectionManager)
                .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            #endif
        }
        .modelContainer(for: [CachedSession.self, CachedMessage.self])
        .commands {
            HermexCommands()
            SidebarCommands()
        }
    }
}
