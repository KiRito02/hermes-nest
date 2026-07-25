# Hermex Direct — iOS App Project Specification

**Status:** source of truth for the `KiRito02/hermex` fork  
**Target:** native iOS client for the self-hosted Hermes Agent API Server  
**Distribution:** personal sideload first; no App Store or TestFlight requirement

---

## 0. How to use this document

This specification replaces the inherited `hermes-webui` product contract for
this fork. The existing SwiftUI application is the implementation starting
point, but inherited WebUI behavior is not automatically a product requirement.

Before implementing an API call:

1. Probe the owner's running Hermes Agent API Server when connection details are
   available. Its wire response is the final arbiter.
2. Check the current official Hermes Agent API Server documentation.
3. Check the matching Hermes Agent source and tests at a recorded commit.
4. Treat `/v1/capabilities` as the runtime compatibility boundary.

Never infer an endpoint or payload from the old WebUI client. Unknown JSON fields
and unknown SSE event types must be tolerated.

---

## 1. Product definition

### 1.1 What we are building

Hermex Direct is a native SwiftUI iPhone application that remotely controls a
Hermes Agent running on the owner's NAS. It connects directly to the API Server
started by `hermes gateway`; `hermes-webui` is not required.

The phone is the interaction and review surface. The NAS remains the execution
plane and owns agent processes, tools, memory, skills, sessions, and scheduled
work.

### 1.2 Why this fork exists

The inherited Hermex UI is substantially better than a generic OpenAI chat
client for agent work, but its networking layer is coupled to `hermes-webui`.
This fork combines:

- the existing native Hermex layout and agent-oriented message UI;
- direct bearer-authenticated access to Hermes Agent API Server;
- capability-gated support for the core session/run/approval flow;
- a dedicated performance pass for long, Markdown-heavy conversations;
- a personal sideload workflow that does not require App Store publication.

### 1.3 What it is not

- Not a WebView wrapper.
- Not a hosted relay or account service.
- Not a copy of Hermes Agent running on iOS.
- Not dependent on `hermes-webui`.
- Not required to preserve WebUI-only Kanban, workspace, upload, profile-cookie,
  memory-file, or analytics endpoints.
- Not an App Store or TestFlight deliverable in the initial fork.

### 1.4 Initial user

The initial user is the fork owner. Multi-user account management, public
distribution, telemetry, crash reporting, and App Store review work are out of
scope until explicitly approved.

---

## 2. Decisions

| Decision | Value |
| --- | --- |
| UI platform | Native SwiftUI, iOS 18+, iPhone first |
| Server | Hermes Agent API Server started by `hermes gateway` |
| Default server port | `8642` |
| Authentication | Required bearer token from `API_SERVER_KEY` |
| Secret storage | iOS Keychain; never `UserDefaults`, logs, fixtures, or git |
| Compatibility | Runtime discovery through `GET /v1/capabilities` |
| Conversation storage | Server-owned sessions; local cache is read-only/offline support |
| Streaming | SSE over `URLSession`/existing LDSwiftEventSource dependency |
| Transport | HTTPS reverse proxy/tunnel or private Tailscale access |
| Dependencies | Keep the exhaustive locked list in §2.1; add none without approval |
| Distribution | Personal sideload first |
| App identity | Owner-specific values supplied through local signing configuration |
| Legacy WebUI backend | Unsupported by the direct-v1 contract |
| Performance work | Separate track from API migration |

### 2.1 Locked third-party dependencies

These are the complete direct Swift Package dependencies currently authorized
for the app. Versions are minimums with the existing up-to-next-major
requirements in the Xcode project.

| Package | Minimum version | Purpose |
| --- | --- | --- |
| LaunchDarkly `swift-eventsource` / `LDSwiftEventSource` | 3.3.0 | SSE transport |
| `swift-markdown-ui` / `MarkdownUI` | 2.4.1 | Markdown rendering |
| `Splash` | 0.16.0 | Syntax highlighting support |
| `Highlightr` | 2.3.0 | Syntax highlighting |
| `KeychainAccess` | 4.2.2 | Keychain storage |
| `SwiftMath` | 1.7.3 | Math rendering |

Transitive packages do not become independently approved direct dependencies.
Any addition or replacement requires owner approval and an update to this
table.

---

## 3. Architecture

```text
┌──────────────────────────────┐      HTTPS REST + SSE
│ Hermex Direct on iPhone      │ ─────────────────────────────┐
│                              │                              │
│ SwiftUI views                │                              ▼
│ feature-level repositories   │                 ┌────────────────────────┐
│ API client + SSE client      │                 │ Tunnel / reverse proxy │
│ Keychain bearer credential   │                 │ or Tailscale           │
│ SwiftData read-only cache    │                 └────────────┬───────────┘
└──────────────────────────────┘                              │
                                                            ▼
                                               ┌──────────────────────────┐
                                               │ Hermes Agent API Server  │
                                               │ hermes gateway :8642     │
                                               │ sessions / runs / jobs   │
                                               └──────────────────────────┘
```

### 3.1 Backend seams

Views must not construct paths or decode wire payloads. Networking is split by
user capability rather than by one giant backend protocol:

- `ServerConnectionService`: health, bearer authentication, capabilities.
- `SessionRepository`: list/create/read/update/delete/fork/messages.
- `ConversationRunService`: start/stream/status/stop/approval.
- `ModelCatalogService`: OpenAI-compatible models and rich Hermes options.
- Optional capability services: jobs, skills, and toolsets.

The existing UI may continue to use concrete types during migration, but new
direct-API code must enter through these feature boundaries. This permits
WebUI-only features to remain disabled without contaminating core chat.

### 3.2 Capability gating

After a successful health check, the app requests `/v1/capabilities` with the
bearer token and stores a tolerant capability snapshot for the configured
server.

- Core UI requires the capabilities needed by the current migration stage.
- Optional destinations are shown only when their endpoint/feature is
  advertised.
- A missing optional capability disables only that feature.
- Unknown capability fields are ignored.
- A server that is healthy but incompatible gets a distinct error from invalid
  credentials or network failure.
- The app must not probe speculative paths to guess support.

### 3.3 UI preservation boundary

The backend migration is behavior-preserving for supported surfaces. Except for
the intentional password-to-API-key onboarding change and hiding unsupported
WebUI-only destinations, retain the inherited:

- Sessions → Chat navigation hierarchy.
- Compact composer layout and normal text-send interaction.
- User/assistant message presentation.
- Markdown, code, math, reasoning, and tool-card presentation.
- Stop, scroll-to-bottom, offline-cache, theme, Dynamic Type, and VoiceOver
  affordances where the direct protocol can support them.

Review each migrated UI slice against `master` with matched fixtures. A visual
redesign, navigation rewrite, or removal of a supported interaction is separate
scope requiring owner approval.

---

## 4. Direct API contract

The paths in this section are documented candidates from the current official
Hermes Agent API Server documentation. They are not yet a compatibility claim
for the owner's installed server. Each implementation issue must confirm the
installed version/commit, sanitized `/v1/capabilities`, and exact live wire
shape before relying on a path or payload.

Base URL examples:

- LAN/private proxy: `https://hermes.example.com`
- Tailscale with valid TLS: `https://nas-name.tailnet-name.ts.net`
- Simulator-only local development: `http://127.0.0.1:8642`

All authenticated calls send:

```http
Authorization: Bearer <API_SERVER_KEY>
```

The bearer value must be redacted from request descriptions, errors, analytics,
screenshots, and debug logs.

### 4.1 Connection and discovery

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Cheap liveness check; documented response includes `{"status":"ok"}` |
| GET | `/health/detailed` | Authenticated bounded readiness details |
| GET | `/v1/capabilities` | Stable, machine-readable feature and endpoint discovery |
| GET | `/v1/models` | OpenAI-compatible model aliases |
| GET | `/api/model/options` | Rich Hermes provider/model/reasoning metadata |

`/health` success alone does not authenticate the client. Onboarding completes
only after an authenticated capability request succeeds.

### 4.2 Sessions

The direct session-control surface is:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/sessions` | Paginated session list |
| POST | `/api/sessions` | Create an empty session |
| GET | `/api/sessions/{id}` | Session metadata |
| PATCH | `/api/sessions/{id}` | Update supported metadata |
| DELETE | `/api/sessions/{id}` | Delete a session |
| GET | `/api/sessions/{id}/messages` | Message history |
| POST | `/api/sessions/{id}/fork` | Fork through SessionDB lineage |
| POST | `/api/sessions/{id}/chat` | One synchronous turn |
| POST | `/api/sessions/{id}/chat/stream` | One persisted SSE turn |

List pagination (`limit`, `offset`, `source`, `include_children`) and response
shapes must be verified against the owner's server before model code is merged.

### 4.3 Runs and human control

The long-running control surface is:

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/v1/runs` | Start a run and receive `run_id` |
| GET | `/v1/runs/{run_id}` | Poll lifecycle state and reconcile after reconnect |
| GET | `/v1/runs/{run_id}/events` | Structured SSE lifecycle stream |
| POST | `/v1/runs/{run_id}/stop` | Request safe interruption |
| POST | `/v1/runs/{run_id}/approval` | Resolve a pending approval |

The exact relationship between persisted session chat and the Runs API must be
verified on the owner's installed Hermes Agent version before choosing the
production turn coordinator. Until then, UI state must not assume that
`session_id` correlation alone guarantees message persistence.

### 4.4 Streaming rules

The direct server can emit event families such as assistant/message deltas,
reasoning, tool started/completed, approval requests, run completed/failed, and
stream termination.

The client must:

- parse the SSE `event:` field and JSON `data:` independently;
- ignore comment/keepalive lines beginning with `:`;
- ignore unknown event types without ending the run;
- keep stable tool-call identity when updating a tool card;
- coalesce presentation updates rather than publishing every token to SwiftUI;
- finalize from authoritative terminal/status data when available;
- never resend the user's prompt automatically after a disconnect;
- reconnect or poll status using the existing `run_id`;
- distinguish completed, failed, cancelled, stopping, and transport-disconnected
  states.

Exact event names and payloads are locked per implementation issue using live
server evidence, official documentation, and matching upstream tests.

### 4.5 Optional direct surfaces

These may be added only when advertised by capabilities and verified:

| Surface | Documented paths |
| --- | --- |
| Jobs | `/api/jobs` and job detail/update/delete/pause/resume/run routes |
| Skills | `GET /v1/skills` |
| Toolsets | `GET /v1/toolsets` |

### 4.6 Explicitly unsupported in direct v1

The following inherited features depend on Hermes Bridge/WebUI endpoints that
the direct API does not currently advertise:

- general workspace tree, raw file browser, git mutations, and file export;
- general document/file upload; inline images may be supported separately;
- WebUI projects, pin/archive actions, profile cookies, personalities, memory
  file browser, usage dashboard, and bridge slash-command metadata;
- Hermes Bridge Kanban/Boards;
- WebUI approval/clarify side streams;
- cookie login, logout, CSRF handling, and WebUI version checks.

Existing code for these features may remain during migration, but direct mode
must hide or clearly mark unavailable features. It must never call an old route
against the Agent API Server.

---

## 5. Security and networking

### 5.1 NAS configuration

Minimum server configuration:

```dotenv
API_SERVER_ENABLED=true
API_SERVER_KEY=<long-random-secret>
```

Start with:

```bash
hermes gateway
```

The default listener is `127.0.0.1:8642`. Prefer keeping it on loopback and
placing an authenticated TLS tunnel or reverse proxy in front. If binding more
broadly for a private network, retain the bearer key and firewall the port.

### 5.2 Remote transport

Preferred options:

1. HTTPS through a reverse proxy or Cloudflare Tunnel.
2. Tailscale with HTTPS via a tailnet certificate or Tailscale Serve.

A blanket iOS App Transport Security exception is not part of the release
configuration. Simulator-only HTTP may use a narrowly scoped debug setting.

### 5.3 Credential handling

- Store server URL and bearer key in Keychain.
- Do not persist the key in SwiftData.
- Do not include it in `URL`, query strings, crash text, or logs.
- Clear credentials when the user reconfigures the server.
- Treat `401` and `403` as authentication/authorization failures without
  deleting offline cached transcripts automatically.
- Self-signed TLS trust is a separate transport decision; v1 prefers a
  system-trusted certificate rather than disabling certificate validation.

---

## 6. Personal sideload configuration

Initial distribution is owner-only sideloading from Windows.

### 6.1 Build configuration

Add a dedicated personal-sideload configuration/scheme during implementation:

- app-only target first;
- owner-specific bundle ID and Apple Team ID supplied through
  `Config/Local.xcconfig`;
- `Config/Local.xcconfig` remains gitignored;
- inherited Share Extension, widget/Live Activity, and App Group capabilities
  are disabled unless the owner's signing profile supports them;
- no upstream maintainer certificate, Team ID, or App Store Connect access is
  required.

### 6.2 Linux/Windows workflow

- Linux/NAS can host the repository, run source-level checks, and drive GitHub.
- A macOS GitHub Actions runner performs Xcode build/test validation.
- CI may package an unsigned sideload artifact where appropriate.
- AltStore/SideStore on Windows performs owner-device signing and installation.
- Free Apple ID provisioning limits and periodic re-signing are accepted for
  the personal-v1 phase.

App Store and TestFlight preparation require a separate explicit decision.

---

## 7. Chat performance requirements

Performance remediation is intentionally independent from direct API migration.
Backend correctness must not be judged from scroll smoothness, and UI
optimization must not silently change protocol behavior.

### 7.1 Known risks in the inherited client

- The main transcript uses a non-lazy `VStack`.
- Markdown, syntax highlighting, tables, math, tool cards, and selectable text
  are expensive in long histories.
- Streaming publishes frequent text changes and applies word/fade animation.
- Scroll offset/content-size observers can cause repeated SwiftUI state writes.
- Nested horizontal code-block scrolling can compete with vertical gestures.

### 7.2 Required remediation

- Use lazy or explicitly windowed transcript rendering.
- Page older messages; do not lay out the entire server history by default.
- Batch streaming deltas before publishing to the view.
- Disable per-token animation and text selection while a message is streaming.
- Preserve stable message/tool identities so existing rows do not rebuild.
- Cache or precompute expensive finalized-message presentation data where
  practical.
- Threshold/debounce scroll geometry updates.
- Keep auto-scroll suspended while the user is reading older content.
- Profile changes with Instruments on macOS/device when available.

### 7.3 Acceptance scenarios

The performance issue must include reproducible fixtures for:

- a short plain-text conversation;
- at least 200 mixed messages;
- Markdown with multiple code blocks, a table, math, and tool activity;
- an actively streaming long response;
- scrolling upward while streaming continues.

Success means no correctness regression, bounded memory growth, and visibly
responsive scrolling on the selected iPhone test target. Numeric frame-time
targets are recorded only after a baseline can be measured on macOS/device.

---

## 8. Migration plan

Each slice gets one GitHub Issue, one `issue/<n>-...` branch, tests, and a PR.
Do not implement all phases at once.

### Phase A — specification and evidence

Tracking issue: https://github.com/KiRito02/hermex/issues/2

- [x] Confirm direct Hermes Agent API Server as the product backend.
- [x] Replace the inherited WebUI product contract with this specification.
- [x] Align `AGENTS.md` API evidence routing after owner approval.
- [ ] Record the owner's Hermes Agent version/commit and live capability
  response without storing secrets.

### Phase B — direct connection foundation

Tracking issue: https://github.com/KiRito02/hermex/issues/1

- [ ] Introduce tolerant capability/auth models.
- [ ] Send bearer authentication from the central API client.
- [ ] Replace password/cookie onboarding with server URL + API key.
- [ ] Validate `/health` and `/v1/capabilities`.
- [ ] Store URL/key in Keychain and redact errors/logs.
- [ ] Hide all migrated-but-unsupported feature entry points.

This is the first implementation issue.

### Phase C — direct sessions

- [ ] List and page `/api/sessions`.
- [ ] Create, read, update, delete, and fork supported sessions.
- [ ] Load paginated message history.
- [ ] Map direct wire models to stable app-domain models.
- [ ] Preserve read-only offline cache behavior.

### Phase D — direct streaming and control

- [ ] Select the verified session-chat/run coordination strategy.
- [ ] Stream assistant, reasoning, and tool lifecycle events.
- [ ] Stop, status-poll, and reconnect without resending.
- [ ] Surface approval requests and responses when supported.
- [ ] Reconcile final messages with server-authoritative state.

### Phase E — optional post-v1 capabilities

This phase is future scope and requires separate owner approval after direct-v1
chat is stable.

- [ ] Rich model/provider/reasoning picker.
- [ ] Jobs.
- [ ] Skills and toolsets.
- [ ] Inline image input if verified and desired.

### Phase F — long-chat performance

- [ ] Establish fixtures/baseline.
- [ ] Lazy/windowed transcript.
- [ ] Batched stream rendering.
- [ ] Reduce heavy Markdown and scroll-observer work.
- [ ] Verify correctness and responsiveness.

### Phase G — personal sideload

- [ ] Add personal signing configuration and app-only scheme.
- [ ] Add macOS CI build/test and sideload artifact workflow.
- [ ] Document Windows AltStore/SideStore installation.
- [ ] Verify on the owner's iPhone/iPad-compatible layout as applicable.

---

## 9. Testing and validation

### 9.1 Unit tests

- URL/path and authorization-header construction.
- Keychain lifecycle without logging secrets.
- Capability decoding with missing/unknown fields.
- Session and message tolerant decoding.
- SSE framing, unknown events, comments, split frames, and malformed data.
- Run state transitions, reconnect, stop, and approval handling.
- Stream batching and transcript identity stability.

### 9.2 Contract tests

Contract tests target a pinned Hermes Agent commit/version and cover only
advertised endpoints. They must never require the owner's secret in public CI.

When live credentials are available locally:

- capture sanitized request/response fixtures;
- record server version/commit and `/v1/capabilities`;
- compare exact method, path, status, content type, and required fields;
- never commit bearer tokens, private hostnames, filesystem paths, or prompts.

### 9.3 Xcode validation

Green full-suite macOS CI is required before review of code-affecting changes.
Because the primary development machines are Linux/Windows, the handoff may
explicitly carry signed simulator/device validation as owed. For UI changes,
signed simulator launch is required before merge or final acceptance when
applicable; the work must not be described as fully UI-validated until that
check occurs. Physical-device checks are required for sideload signing,
Keychain entitlements, performance, microphone, and background behavior.

For each migrated supported screen, manual validation compares the same
fixture/state on `master` and the direct branch. Expected differences are
limited to direct authentication/capability wording and explicitly unsupported
destinations.

---

## 10. Definition of done for direct v1

Direct v1 is complete when the owner can sideload the app and:

- configure a NAS URL and API key;
- pass liveness, authentication, and capability checks;
- list/create/open supported Hermes sessions;
- load conversation history;
- send a turn and watch assistant/tool/reasoning progress;
- recover status after transient disconnect without duplicate submission;
- stop a run and answer an approval when advertised;
- use the app without any `hermes-webui` process;
- retain the inherited Sessions/Chat navigation, compact composer, and
  message/Markdown/reasoning/tool-card presentation for supported behavior;
- scroll a long mixed-content conversation responsively;
- understand which optional legacy features are unavailable;
- rebuild and reinstall through the documented Linux/Windows/macOS-CI
  sideload workflow.

No App Store listing, TestFlight build, public account system, telemetry, or
WebUI compatibility is required.

---

## 11. Open questions

Stop and ask before implementing a choice that depends on one of these:

1. Owner-specific bundle ID and Apple Team ID for the sideload configuration.
2. The exact Hermes Agent version/commit running on the NAS.
3. The sanitized live `/v1/capabilities` response from that server.
4. Whether the owner's public transport will use Cloudflare, Tailscale HTTPS,
   or another reverse proxy.
5. Whether persisted session chat or Runs API is the primary turn transport
   after live verification.
6. Whether any WebUI-only feature should later be rebuilt against a new direct
   API rather than simply removed.

---

## 12. References

- Hermes Agent repository:
  https://github.com/NousResearch/hermes-agent
- Official Hermes Agent API Server documentation:
  https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server
- Hermes Agent API server source:
  https://github.com/NousResearch/hermes-agent/blob/main/gateway/platforms/api_server.py
- Cloudflare Tunnel:
  https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
- Tailscale:
  https://tailscale.com/
- AltStore:
  https://altstore.io/
- Existing locked SSE dependency:
  https://github.com/launchdarkly/swift-eventsource
