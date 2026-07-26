import XCTest
@testable import HermesMobile

final class OnboardingFlowTests: XCTestCase {
    func testPrimaryButtonTitlesFollowPagerFlow() {
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 0), "Get Started")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 1), "Set Up")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 2), "Continue")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 3), "Continue")
        XCTAssertEqual(OnboardingFlowPolicy.primaryButtonTitle(for: 4), "Connect")
    }

    func testCopyReminderOnlyAppliesToAgentPromptPageWithoutCopy() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                hasCopiedAgentPrompt: false
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                hasCopiedAgentPrompt: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.agentPromptPageIndex,
                hasCopiedAgentPrompt: false,
                hasBypassedCopyReminder: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldShowCopyReminder(
                page: OnboardingFlowPolicy.connectPageIndex,
                hasCopiedAgentPrompt: false
            )
        )
    }

    func testForwardSwipeFromAgentPromptRequiresCopyOrBypass() {
        XCTAssertTrue(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                hasCopiedAgentPrompt: false
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                hasCopiedAgentPrompt: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 3,
                hasCopiedAgentPrompt: false,
                hasBypassedCopyReminder: true
            )
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.shouldInterceptForwardNavigationFromAgentPrompt(
                from: OnboardingFlowPolicy.agentPromptPageIndex,
                to: 1,
                hasCopiedAgentPrompt: false
            )
        )
    }

    func testConnectFocusClearsWhenLeavingConnectPage() {
        XCTAssertTrue(OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(3))
        XCTAssertFalse(OnboardingFlowPolicy.shouldClearConnectFocusWhenLeavingPage(OnboardingFlowPolicy.connectPageIndex))
    }

    func testServerShortcutShowsBeforeConnectPageOnly() {
        XCTAssertTrue(OnboardingFlowPolicy.showsServerShortcut(for: 0))
        XCTAssertTrue(OnboardingFlowPolicy.showsServerShortcut(for: 3))
        XCTAssertFalse(OnboardingFlowPolicy.showsServerShortcut(for: OnboardingFlowPolicy.connectPageIndex))
    }

    func testAgentSetupPromptUsesCompanionAndKeepsGatewaySecretOnHost() {
        let prompt = OnboardingFlowPolicy.agentSetupPrompt

        XCTAssertTrue(prompt.contains("Hermes Nest Companion"))
        XCTAssertTrue(prompt.contains("127.0.0.1:8642"))
        XCTAssertTrue(prompt.contains("API_SERVER_KEY"))
        XCTAssertTrue(prompt.contains("Lucky HTTPS"))
        XCTAssertTrue(prompt.contains("/companion/v1/health"))
        XCTAssertTrue(prompt.contains("trusted shell on the Hermes Agent host"))
        XCTAssertTrue(prompt.contains("Do not create, print, request, or include the pairing secret in this chat."))
        XCTAssertTrue(prompt.contains("Do not install hermes-webui"))
        XCTAssertFalse(prompt.contains("HERMES_WEBUI_PASSWORD"))
    }

    func testTailscaleAppStoreURLUsesITMSDeepLink() {
        XCTAssertEqual(
            OnboardingFlowPolicy.tailscaleAppStoreURL.absoluteString,
            "itms-apps://apps.apple.com/us/app/tailscale/id1470499037"
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.tailscaleAppStoreFallbackURL.absoluteString,
            "https://apps.apple.com/us/app/tailscale/id1470499037"
        )
    }

    func testConnectPageIndexIsFinalPagerPage() {
        XCTAssertEqual(OnboardingFlowPolicy.connectPageIndex, OnboardingFlowPolicy.pageCount - 1)
    }
}
