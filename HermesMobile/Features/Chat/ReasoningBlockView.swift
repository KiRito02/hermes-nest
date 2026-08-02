import SwiftUI

struct ReasoningBlockView: View {
    let text: String
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?

    init(text: String, isActive: Bool = false) {
        self.text = text
        self.isActive = isActive
    }

    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    var body: some View {
        if let trimmedText {
            let summary = summary(for: trimmedText)

            VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
                Button {
                    withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                        userToggledExpansion = !isExpanded
                    }
                } label: {
                    header(summary: summary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(stateTitle), \(summary)")
                .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

                if isExpanded {
                    ScrollView(.vertical) {
                        MarkdownRenderer(content: trimmedText)
                            .font(AppFont.caption())
                            .foregroundStyle(.primary)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                    }
                    .frame(maxHeight: 280)
                    .scrollIndicators(.visible)
                    .scrollBounceBehavior(.basedOnSize)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.28))
                                .frame(width: 2)
                        }
                        .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private func header(summary: String) -> some View {
        HStack(alignment: usesStackedHeader ? .top : .center, spacing: 8) {
            Image("LucideBrain")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            if usesStackedHeader {
                VStack(alignment: .leading, spacing: 1) {
                    titleText
                    summaryText(summary, lineLimit: 2)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    summaryText(summary, lineLimit: 1)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        HStack(spacing: 5) {
            Text(stateTitle)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.18),
                    value: stateTitle
                )

            if isActive {
                TimelineView(
                    .animation(
                        minimumInterval: 0.18,
                        paused: reduceMotion
                    )
                ) { context in
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 4, height: 4)
                                .opacity(
                                    dotOpacity(
                                        index: index,
                                        date: context.date
                                    )
                                )
                        }
                    }
                }
                .frame(width: 18, height: 8)
                .accessibilityHidden(true)
            }
        }
        .font(AppFont.caption(weight: .semibold))
        .foregroundStyle(.primary)
    }

    private func summaryText(_ value: String, lineLimit: Int) -> some View {
        Text(value)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .contentTransition(.opacity)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: value
            )
    }

    private var stateTitle: String {
        isActive
            ? String(localized: "Thinking")
            : String(localized: "Thought process")
    }

    private var trimmedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func summary(for value: String) -> String {
        let latestLine = value
            .split(whereSeparator: \.isNewline)
            .reversed()
            .compactMap { line -> String? in
                let cleaned = String(line)
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "__", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            }
            .first ?? stateTitle

        if latestLine.count <= 80 {
            return latestLine
        }

        return "\(latestLine.prefix(80))..."
    }

    private func dotOpacity(index: Int, date: Date) -> Double {
        guard !reduceMotion else { return 0.65 }
        let step = Int(date.timeIntervalSinceReferenceDate / 0.18) % 3
        return step == index ? 1 : 0.28
    }
}
