import SwiftUI

struct OnboardingTailscalePage: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                OnboardingStepHeader(
                    stepNumber: 2,
                    icon: "iphone.and.arrow.forward",
                    title: String(localized: "Use a trusted HTTPS connection"),
                    description: String(localized: "Use your Lucky HTTPS URL, or install Tailscale and join the same tailnet as your NAS. The next screen accepts either trusted HTTPS URL.")
                )

                VStack(alignment: .leading, spacing: 14) {
                    tailscaleStep(number: "1", text: String(localized: "Preferred: use the Lucky HTTPS hostname that proxies only to Companion."))
                    tailscaleStep(number: "2", text: String(localized: "Private alternative: install Tailscale and sign in to the NAS tailnet."))
                    tailscaleStep(number: "3", text: String(localized: "Do not expose Hermes Gateway directly or disable certificate checks."))

                    Button(action: openTailscaleInAppStore) {
                        Label("Get Tailscale on the App Store", systemImage: "arrow.up.forward.square")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.10))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the Tailscale page in the App Store.")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func openTailscaleInAppStore() {
        openURL(OnboardingFlowPolicy.tailscaleAppStoreURL, completion: { accepted in
            guard !accepted else { return }
            openURL(OnboardingFlowPolicy.tailscaleAppStoreFallbackURL)
        })
    }

    private func tailscaleStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 23, height: 23)
                .background(Color(red: 1.0, green: 0.74, blue: 0.10), in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
