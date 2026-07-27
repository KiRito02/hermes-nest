import SwiftUI
import UIKit

struct ReasoningGroup: Identifiable, Equatable {
    let id: String
    let anchorMessageID: String?
    let text: String

    init(
        id: String = UUID().uuidString,
        anchorMessageID: String?,
        text: String
    ) {
        self.id = id
        self.anchorMessageID = anchorMessageID
        self.text = text
    }
}

enum CompanionReasoningPresentation {
    nonisolated static func groups(
        messages: [ChatMessage],
        messageOffset: Int? = nil,
        archivedGroups: [ReasoningGroup] = []
    ) -> [ReasoningGroup] {
        let turnKeysByMessageID =
            TranscriptTurnClassifier.assistantTurnKeysByAnchorID(
                messages,
                messageOffset: messageOffset
            )
        let assistantMessagesByID = messages.enumerated().reduce(
            into: [String: ChatMessage]()
        ) { result, entry in
            let message = entry.element
            guard message.role == "assistant" else { return }
            let anchorID = TranscriptTurnClassifier.anchorID(
                for: message,
                at: entry.offset,
                messageOffset: messageOffset
            )
            result[anchorID] = message
        }

        var candidates: [ReasoningDisplayCandidate] = []
        var order = 0

        for group in archivedGroups {
            let visibleText = group.anchorMessageID.flatMap {
                assistantMessagesByID[$0]?.content
            }
            appendCandidate(
                text: group.text,
                anchorMessageID: group.anchorMessageID,
                turnKey: group.anchorMessageID.flatMap {
                    turnKeysByMessageID[$0]
                } ?? "archived:\(group.anchorMessageID ?? group.id)",
                visibleText: visibleText,
                order: &order,
                candidates: &candidates
            )
        }

        for (messageIndex, message) in messages.enumerated()
        where message.role == "assistant" {
            let anchorID = TranscriptTurnClassifier.anchorID(
                for: message,
                at: messageIndex,
                messageOffset: messageOffset
            )
            let turnKey =
                turnKeysByMessageID[anchorID] ?? "message:\(anchorID)"
            for text in reasoningTexts(from: message) {
                appendCandidate(
                    text: text,
                    anchorMessageID: anchorID,
                    turnKey: turnKey,
                    visibleText: message.content,
                    order: &order,
                    candidates: &candidates
                )
            }
        }

        var latestCandidateIndexByKey: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            latestCandidateIndexByKey[
                "\(candidate.turnKey)::\(normalizedKey(candidate.text))"
            ] = index
        }

        return candidates.enumerated().compactMap { index, candidate in
            let key =
                "\(candidate.turnKey)::\(normalizedKey(candidate.text))"
            guard latestCandidateIndexByKey[key] == index else {
                return nil
            }
            return ReasoningGroup(
                id:
                    "reasoning-\(candidate.anchorMessageID ?? "unanchored")-\(candidate.order)",
                anchorMessageID: candidate.anchorMessageID,
                text: candidate.text
            )
        }
    }

    nonisolated private static func appendCandidate(
        text: String,
        anchorMessageID: String?,
        turnKey: String,
        visibleText: String?,
        order: inout Int,
        candidates: inout [ReasoningDisplayCandidate]
    ) {
        guard
            let text = strippedVisibleAssistantEcho(
                fromReasoning: text,
                visibleText: visibleText
            )
        else {
            return
        }
        candidates.append(
            ReasoningDisplayCandidate(
                order: order,
                anchorMessageID: anchorMessageID,
                turnKey: turnKey,
                text: text
            )
        )
        order += 1
    }

    nonisolated private static func reasoningTexts(
        from message: ChatMessage
    ) -> [String] {
        if let partsText = reasoningText(fromContentParts: message.contentParts) {
            return [partsText]
        }
        if let reasoning = nonEmptyText(message.reasoning) {
            return [reasoning]
        }
        if let contentReasoning = reasoningText(fromContent: message.content) {
            return [contentReasoning]
        }
        return []
    }

    nonisolated private static func reasoningText(
        fromContentParts parts: [JSONValue]?
    ) -> String? {
        guard let parts else { return nil }
        let text = parts.compactMap { part -> String? in
            guard
                case .object(let object) = part,
                let type = jsonStringValue(object["type"]),
                type == "thinking" || type == "reasoning"
            else {
                return nil
            }
            return jsonStringValue(object["thinking"])
                ?? jsonStringValue(object["reasoning"])
                ?? jsonStringValue(object["text"])
        }
        .joined(separator: "\n")
        return nonEmptyText(text)
    }

    nonisolated private static func reasoningText(
        fromContent content: String?
    ) -> String? {
        guard let content = nonEmptyText(content) else { return nil }
        if let text = leadingDelimitedText(
            in: content,
            open: "<think>",
            close: "</think>"
        ) {
            return text
        }
        if let text = leadingDelimitedText(
            in: content,
            open: "<|channel|>thought",
            close: "<channel|>"
        ) {
            return text
        }
        return leadingDelimitedText(
            in: content,
            open: "<|turn|>thinking\n",
            close: "<turn|>"
        )
    }

    nonisolated private static func leadingDelimitedText(
        in content: String,
        open: String,
        close: String
    ) -> String? {
        let trimmed = content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            trimmed.hasPrefix(open),
            let closeRange = trimmed.range(
                of: close,
                range:
                    trimmed.index(
                        trimmed.startIndex,
                        offsetBy: open.count
                    )..<trimmed.endIndex
            )
        else {
            return nil
        }
        let start = trimmed.index(
            trimmed.startIndex,
            offsetBy: open.count
        )
        return nonEmptyText(String(trimmed[start..<closeRange.lowerBound]))
    }

    nonisolated private static func strippedVisibleAssistantEcho(
        fromReasoning reasoning: String,
        visibleText: String?
    ) -> String? {
        var output = reasoning
        let visibleParagraphs =
            visibleText?
            .components(separatedBy: "\n\n")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { $0.count >= 20 } ?? []
        for paragraph in visibleParagraphs {
            output = output.replacingOccurrences(
                of: paragraph,
                with: ""
            )
        }
        return nonEmptyText(output)
    }

    nonisolated private static func normalizedKey(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func nonEmptyText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    nonisolated private static func jsonStringValue(
        _ value: JSONValue?
    ) -> String? {
        switch value {
        case .string(let value):
            return value
        case .number(let value):
            return value.formatted()
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array, .null, nil:
            return nil
        }
    }
}

private struct ReasoningDisplayCandidate {
    let order: Int
    let anchorMessageID: String?
    let turnKey: String
    let text: String
}

struct CompanionMessageQuickActions: View {
    let text: String
    let onCopy: () -> Void

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                onCopy()
                didCopy = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    didCopy = false
                }
            } label: {
                actionIcon(
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .help(didCopy ? "Copied Message" : "Copy Message")
            .accessibilityLabel(
                didCopy ? "Copied Message" : "Copy Message"
            )
            .accessibilityHint(
                "Copies this completed message to the clipboard."
            )

            ShareLink(item: text) {
                actionIcon(systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .help("Share Message")
            .accessibilityLabel("Share Message")
            .accessibilityHint(
                "Opens the system share sheet for this completed message."
            )
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func actionIcon(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .chatMinimumHitTarget(in: Circle())
    }
}

struct CompanionShareItem: Identifiable {
    let fileURL: URL

    var id: String {
        fileURL.absoluteString
    }
}

struct CompanionShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

struct CompanionOfflineCacheBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text("Offline - viewing cached version")
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}
