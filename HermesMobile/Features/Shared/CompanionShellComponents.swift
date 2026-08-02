import Foundation
import SwiftUI

enum CompanionShellDestination: CaseIterable, Hashable {
    case files
    case memory
    case skillsAndToolsets

    var title: String {
        switch self {
        case .files:
            String(localized: "Files")
        case .memory:
            String(localized: "Memory")
        case .skillsAndToolsets:
            String(localized: "Skills and Toolsets")
        }
    }

    var systemImage: String {
        switch self {
        case .files:
            "folder"
        case .memory:
            "brain"
        case .skillsAndToolsets:
            "books.vertical"
        }
    }
}

struct CompanionShellDestinationRow: View {
    let destination: CompanionShellDestination
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HermesNestDesign.Spacing.medium) {
                Image(systemName: destination.systemImage)
                    .font(.body.weight(.medium))
                    .frame(
                        width: HermesNestDesign.Shell.sidebarIconWidth,
                        alignment: .center
                    )
                    .foregroundStyle(.primary)

                Text(destination.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isEnabled {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, HermesNestDesign.Spacing.medium)
            .frame(
                minHeight: HermesNestDesign.Shell.minimumControlSize
            )
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? HermesNestDesign.selectedSurface
                    : Color.clear,
                in: RoundedRectangle(
                    cornerRadius:
                        HermesNestDesign.Shell.sidebarRowCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(destination.title)
        .accessibilityHint(
            isEnabled
                ? Text("Opens this destination")
                : Text("Unavailable with this Gateway or Companion")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CompanionConnectionRow: View {
    let companionURL: URL
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HermesNestDesign.Spacing.medium) {
                ZStack(alignment: .bottomTrailing) {
                    Image("HermesAppIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())

                    Circle()
                        .fill(Color(uiColor: .systemGreen))
                        .frame(width: 10, height: 10)
                        .overlay {
                            Circle()
                                .stroke(HermesNestDesign.sidebar, lineWidth: 2)
                        }
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Connected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(endpointLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, HermesNestDesign.Spacing.medium)
            .frame(
                minHeight: HermesNestDesign.Shell.minimumControlSize + 8
            )
            .contentShape(Rectangle())
            .background(
                HermesNestDesign.raisedSurface,
                in: RoundedRectangle(
                    cornerRadius:
                        HermesNestDesign.Shell.connectionRowCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(localized: "Connected") + ", " + endpointLabel
        )
        .accessibilityHint("Shows Companion connection details")
    }

    private var endpointLabel: String {
        guard let host = companionURL.host else {
            return companionURL.absoluteString
        }
        guard let port = companionURL.port else { return host }
        return "\(host):\(port)"
    }
}

struct CompanionConnectionDetailsView: View {
    @Environment(\.dismiss) private var dismiss

    let companionURL: URL
    let gatewayStatus: String?
    let isWorking: Bool
    let onRefresh: () -> Void
    let onForget: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color(uiColor: .systemGreen))

                    LabeledContent("Companion") {
                        Text(companionURL.absoluteString)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }

                    LabeledContent("Gateway status") {
                        Text(gatewayStatus ?? String(localized: "Unavailable"))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isWorking)
                }

                Section {
                    Button(role: .destructive) {
                        onForget()
                    } label: {
                        Label(
                            "Forget Companion",
                            systemImage:
                                "rectangle.portrait.and.arrow.right"
                        )
                    }
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
