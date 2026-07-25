# Hermex Companion Capability Roadmap

This is the thin roadmap for migrating the inherited Hermex SwiftUI client from
`hermes-webui` to the self-hosted Companion and loopback Gateway architecture.

It records durable product judgment only. Exact paths, payloads, event names,
and handler details are verified just-in-time and belong in the implementation
Issue/PR, not this index.

## Status vocabulary

| Status | Meaning |
| --- | --- |
| `implemented` | Verified Companion/Gateway behavior ships in this fork. |
| `in-progress` | A selected Issue owns the current migration slice. |
| `roadmap` | Approved direction, not yet selected/implemented. |
| `post-v1` | Requires separate owner approval after Companion v1. |
| `n-a` | Inherited surface with no Companion-v1 promise. |

## Priority and safety

- **P0:** required for the first useful Companion client.
- **P1:** high-value follow-up after the core loop works.
- **P2:** optional expansion.
- Safety: `read`, `write`, `exec`, `secret`, `privacy`, or `—`.

## Capability roadmap

| Capability | Status | Priority | Safety | Tracking / note |
| --- | --- | :---: | :---: | --- |
| Companion pairing, device auth, health, capabilities | in-progress | P0 | secret | [#1](https://github.com/KiRito02/hermex/issues/1) |
| Loopback Gateway proxy and capability merge | roadmap | P0 | secret | Preserve Gateway identity and SSE semantics |
| Session list/create/detail/update/delete/fork/messages | roadmap | P0 | write | Verify advertised session endpoints and pagination first |
| Persisted streaming turn | roadmap | P0 | exec | Choose session chat vs Runs coordination from live evidence |
| Run status/reconnect/stop | roadmap | P0 | exec | Never resend a prompt on reconnect |
| Approval request/response | roadmap | P0 | exec | Capability-gated; preserve explicit human decision |
| Progressive streaming + long-chat benchmark | roadmap | P0 | — | Windowed history and bounded presentation cadence |
| Rich model/provider/reasoning options | roadmap | P1 | secret | Capability-gated Gateway surface |
| Jobs | roadmap | P1 | write | Capability-gated scheduled/background work |
| Skills/toolsets discovery | roadmap | P1 | read | Read-only in Companion v1 |
| Inline images | roadmap | P1 | privacy | Verified Gateway multimodal input |
| Adaptive iPhone/iPad layout | roadmap | P1 | — | Navigation, composer, sheets, transcript |
| Allowed-root file browse/preview/download | roadmap | P1 | privacy | Companion-native; no arbitrary filesystem |
| Streaming upload + turn availability | roadmap | P1 | write | Bounded, cancelable, atomic |
| Built-in Memory management | roadmap | P1 | privacy | `MEMORY.md`/`USER.md`, locking and stale-write defense |
| Personal app-only signing/sideload workflow | roadmap | P0 | secret | Disable inherited extensions/App Groups in the personal scheme |
| Arbitrary file delete/terminal/Git mutation | n-a | — | exec | Outside Companion v1 |
| Hermes Bridge Kanban/Boards | n-a | — | write | WebUI/Bridge-specific |
| WebUI projects/profile cookies/personalities | n-a | — | write | No cookie backend |
| External Memory-provider administration | post-v1 | — | privacy | Requires named provider adapter |
| Hosted account/relay | n-a | — | privacy | Zero-control-plane product decision |

## Just-in-time evidence rule

For a selected capability:

1. Verify the versioned Companion contract/tests.
2. Probe the owner's Companion and capture sanitized capability evidence.
3. For proxied behavior, record Hermes Agent version/commit and sanitized
   `/v1/capabilities`.
4. Probe the local Gateway only from NAS; never expose `API_SERVER_KEY`.
5. Check official API Server documentation and the matching read-only source,
   especially `gateway/platforms/api_server.py` and `tests/gateway/`.
6. Record method/path/status/content type, required fields, event vocabulary,
   and upstream commit in the Issue/PR.
7. Do not translate a WebUI, Dashboard, or HermesPilot Link route by name.

## Implementation rules

1. Read `CURRENT.md` and only the spec sections it names.
2. Work from a selected Issue on `issue/<n>-slug`.
3. Put Companion/Gateway protocol knowledge behind feature-level
   service/repository seams.
4. Decode unknown/additive fields tolerantly.
5. Add focused request/decode/state tests.
6. On macOS, run focused then full XCTest and launch UI changes. On
   Linux/Windows, commit locally, request push approval, then require green
   macOS CI before review/merge.
7. Update this index only when durable status/scope changes.
8. Update `CURRENT.md` at handoff; do not commit it.

The retired WebUI route watcher is not a Companion compatibility source.
