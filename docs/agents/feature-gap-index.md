# Hermes Agent Direct Capability-Gap Index

This is the thin roadmap for migrating the inherited Hermex SwiftUI client from
`hermes-webui` to the direct Hermes Agent API Server.

It records durable product judgment only. Exact paths, payloads, event names,
and handler details are verified just-in-time and belong in the implementation
Issue/PR, not this index.

## Status vocabulary

| Status | Meaning |
| --- | --- |
| `implemented` | Verified direct-server behavior ships in this fork. |
| `in-progress` | A selected Issue owns the current migration slice. |
| `roadmap` | Approved direction, not yet selected/implemented. |
| `post-v1` | Requires separate owner approval after direct chat is stable. |
| `n-a` | Inherited WebUI-only surface with no direct-v1 promise. |

## Priority and safety

- **P0:** required for the first useful direct client.
- **P1:** high-value follow-up after the core loop works.
- **P2:** optional expansion.
- Safety: `read`, `write`, `exec`, `secret`, `privacy`, or `—`.

## Capability roadmap

| Capability | Status | Priority | Safety | Tracking / note |
| --- | --- | :---: | :---: | --- |
| Server URL, bearer auth, health, capabilities | in-progress | P0 | secret | [#1](https://github.com/KiRito02/hermex/issues/1) |
| Session list/create/detail/update/delete/fork/messages | roadmap | P0 | write | Verify advertised session endpoints and pagination first |
| Persisted streaming turn | roadmap | P0 | exec | Choose session chat vs Runs coordination from live evidence |
| Run status/reconnect/stop | roadmap | P0 | exec | Never resend a prompt on reconnect |
| Approval request/response | roadmap | P0 | exec | Capability-gated; preserve explicit human decision |
| Long-chat rendering performance | roadmap | P0 | — | Separate UI issue: lazy/windowed history and batched stream updates |
| Rich model/provider/reasoning options | post-v1 | P1 | secret | `/api/model/options` candidate; separate approval required |
| Jobs | post-v1 | P2 | write | Capability-gated scheduled/background work |
| Skills/toolsets discovery | post-v1 | P2 | read | Read-only discovery first |
| Inline images | post-v1 | P2 | privacy | General file upload is not promised |
| Personal app-only signing/sideload workflow | roadmap | P0 | secret | Disable inherited extensions/App Groups in the personal scheme |
| Workspace/file/Git browser | n-a | — | write | No documented direct-v1 equivalent |
| Hermes Bridge Kanban/Boards | n-a | — | write | WebUI/Bridge-specific |
| WebUI projects/profile cookies/personalities | n-a | — | write | No cookie backend in direct mode |
| WebUI memory/insights panels | n-a | — | read | No direct-v1 promise |

## Just-in-time evidence rule

For a selected direct capability:

1. Record the owner's installed Hermes Agent version or commit.
2. Capture a sanitized live `/v1/capabilities` response.
3. Probe the exact live endpoint with `curl`; never expose `API_SERVER_KEY`.
4. Check the official API Server documentation.
5. Check the matching read-only `.codex-tmp/hermes-agent` source and tests,
   especially `gateway/platforms/api_server.py` and `tests/gateway/`.
6. Record method/path/status/content type, required fields, event vocabulary,
   and upstream commit in the Issue/PR.
7. Do not probe speculative paths or translate a WebUI route by name.

## Implementation rules

1. Read `CURRENT.md` and only the spec sections it names.
2. Work from a selected Issue on `issue/<n>-slug`.
3. Put direct protocol knowledge behind feature-level service/repository seams.
4. Decode unknown/additive fields tolerantly.
5. Add focused request/decode/state tests.
6. On macOS, run focused then full XCTest and launch UI changes. On
   Linux/Windows, commit locally, request push approval, then require green
   macOS CI before review/merge.
7. Update this index only when durable status/scope changes.
8. Update `CURRENT.md` at handoff; do not commit it.

The retired WebUI route watcher is not a direct API compatibility source.
