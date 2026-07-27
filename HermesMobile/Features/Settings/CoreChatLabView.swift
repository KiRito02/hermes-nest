#if DEBUG
import Foundation
import SwiftUI

/// Deterministic, server-free fixture that exercises the production core chat
/// surface. CI launches it with `--core-chat-lab` for localized screenshots.
struct CoreChatLabView: View {
    private let session: SessionSummary
    private let repository: any SessionRepository
    private let runService: any ConversationRunServing
    private let modelService: any CompanionModelServing

    init() {
        let usesSimplifiedChinese =
            Locale.preferredLanguages.first?.hasPrefix("zh-Hans") == true
                || Locale.preferredLanguages.first?.hasPrefix("zh-CN") == true
        let session = CoreChatLabFixture.session(
            usesSimplifiedChinese: usesSimplifiedChinese
        )
        self.session = session
        repository = CoreChatLabRepository(
            session: session,
            messages: CoreChatLabFixture.messages(
                usesSimplifiedChinese: usesSimplifiedChinese
            )
        )
        runService = CoreChatLabRunService(
            usesSimplifiedChinese: usesSimplifiedChinese
        )
        modelService = CoreChatLabModelService()
    }

    var body: some View {
        CompanionSessionHistoryView(
            session: session,
            repository: repository,
            companionURL: URL(string: "https://ui-smoke.invalid")!,
            supportsRunApprovals: true,
            supportsModelSelection: true,
            runService: runService,
            modelService: modelService,
            onUpdated: { _ in },
            onForked: {},
            onDeleted: { _ in }
        )
    }

}

private enum CoreChatLabFixture {
    static func session(
        usesSimplifiedChinese: Bool
    ) -> SessionSummary {
        SessionSummary(
            sessionId: "core-chat-ui-smoke",
            title: usesSimplifiedChinese
                ? "Hermes Nest 界面验收"
                : "Hermes Nest UI Review",
            workspace: "/volume1/agents/hermes",
            model: "anthropic/claude-sonnet-4.6",
            modelProvider: "openrouter",
            messageCount: 6,
            createdAt: 1_753_680_000,
            updatedAt: 1_753_680_420,
            lastMessageAt: 1_753_680_420,
            inputTokens: 18_240,
            outputTokens: 2_816,
            estimatedCost: 0.082
        )
    }

    static func messages(
        usesSimplifiedChinese: Bool
    ) -> [ChatMessage] {
        let content: [(String, String)]
        if usesSimplifiedChinese {
            content = [
                (
                    "user",
                    "检查运行服务器上 Hermes Agent 的状态，并给我一个简洁摘要。"
                ),
                (
                    "assistant",
                    """
                    Hermes Agent 正常运行，Companion 仅通过回环地址连接 Gateway。

                    - 会话历史可读取
                    - Runs SSE 已连接
                    - 设备凭据有效
                    """
                ),
                (
                    "user",
                    "把健康检查命令也给我，代码内容需要能直接选择复制。"
                ),
                (
                    "assistant",
                    """
                    可以，在 Hermes Agent 运行服务器上执行：

                    ```bash
                    systemctl status hermes-nest-companion
                    curl --fail http://127.0.0.1:8788/health
                    ```

                    返回 `ok` 即表示 Companion 与本地 Gateway 通路正常。
                    """
                ),
                (
                    "user",
                    "很好，也要在输入区说明图片附件会如何处理。"
                ),
                (
                    "assistant",
                    "已确认。图片会作为安全文件附件上传，并请求 Hermes "
                        + "尝试通过 Vision 分析；Runs 尚未声明支持原生内联图片输入。"
                ),
            ]
        } else {
            content = [
                (
                    "user",
                    "Check the Hermes Agent host and give me a concise summary."
                ),
                (
                    "assistant",
                    """
                    Hermes Agent is healthy. Companion reaches Gateway over loopback only.

                    - Session history is available
                    - Runs SSE is connected
                    - The device credential is valid
                    """
                ),
                (
                    "user",
                    "Include the health-check command. Code must be selectable in place."
                ),
                (
                    "assistant",
                    """
                    Run this on the Hermes Agent host:

                    ```bash
                    systemctl status hermes-nest-companion
                    curl --fail http://127.0.0.1:8788/health
                    ```

                    An `ok` response confirms the Companion-to-Gateway path.
                    """
                ),
                (
                    "user",
                    "Good. Clarify how image attachments work in the composer."
                ),
                (
                    "assistant",
                    "Confirmed. Images are uploaded as secure file attachments, "
                        + "and Hermes will try Vision analysis. Native inline "
                        + "image input is not advertised by Runs."
                ),
            ]
        }

        return content.enumerated().map { index, item in
            ChatMessage(
                role: item.0,
                content: item.1,
                timestamp: 1_753_680_000 + Double(index * 70),
                messageId: "core-chat-ui-smoke-\(index)"
            )
        }
    }
}

private actor CoreChatLabRepository: SessionRepository {
    let fixtureSession: SessionSummary
    let fixtureMessages: [ChatMessage]

    init(
        session: SessionSummary,
        messages: [ChatMessage]
    ) {
        fixtureSession = session
        fixtureMessages = messages
    }

    func listSessions(
        _ query: SessionListQuery
    ) async throws -> SessionPage {
        SessionPage(
            sessions: [fixtureSession],
            limit: query.limit,
            offset: query.offset,
            hasMore: false
        )
    }

    func createSession(
        _ request: SessionCreateRequest
    ) async throws -> SessionSummary {
        fixtureSession
    }

    func session(id: String) async throws -> SessionSummary {
        fixtureSession
    }

    func updateSession(
        id: String,
        request: SessionUpdateRequest
    ) async throws -> SessionSummary {
        fixtureSession
    }

    func deleteSession(id: String) async throws -> Bool {
        true
    }

    func forkSession(
        id: String,
        request: SessionForkRequest
    ) async throws -> SessionSummary {
        fixtureSession
    }

    func messageHistory(id: String) async throws -> SessionHistory {
        SessionHistory(
            sessionID: fixtureSession.sessionId ?? id,
            messages: fixtureMessages
        )
    }
}

private actor CoreChatLabRunService: ConversationRunServing {
    private let response: String

    init(usesSimplifiedChinese: Bool) {
        response = usesSimplifiedChinese
            ? "这是本地界面验收回复；没有向 Hermes Agent 服务器或 Companion 发送请求。"
            : "This is a local UI-review response; no Hermes Agent host or Companion request was sent."
    }

    func start(
        _ request: ConversationRunStartRequest
    ) async throws -> ConversationRunSnapshot {
        ConversationRunSnapshot(
            runID: "core-chat-ui-smoke-run",
            state: .started,
            sessionID: request.sessionID,
            lastEvent: "run.started",
            output: nil,
            errorMessage: nil
        )
    }

    func status(
        runID: String
    ) async throws -> ConversationRunSnapshot {
        ConversationRunSnapshot(
            runID: runID,
            state: .completed,
            sessionID: "core-chat-ui-smoke",
            lastEvent: "run.completed",
            output: response,
            errorMessage: nil
        )
    }

    func stop(
        runID: String
    ) async throws -> ConversationRunSnapshot {
        ConversationRunSnapshot(
            runID: runID,
            state: .cancelled,
            sessionID: "core-chat-ui-smoke",
            lastEvent: "run.cancelled",
            output: nil,
            errorMessage: nil
        )
    }

    func respondToApproval(
        runID: String,
        choice: ConversationApprovalChoice
    ) async throws -> ConversationApprovalResponse {
        ConversationApprovalResponse(
            runID: runID,
            choice: choice,
            resolved: 1
        )
    }

    func events(
        runID: String
    ) async throws -> AsyncThrowingStream<ConversationRunEvent, Error> {
        let response = response
        return AsyncThrowingStream { continuation in
            continuation.yield(
                .data(
                    ConversationRunEventData(
                        transportEvent: nil,
                        event: "run.delta",
                        runID: runID,
                        delta: response,
                        output: nil,
                        error: nil,
                        timestamp: 1_753_680_490
                    )
                )
            )
            continuation.yield(
                .data(
                    ConversationRunEventData(
                        transportEvent: nil,
                        event: "run.completed",
                        runID: runID,
                        delta: nil,
                        output: response,
                        error: nil,
                        timestamp: 1_753_680_491,
                        usage: ConversationRunUsage(
                            inputTokens: 18_320,
                            outputTokens: 32,
                            totalTokens: 18_352
                        )
                    )
                )
            )
            continuation.finish()
        }
    }
}

private actor CoreChatLabModelService: CompanionModelServing {
    func fetchOptions(
        refresh: Bool
    ) async throws -> CompanionModelInventory {
        CompanionModelInventory(
            providers: [
                CompanionModelProvider(
                    slug: "openrouter",
                    name: "OpenRouter",
                    models: [
                        .string("anthropic/claude-sonnet-4.6"),
                        .string("openai/gpt-5.2"),
                    ],
                    authenticated: true,
                    capabilities: [
                        "anthropic/claude-sonnet-4.6": .object([
                            "reasoning": .bool(true)
                        ])
                    ]
                )
            ],
            model: "anthropic/claude-sonnet-4.6",
            provider: "openrouter"
        )
    }

    func lock(
        _ selection: CompanionModelSelection,
        sessionID: String
    ) async throws -> CompanionModelLockAcknowledgement {
        CompanionModelLockAcknowledgement(
            object: "hermes.session.model_lock",
            sessionID: sessionID,
            runtime: CompanionModelRuntime(
                provider: selection.provider,
                model: selection.model,
                modelLock: "accepted"
            )
        )
    }
}
#endif
