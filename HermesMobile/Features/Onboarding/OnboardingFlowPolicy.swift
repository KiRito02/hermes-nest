import Foundation

enum OnboardingFlowPolicy {
    static let pageCount = 5
    static let connectPageIndex = 4
    static let agentPromptPageIndex = 2

    static let agentSetupPrompt = """
Set up Hermes Nest Companion from my KiRito02/hermes-nest checkout on this server running Hermes Agent.

Follow Companion/README.md exactly. Use Python 3.11, `uv sync --frozen`, the dedicated Companion/.venv, SQLite in the service account's XDG state directory, and the repository systemd template.
Keep Hermes Agent API Server on 127.0.0.1:8642. Put API_SERVER_KEY only in the host-local Companion environment file; never send it to the iPhone, print it, or place it in a URL.
Keep Companion on its default loopback listener. Expose only Companion through my Lucky HTTPS reverse proxy. Tailscale HTTPS is also supported; do not expose Hermes Gateway directly and do not disable TLS verification.
Verify `/companion/v1/health` through the public HTTPS Companion URL.
Reply with:
- The exact HTTPS Companion URL I enter in Hermes Nest
- The exact command I should run myself in a trusted shell on the Hermes Agent host to create a five-minute one-time pairing secret
- Any Lucky, Tailscale, or iPhone step I still need to complete
Do not create, print, request, or include the pairing secret in this chat. Do not install hermes-webui or use a hosted relay.
"""

    static let tailscaleAppStoreURL = URL(string: "itms-apps://apps.apple.com/us/app/tailscale/id1470499037")!

    static let tailscaleAppStoreFallbackURL = URL(string: "https://apps.apple.com/us/app/tailscale/id1470499037")!

    static func primaryButtonTitle(for page: Int) -> String {
        switch page {
        case 0:
            return String(localized: "Get Started")
        case 1:
            return String(localized: "Set Up")
        case connectPageIndex:
            return String(localized: "Connect")
        default:
            return String(localized: "Continue")
        }
    }

    static func shouldShowCopyReminder(
        page: Int,
        hasCopiedAgentPrompt: Bool,
        hasBypassedCopyReminder: Bool = false
    ) -> Bool {
        page == agentPromptPageIndex && !hasCopiedAgentPrompt && !hasBypassedCopyReminder
    }

    static func shouldInterceptForwardNavigationFromAgentPrompt(
        from oldPage: Int,
        to newPage: Int,
        hasCopiedAgentPrompt: Bool,
        hasBypassedCopyReminder: Bool = false
    ) -> Bool {
        oldPage == agentPromptPageIndex
            && newPage > oldPage
            && !hasCopiedAgentPrompt
            && !hasBypassedCopyReminder
    }

    static func shouldClearConnectFocusWhenLeavingPage(_ page: Int) -> Bool {
        page != connectPageIndex
    }

    static func showsServerShortcut(for page: Int) -> Bool {
        page < connectPageIndex
    }
}
