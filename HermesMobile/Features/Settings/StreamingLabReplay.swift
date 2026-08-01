#if DEBUG
import Foundation

/// Pure replay logic for the Streaming Lab (issue #234): a canned markdown
/// fixture plus the pacing math that decides how many word units each tick
/// reveals. Pure so it is unit-testable; the view owns the actual timer.
///
/// Word units come from `StreamingWordDrain`, the same splitter production
/// uses for #212 pacing, so `prefix(of:unitCount:)` can never alter content —
/// the final prefix is exactly the fixture.
enum StreamingLabReplay {
    /// Matches the production word-reveal cadence (one unit per 48ms tick), so
    /// the default lab speed feels like a real
    /// reply and higher speeds reveal several words per tick — the chunky
    /// #212 backlog-catch-up arrival pattern.
    static let tickInterval: TimeInterval = 0.048

    static let defaultWordsPerSecond: Double = 21
    static let minWordsPerSecond: Double = 2
    static let maxWordsPerSecond: Double = 80

    /// Exercises every shape the fade pipeline treats differently: short
    /// paragraphs, one long wrapping paragraph, a heading, a flat bullet
    /// list, a nested list, and a code fence (which reveals unfaded).
    static let fixture = """
    Hermes is a self-hosted agent you carry in your pocket. This first \
    paragraph is short on purpose.

    A second short paragraph follows the first one, so the block boundary \
    between them gets exercised on every single replay.

    # How the fade should feel

    This is the long wrapping paragraph. It keeps going for long enough \
    that the renderer has to wrap it across several lines on an iPhone, \
    because the most important part of the Telegram-style effect is how a \
    word drops to the start of the next line while it is still invisible \
    and then fades up in place, with the gradient sweeping smoothly across \
    the whole width of the bubble instead of popping line by line.

    - First flat bullet about pacing
    - Second flat bullet about the gradient width
    - Third flat bullet about absorption

    1. Ordered parent item
       - Nested child that must stay inside its parent block
       - Second nested child to stretch the nested case
    2. Second ordered parent item

    ```swift
    // Code fences reveal instantly, with no fade.
    let knobs = StreamingTextFadeDefaults.self
    ```

    A closing paragraph after the fence, so the replay always ends on \
    fadeable text and the completion linger is visible at the very end.
    """

    static var fixtureUnitCount: Int {
        StreamingWordDrain.unitCount(in: fixture)
    }

    /// First `unitCount` word units of `text`.
    static func prefix(of text: String, unitCount: Int) -> String {
        StreamingWordDrain.splitAtUnitBoundary(text, unitCount: unitCount).head
    }

    /// One tick of replay progress. `carry` accumulates the fractional unit
    /// budget so slow speeds still advance (every tick banks
    /// `tickInterval * wordsPerSecond` units and reveals the whole ones),
    /// and a mid-replay speed change simply changes the next tick's deposit.
    static func advance(
        revealed: Int,
        carry: Double,
        wordsPerSecond: Double,
        tickInterval: TimeInterval = tickInterval
    ) -> (revealed: Int, carry: Double) {
        let budget = max(0, carry) + max(0, wordsPerSecond) * max(0, tickInterval)
        let wholeUnits = Int(budget)
        return (revealed + wholeUnits, budget - Double(wholeUnits))
    }
}

/// Deterministic 200-message fixture for the long-conversation lab required by
/// PROJECT_SPEC §7.3. It deliberately mixes the expensive presentation shapes
/// while keeping stable IDs and timestamps so Instruments runs are comparable.
enum LongChatLabFixture {
    static let version = "long-chat-v1"
    static let messageCount = 200

    static let shortPlainTextMessages: [ChatMessage] = [
        ChatMessage(
            role: "user",
            content: "Give me a short status update.",
            timestamp: 1_699_999_996,
            messageId: "short-plain-0"
        ),
        ChatMessage(
            role: "assistant",
            content: "The connection is healthy and the current run is still active.",
            timestamp: 1_699_999_997,
            messageId: "short-plain-1"
        ),
        ChatMessage(
            role: "user",
            content: "What should I check next?",
            timestamp: 1_699_999_998,
            messageId: "short-plain-2"
        ),
        ChatMessage(
            role: "assistant",
            content: "Review the latest event, then verify that stopping the run leaves the session usable.",
            timestamp: 1_699_999_999,
            messageId: "short-plain-3"
        )
    ]

    static let shortPlainStreamingContent = """
    This is a short plain-text streaming response. It contains no heading, \
    code, table, math, or tool card.
    """

    static let messages: [ChatMessage] = (0..<messageCount).map { index in
        ChatMessage(
            role: index.isMultiple(of: 2) ? "user" : "assistant",
            content: content(at: index),
            timestamp: 1_700_000_000 + Double(index),
            messageId: "long-chat-\(index)"
        )
    }

    static let streamingContent = """
    ## Live benchmark tail

    This response keeps streaming while you scroll upward through the two \
    hundred finalized messages. The presentation pipeline should keep the \
    transcript responsive, suspend decorative glyph animation during direct \
    manipulation, preserve the reader's position, and resume a bounded fade \
    only after scrolling stops.

    ```swift
    let mountedRows = "lazy"
    let selection = "finalized messages only"
    ```

    | Check | Expected |
    | --- | --- |
    | Scroll | Responsive |
    | Selection | Direct |
    | Tail | Still streaming |
    """

    static func includesToolActivity(after index: Int) -> Bool {
        index >= 0 && (index + 1).isMultiple(of: 20)
    }

    static func includesReasoning(after index: Int) -> Bool {
        index >= 0 && (index + 1).isMultiple(of: 24)
    }

    static func reasoningGroup(after index: Int) -> ReasoningGroup {
        ReasoningGroup(
            id: "long-chat-reasoning-\(index)",
            anchorMessageID: "long-chat-\(index)",
            text: """
            Compare the current row identity, mounted transcript window, and \
            streaming publication cadence before presenting benchmark turn \
            \(index / 2 + 1).
            """
        )
    }

    static func toolGroup(after index: Int) -> ToolCallGroup {
        ToolCallGroup(
            id: "long-chat-tools-\(index)",
            anchorMessageID: "long-chat-\(index)",
            toolCalls: [
                ToolCall(
                    id: "long-chat-tool-\(index)",
                    name: "workspace_read",
                    preview: "Inspected benchmark fixture \(index)",
                    args: ["path": .string("Sources/Fixture\(index).swift")],
                    duration: 0.12,
                    isError: false,
                    isCompleted: true,
                    startedAt: 1_700_000_000 + Double(index)
                )
            ]
        )
    }

    private static func content(at index: Int) -> String {
        if index.isMultiple(of: 2) {
            return "Review benchmark turn \(index / 2 + 1) and keep the current scroll position."
        }

        switch (index / 2) % 5 {
        case 0:
            return """
            ### Summary \(index)

            The finalized assistant response stays directly selectable in the
            transcript. It contains enough prose to wrap across several lines
            on iPhone while remaining comfortable to scan on iPad.
            """
        case 1:
            return """
            ### Checklist \(index)

            - Preserve stable message identity
            - Mount older rows lazily
            - Keep selection in the rendered response
              - Avoid a raw Markdown modal
              - Keep whole-message copy in the actions menu
            """
        case 2:
            return """
            ```swift
            struct BenchmarkRow: Identifiable {
                let id = "row-\(index)"
                let body = "finalized"
            }
            ```
            """
        case 3:
            return """
            | Metric | Sample |
            | --- | ---: |
            | Message | \(index) |
            | Page size | 50 |
            | Fixture size | \(messageCount) |
            """
        default:
            return """
            The display equation for turn \(index) is:

            $$
            T_{render} = T_{layout} + T_{markdown} + T_{animation}
            $$

            Text after math confirms that mixed segment layout remains stable.
            """
        }
    }
}
#endif
