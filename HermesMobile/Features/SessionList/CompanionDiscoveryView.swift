import SwiftUI

@MainActor
struct CompanionDiscoveryView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case skills
        case toolsets

        var id: String { rawValue }

        var title: String {
            switch self {
            case .skills: return String(localized: "Skills")
            case .toolsets: return String(localized: "Toolsets")
            }
        }
    }

    @State private var viewModel: CompanionDiscoveryViewModel
    @State private var selectedSection = Section.skills
    @State private var searchText = ""

    init(
        companionURL: URL,
        capabilities: CompanionCapabilities,
        service: (any CompanionDiscoveryServing)? = nil
    ) {
        _viewModel = State(
            initialValue: CompanionDiscoveryViewModel(
                service: service ?? CompanionDiscoveryService(
                    companionURL: companionURL
                ),
                isSupported:
                    capabilities.supportsSkillsAndToolsetsDiscovery
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Capability type", selection: $selectedSection) {
                ForEach(Section.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            content
        }
        .background(HermesNestDesign.canvas)
        .navigationTitle("Skills & Toolsets")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search capabilities"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(
                    viewModel.isLoading
                        || viewModel.unavailableMessage != nil
                )
            }
        }
        .task {
            if viewModel.skills.isEmpty && viewModel.toolsets.isEmpty {
                await viewModel.load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let unavailable = viewModel.unavailableMessage {
            unavailableView(
                title: "Discovery unavailable",
                systemImage: "lock.trianglebadge.exclamationmark",
                message: unavailable,
                offersRetry: false
            )
        } else if viewModel.isLoading
                    && viewModel.skills.isEmpty
                    && viewModel.toolsets.isEmpty {
            ProgressView("Loading capabilities...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage,
                  viewModel.skills.isEmpty,
                  viewModel.toolsets.isEmpty {
            unavailableView(
                title: "Could not load capabilities",
                systemImage: "wifi.exclamationmark",
                message: error,
                offersRetry: true
            )
        } else {
            VStack(spacing: 0) {
                if let error = viewModel.errorMessage {
                    staleCatalogError(message: error)
                }
                catalogContent
            }
        }
    }

    @ViewBuilder
    private var catalogContent: some View {
        switch selectedSection {
        case .skills:
            skillsContent
        case .toolsets:
            toolsetsContent
        }
    }

    private func staleCatalogError(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Retry") {
                Task { await viewModel.load() }
            }
            .font(.footnote.weight(.semibold))
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var skillsContent: some View {
        let skills = viewModel.matchingSkills(searchText: searchText)
        if viewModel.skills.isEmpty {
            emptyView(
                title: "No Skills",
                systemImage: "hammer",
                message: "Hermes Gateway did not report any installed Skills."
            )
        } else if skills.isEmpty {
            noResultsView
        } else {
            capabilityGrid {
                ForEach(skills) { skill in
                    NavigationLink {
                        CompanionSkillDetailView(skill: skill)
                    } label: {
                        CompanionSkillCard(skill: skill)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var toolsetsContent: some View {
        let toolsets = viewModel.matchingToolsets(searchText: searchText)
        if viewModel.toolsets.isEmpty {
            emptyView(
                title: "No Toolsets",
                systemImage: "wrench.and.screwdriver",
                message: "Hermes Gateway did not report any API Server Toolsets."
            )
        } else if toolsets.isEmpty {
            noResultsView
        } else {
            capabilityGrid {
                ForEach(toolsets) { toolset in
                    NavigationLink {
                        CompanionToolsetDetailView(toolset: toolset)
                    } label: {
                        CompanionToolsetCard(toolset: toolset)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func capabilityGrid<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 300, maximum: 520),
                        spacing: 14,
                        alignment: .top
                    )
                ],
                alignment: .center,
                spacing: 14
            ) {
                content()
            }
            .padding(16)
            .frame(maxWidth: 1_120)
            .frame(maxWidth: .infinity)
        }
        .background(HermesNestDesign.canvas)
        .refreshable {
            await viewModel.load()
        }
    }

    private var noResultsView: some View {
        emptyView(
            title: "No Results",
            systemImage: "magnifyingglass",
            message: "No capabilities match “\(searchText)”."
        )
    }

    private func emptyView(
        title: LocalizedStringKey,
        systemImage: String,
        message: LocalizedStringKey
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableView(
        title: LocalizedStringKey,
        systemImage: String,
        message: String,
        offersRetry: Bool
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if offersRetry {
                Button("Try Again") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CompanionSkillCard: View {
    let skill: CompanionSkill

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hammer.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 7) {
                Text(skill.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let category = skill.category {
                    Text(category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }

                if let description = skill.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 4)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(
            HermesNestDesign.sidebar,
            in: RoundedRectangle(
                cornerRadius: HermesNestDesign.cardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: HermesNestDesign.cardCornerRadius,
                style: .continuous
            )
            .stroke(HermesNestDesign.subtleBorder, lineWidth: 0.5)
        }
        .contentShape(
            RoundedRectangle(
                cornerRadius: HermesNestDesign.cardCornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows read-only Skill details")
    }
}

private struct CompanionToolsetCard: View {
    let toolset: CompanionToolset

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 7) {
                Text(toolset.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if toolset.displayName != toolset.name {
                    Text(toolset.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    if let enabled = toolset.enabled {
                        stateBadge(
                            enabled ? "Enabled" : "Disabled",
                            color: enabled ? .green : .secondary
                        )
                    }
                    if let configured = toolset.configured {
                        stateBadge(
                            configured ? "Configured" : "Not configured",
                            color: configured ? .blue : .secondary
                        )
                    }
                }

                if let description = toolset.description,
                   !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 4)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(
            HermesNestDesign.sidebar,
            in: RoundedRectangle(
                cornerRadius: HermesNestDesign.cardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: HermesNestDesign.cardCornerRadius,
                style: .continuous
            )
            .stroke(HermesNestDesign.subtleBorder, lineWidth: 0.5)
        }
        .contentShape(
            RoundedRectangle(
                cornerRadius: HermesNestDesign.cardCornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows read-only Toolset details")
    }

    private func stateBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct CompanionSkillDetailView: View {
    let skill: CompanionSkill

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(skill.name, systemImage: "hammer.fill")
                    .font(.title2.bold())

                if let category = skill.category {
                    LabeledContent("Category") {
                        Text(category)
                            .textSelection(.enabled)
                    }
                }

                if let description = skill.description,
                   !description.isEmpty {
                    detailSection(title: "Description") {
                        Text(description)
                            .textSelection(.enabled)
                    }
                }

                Label(
                    "Read-only metadata from Hermes Gateway",
                    systemImage: "lock"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(HermesNestDesign.canvas)
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CompanionToolsetDetailView: View {
    let toolset: CompanionToolset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(
                    toolset.displayName,
                    systemImage: "wrench.and.screwdriver.fill"
                )
                .font(.title2.bold())

                LabeledContent("Identifier") {
                    Text(toolset.name)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }

                if let enabled = toolset.enabled {
                    LabeledContent("API Server") {
                        Label(
                            enabled ? "Enabled" : "Disabled",
                            systemImage: enabled
                                ? "checkmark.circle.fill"
                                : "minus.circle"
                        )
                        .foregroundStyle(enabled ? .green : .secondary)
                    }
                }

                if let configured = toolset.configured {
                    LabeledContent("Configuration") {
                        Text(configured ? "Configured" : "Not configured")
                    }
                }

                if let description = toolset.description,
                   !description.isEmpty {
                    detailSection(title: "Description") {
                        Text(description)
                            .textSelection(.enabled)
                    }
                }

                if let tools = toolset.tools {
                    detailSection(title: "Tools (\(tools.count))") {
                        if tools.isEmpty {
                            Text("No concrete tools were supplied.")
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(
                                columns: [
                                    GridItem(
                                        .adaptive(minimum: 190),
                                        alignment: .leading
                                    )
                                ],
                                alignment: .leading,
                                spacing: 8
                            ) {
                                ForEach(tools, id: \.self) { tool in
                                    Text(tool)
                                        .font(.callout.monospaced())
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .frame(
                                            maxWidth: .infinity,
                                            alignment: .leading
                                        )
                                        .background(
                                            .quaternary,
                                            in: RoundedRectangle(
                                                cornerRadius: 8
                                            )
                                        )
                                }
                            }
                        }
                    }
                }

                Label(
                    "Read-only metadata from Hermes Gateway",
                    systemImage: "lock"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(HermesNestDesign.canvas)
        .navigationTitle(toolset.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func detailSection<Content: View>(
    title: LocalizedStringKey,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.headline)
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
