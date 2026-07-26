# Long-chat benchmark

Use this harness to compare transcript changes on the same signed Debug build,
device, and OS. It is server-free and contains no owner data.

## Launch

From Settings → Developer, open **Long Chat Lab**, or launch the signed app
with:

```sh
xcrun simctl launch <udid> <local-bundle-id> --long-chat-lab
```

The fixture identifier shown in the lab must be `long-chat-v1`. Its selector
provides:

- `Short plain`: four stable plain-text messages and a plain-text streaming tail;
- `200 mixed`: 200 stable user/assistant messages with wrapped prose, lists,
  Swift code blocks, tables, display math, and periodic tool-activity cards;
- a production-cadence streaming tail for each fixture.

For the Companion-native chat surface, distinguish two independent cadences:

- Run SSE deltas are coalesced before publishing Markdown state, with a
  33 ms minimum publication interval and a bounded per-tick character budget;
- the deterministic lab reveals word units every 48 ms so visual fade behavior
  remains directly comparable with earlier baselines.

Neither value caps display refresh. On supported iPhone Pro hardware,
`CADisableMinimumFrameDurationOnPhone` lets SwiftUI/Core Animation render
scrolling and transitions at the system-selected variable refresh rate up to
120 Hz.

## Scenarios

Run each scenario twice after one unrecorded warm-up:

1. Select `Short plain`, follow its streaming tail, and select finalized text.
2. Select `200 mixed`, open at the top, and scroll through the finalized transcript.
3. Jump to the bottom, restart the streaming tail, and follow it to completion.
4. While the tail is streaming, jump to the top and continuously scroll through
   older content for at least ten seconds.
5. Long-press finalized rendered prose and select a partial sentence in place.
6. Select text inside a finalized code block, then use its whole-block copy
   button.
7. Confirm the actively streaming tail does not enter selection mode.
8. Open the visible message-actions menu and verify whole-message copy plus
   role-appropriate edit/listen/regenerate/fork actions.
9. Repeat the finalized-scroll and active-stream scenarios in the Companion
   chat on an iPhone Pro Max and a 13-inch iPad Pro; confirm the iPad sidebar
   remains independently usable and the transcript stays within its readable
   content column.

## Record

| Field | Value |
| --- | --- |
| Fixture | `long-chat-v1` / `Short plain` or `200 mixed` |
| Commit | |
| Device | |
| OS | |
| Build configuration | Debug |
| Message count | |
| Content mix | |
| Run publication cadence | 33 ms minimum; max 192 queued characters per tick |
| Lab animation cadence | 48 ms per word unit |
| Peak memory | |
| Hitch/dropped frames | |
| Stream-to-presentation latency | |
| Time to settle after completion | |
| Direct selection result | |
| Notes | |

Use Instruments on macOS/device for numeric results. On Linux/Windows, validate
the fixture and policy tests locally, then explicitly record that signed
simulator/device measurements remain owed.
