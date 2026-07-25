import SwiftUI

struct OnboardingAgentPromptPage: View {
    @Binding var hasCopiedAgentPrompt: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                OnboardingStepHeader(
                    stepNumber: 1,
                    icon: "terminal",
                    title: String(localized: "Set up Hermex Companion"),
                    description: String(localized: "Send this prompt to an agent on your NAS. It installs Companion, keeps the Gateway key local, and prepares HTTPS access.")
                )

                OnboardingAgentPromptCard(
                    prompt: OnboardingFlowPolicy.agentSetupPrompt,
                    hasCopied: $hasCopiedAgentPrompt
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
