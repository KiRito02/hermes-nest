#if DEBUG
import SwiftUI
import UIKit

/// Debug-only Streaming Lab (issue #234): replays a canned markdown fixture
/// through the real display pipeline (`MarkdownRenderer(content:isStreaming:)`
/// → chunked streaming view → fade window) while the fade knobs are tuned
/// live via `StreamingTextFadeLab`. No server, deterministic content.
struct StreamingLabView: View {
    @State private var displayedContent = ""
    @State private var isStreaming = false
    @State private var replayID = 0
    @State private var followsTail = true
    // Surfaced here because the user setting silently disables every fade
    // knob below — invisible state the lab must make visible (see the #232
    // textSelection dead-cascade hunt).
    @AppStorage(StreamedTextAnimationSettings.isEnabledKey) private var isStreamedTextAnimationEnabled = true

    @State private var wordsPerSecond = StreamingLabReplay.defaultWordsPerSecond
    @State private var fadeDuration = StreamingTextFadeLab.shared.fadeDuration
    @State private var glyphStagger = StreamingTextFadeLab.shared.glyphStagger
    @State private var maxStampLead = StreamingTextFadeLab.shared.maxStampLead

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    Divider()
                    transcript
                    Color.clear
                        .frame(height: 1)
                        .id(Self.tailAnchorID)
                }
                .padding(16)
            }
            .onChange(of: displayedContent) { _, _ in
                guard followsTail else { return }
                proxy.scrollTo(Self.tailAnchorID, anchor: .bottom)
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Streaming Lab")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: replayID) {
            await replayFixture()
        }
    }

    private static let tailAnchorID = "streaming-lab-tail"

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    replayID += 1
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    StreamingTextFadeLab.shared.reset()
                    fadeDuration = StreamingTextFadeDefaults.Baseline.fadeDuration
                    glyphStagger = StreamingTextFadeDefaults.Baseline.glyphStagger
                    maxStampLead = StreamingTextFadeDefaults.Baseline.maxStampLead
                } label: {
                    Label("Reset Knobs", systemImage: "slider.horizontal.2.arrow.trianglehead.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Toggle("Follow tail while streaming", isOn: $followsTail)
                .font(.subheadline)

            Toggle("Streamed text animation (user setting)", isOn: $isStreamedTextAnimationEnabled)
                .font(.subheadline)

            if !isStreamedTextAnimationEnabled {
                Text("Animation is off — the knobs below have no visible effect until it's re-enabled.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            knobSlider(
                title: "Stream speed",
                value: $wordsPerSecond,
                range: StreamingLabReplay.minWordsPerSecond...StreamingLabReplay.maxWordsPerSecond,
                display: String(format: "%.0f words/s", wordsPerSecond)
            )

            knobSlider(
                title: "fadeDuration",
                value: $fadeDuration,
                range: 0.05...1.0,
                display: String(format: "%.2f s", fadeDuration)
            )
            .onChange(of: fadeDuration) { _, newValue in
                StreamingTextFadeLab.shared.fadeDuration = newValue
            }

            knobSlider(
                title: "glyphStagger",
                value: $glyphStagger,
                range: 0...0.06,
                display: String(format: "%.0f ms", glyphStagger * 1000)
            )
            .onChange(of: glyphStagger) { _, newValue in
                StreamingTextFadeLab.shared.glyphStagger = newValue
            }

            knobSlider(
                title: "maxStampLead",
                value: $maxStampLead,
                range: 0...1.5,
                display: String(format: "%.2f s", maxStampLead)
            )
            .onChange(of: maxStampLead) { _, newValue in
                StreamingTextFadeLab.shared.maxStampLead = newValue
            }

            knobReadout
        }
    }

    private func knobSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(display)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range)
        }
    }

    /// Paste-ready values for `StreamingTextFadeDefaults` once a feel is
    /// chosen (the lab never persists anything across launches).
    private var knobReadout: some View {
        Text(
            """
            static let fadeDuration: TimeInterval = \(String(format: "%.3f", fadeDuration))
            static let glyphStagger: TimeInterval = \(String(format: "%.3f", glyphStagger))
            static let maxStampLead: TimeInterval = \(String(format: "%.3f", maxStampLead))
            """
        )
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var transcript: some View {
        MarkdownRenderer(content: displayedContent, isStreaming: isStreaming)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Local word-cadence appender standing in for the server stream: reveals
    /// the fixture unit-by-unit at the production tick interval, with the
    /// speed slider scaling how many units each tick deposits.
    private func replayFixture() async {
        displayedContent = ""
        isStreaming = true

        let fixture = StreamingLabReplay.fixture
        let totalUnits = StreamingLabReplay.fixtureUnitCount
        var revealed = 0
        var carry = 0.0

        while revealed < totalUnits {
            try? await Task.sleep(for: .seconds(StreamingLabReplay.tickInterval))
            guard !Task.isCancelled else { return }

            (revealed, carry) = StreamingLabReplay.advance(
                revealed: revealed,
                carry: carry,
                wordsPerSecond: wordsPerSecond
            )
            revealed = min(revealed, totalUnits)
            displayedContent = StreamingLabReplay.prefix(of: fixture, unitCount: revealed)
        }

        // A cancelled replay must not flip the flag: on restart the new task
        // has already set `isStreaming = true` and this would end its fade.
        guard !Task.isCancelled else { return }
        isStreaming = false
    }
}

/// Debug-only, server-free long transcript harness. Launch with
/// `--long-chat-lab`, start Instruments, then scroll upward while the final
/// response continues to stream.
struct LongChatLabView: View {
    private enum Fixture: String, CaseIterable, Identifiable {
        case shortPlain = "Short plain"
        case longMixed = "200 mixed"

        var id: Self { self }
    }

    @State private var displayedStreamingContent = ""
    @State private var isStreaming = false
    @State private var replayID = 0
    @State private var fixture: Fixture = .longMixed
    @State private var scrollMetrics = ChatScrollMetrics(
        distanceFromBottom: 0,
        isUserInteracting: false
    )

    private static let topAnchorID = "long-chat-lab-top"
    private static let bottomAnchorID = "long-chat-lab-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ChatTranscriptLazyStack(spacing: 14) {
                    benchmarkHeader
                        .id(Self.topAnchorID)

                    ForEach(messages.indices, id: \.self) { index in
                        let message = messages[index]

                        benchmarkBlock(
                            message: message,
                            index: index,
                            rendersAsStreaming: false
                        )
                            .id(message.id)
                    }

                    benchmarkBlock(
                        message: ChatMessage(
                            role: "assistant",
                            content: displayedStreamingContent,
                            timestamp: 1_700_000_001 + Double(messages.count),
                            messageId: "\(fixture.id)-streaming-tail"
                        ),
                        index: messages.count,
                        rendersAsStreaming: isStreaming
                    )

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(16)
                .environment(
                    \.chatIsUserInteractingWithScroll,
                    scrollMetrics.isUserInteracting
                )
                .background {
                    ChatScrollObserver(isStreaming: isStreaming) { metrics in
                        scrollMetrics = metrics
                    }
                    .accessibilityHidden(true)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    } label: {
                        Image(systemName: "arrow.up.to.line")
                    }
                    .accessibilityLabel("Scroll to benchmark start")

                    Button {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .accessibilityLabel("Scroll to streaming tail")

                    Button {
                        replayID += 1
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Restart streaming tail")
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Long Chat Lab")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(fixture.id)-\(replayID)") {
            await replayStreamingTail()
        }
    }

    private var messages: [ChatMessage] {
        switch fixture {
        case .shortPlain:
            LongChatLabFixture.shortPlainTextMessages
        case .longMixed:
            LongChatLabFixture.messages
        }
    }

    private var benchmarkHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Long conversation benchmark", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)

            Picker("Fixture", selection: $fixture) {
                ForEach(Fixture.allCases) { fixture in
                    Text(fixture.rawValue).tag(fixture)
                }
            }
            .pickerStyle(.segmented)

            Text("\(LongChatLabFixture.version) · \(messages.count) messages · "
                + (isStreaming ? "streaming" : "settled"))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)

            Text(
                scrollMetrics.isUserInteracting
                    ? "Scrolling: decorative stream animation is simplified."
                    : "Scroll upward while the tail streams; long-press finalized text to select it in place."
            )
            .font(.footnote)
            .foregroundStyle(
                scrollMetrics.isUserInteracting
                    ? Color.orange
                    : Color(.secondaryLabel)
            )

            Text("Record device, OS, Debug build, peak memory, hitch/dropped frames, stream latency, and settle time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func benchmarkBlock(
        message: ChatMessage,
        index: Int,
        rendersAsStreaming: Bool
    ) -> some View {
        ChatTranscriptMessageBlock(
            transcriptMessage: TranscriptMessage(
                loadedIndex: index,
                renderID: message.id,
                anchorID: message.id,
                message: message
            ),
            transcriptBlockSpacing: 10,
            showsThinkingAndToolCards: true,
            reasoningGroups: [],
            toolCallGroups: benchmarkToolCallGroups(
                after: index,
                rendersAsStreaming: rendersAsStreaming
            ),
            liveReasoningText: "",
            reasoningAnchorMessageID: nil,
            liveToolCalls: [],
            toolCallAnchorMessageID: nil,
            streamingAssistantMessageID: rendersAsStreaming ? message.messageId : nil,
            localAttachmentPreviews: nil,
            listeningMessageID: nil,
            isViewingCachedData: false,
            hasActiveStream: isStreaming,
            isRegeneratingMessage: false,
            isEditingMessage: false,
            isForkingMessage: false,
            loadAttachmentImage: { _ in nil },
            loadAttachmentData: { _ in nil },
            loadTranscriptMediaImage: { _ in nil },
            loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: "long-chat-lab",
            actionContext: { message, visibleIndex in
                MessageActionContext(
                    message: message,
                    visibleIndex: visibleIndex,
                    messagesOffset: 0
                )
            },
            shouldRenderMessageRow: { _ in true },
            onPreviewAttachment: { _, _ in },
            onPreviewTranscriptMedia: { _ in },
            onToggleListening: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { context in
                UIPasteboard.general.string = context.copyText
            }
        )
        .equatable()
    }

    private func benchmarkToolCallGroups(
        after index: Int,
        rendersAsStreaming: Bool
    ) -> [ToolCallGroup] {
        guard !rendersAsStreaming,
              fixture == .longMixed,
              LongChatLabFixture.includesToolActivity(after: index) else {
            return []
        }
        return [LongChatLabFixture.toolGroup(after: index)]
    }

    private func replayStreamingTail() async {
        displayedStreamingContent = ""
        isStreaming = true

        let content = switch fixture {
        case .shortPlain:
            LongChatLabFixture.shortPlainStreamingContent
        case .longMixed:
            LongChatLabFixture.streamingContent
        }
        let totalUnits = StreamingWordDrain.unitCount(in: content)
        for revealed in 1...totalUnits {
            try? await Task.sleep(for: .seconds(StreamingLabReplay.tickInterval))
            guard !Task.isCancelled else { return }
            displayedStreamingContent = StreamingLabReplay.prefix(
                of: content,
                unitCount: revealed
            )
        }

        guard !Task.isCancelled else { return }
        isStreaming = false
    }
}

#Preview {
    NavigationStack {
        StreamingLabView()
    }
}

#Preview("Long Chat Lab") {
    NavigationStack {
        LongChatLabView()
    }
}
#endif
