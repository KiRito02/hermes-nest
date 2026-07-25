# Hermex Direct — iOS App + NAS Companion Project Specification

**Status:** source of truth for the `KiRito02/hermex` fork
**Target:** native iOS client for a self-hosted NAS Companion that uses the
local Hermes Agent API Server
**Distribution:** personal sideload first; no App Store or TestFlight requirement

---

## 0. How to use this document

This specification replaces both the inherited `hermes-webui` product contract
and the superseded direct-App-to-Gateway draft for this fork. The existing
SwiftUI application is the implementation starting point, but inherited WebUI
behavior is not automatically a product requirement.

Before implementing an App-facing call:

1. Check the versioned Hermex Companion contract and matching tests.
2. Probe the owner's running Companion when connection details are available.
   Its App-facing wire response is the final arbiter.
3. For a proxied Gateway behavior, probe the local Gateway, check the official
   Hermes Agent API Server documentation, then check matching upstream source
   and tests at a recorded commit.
4. Treat the Companion capability document, which includes a sanitized Gateway
   capability snapshot, as the App's runtime compatibility boundary.

Never infer a Companion endpoint or payload from the old WebUI client,
HermesPilot Link, or an upstream Dashboard route. Exact Companion-native paths
and payloads are locked in their implementation issues. Unknown JSON fields and
unknown SSE event types must be tolerated.

---

## 1. Product definition

### 1.1 What we are building

Hermex Direct is a native SwiftUI iPhone and iPad application plus a small
self-hosted Companion running on the owner's NAS. The App connects only to the
Companion. The Companion connects over loopback to the API Server started by
`hermes gateway`, transparently carries supported Gateway REST/SSE behavior,
and supplies restricted file, upload, and built-in Memory management that the
Gateway does not expose.

The phone is the interaction and review surface. The NAS remains the execution
plane and owns agent processes, tools, memory, skills, sessions, and scheduled
work. No vendor account, hosted relay, or third-party control plane is required.

### 1.2 Why this fork exists

The inherited Hermex UI is substantially better than a generic OpenAI chat
client for agent work, but its networking layer is coupled to `hermes-webui`.
This fork combines:

- the existing native Hermex layout and agent-oriented message UI;
- a self-hosted, single-endpoint Companion with per-device authentication;
- loopback-only access from the Companion to Hermes Agent API Server;
- capability-gated support for the core session/run/approval flow;
- Jobs, Skills/Toolsets, model selection, inline images, restricted files,
  upload, and built-in Memory management in the first-release roadmap;
- a dedicated performance pass for long, Markdown-heavy conversations;
- adaptive iPhone/iPad presentation;
- a personal sideload workflow that does not require App Store publication.

### 1.3 What it is not

- Not a WebView wrapper.
- Not a hosted relay or account service.
- Not a copy of Hermes Agent running on iOS.
- Not dependent on `hermes-webui`.
- Not a general NAS administration API, arbitrary filesystem browser, SSH/SFTP
  client, terminal, or Git mutation service.
- Not required to preserve WebUI-only Kanban, projects, profile cookies,
  personalities, analytics, or private route shapes.
- Not an App Store or TestFlight deliverable in the initial fork.

### 1.4 Initial user

The initial user is the fork owner. Multi-user account management, public
distribution, telemetry, crash reporting, and App Store review work are out of
scope until explicitly approved.

---

## 2. Decisions

| Decision | Value |
| --- | --- |
| UI platform | Native SwiftUI, iOS 18+, adaptive iPhone and iPad |
| App server | Self-hosted Hermex Companion on the owner's NAS |
| Agent upstream | Hermes Agent API Server on Companion-local loopback |
| App authentication | Revocable per-device Companion credential |
| Gateway authentication | `API_SERVER_KEY`, stored only on the NAS |
| Secret storage | App device credential in Keychain; NAS secrets outside git/logs |
| Compatibility | Companion capabilities merged with sanitized Gateway capabilities |
| Conversation storage | Server-owned sessions; local cache is read-only/offline support |
| Streaming | SSE over `URLSession`/existing LDSwiftEventSource dependency |
| Transport | HTTPS reverse proxy/tunnel or private Tailscale access to Companion |
| Dependencies | Keep the exhaustive locked lists in §§2.1–2.2; add none without approval |
| Distribution | Personal sideload first |
| App identity | Owner-specific values supplied through local signing configuration |
| Hosted control plane | None |
| Legacy WebUI backend | Unsupported by the Companion-v1 contract |
| Performance work | Separate track from protocol migration |

### 2.1 Locked third-party dependencies

These are the complete Swift Package dependencies currently authorized for the
App. Versions are minimums with the existing up-to-next-major requirements in
the Xcode project.

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

### 2.2 Locked Companion runtime, packaging, and deployment

The owner approved this Companion baseline on 2026-07-25:

| Component | Approved value | Purpose |
| --- | --- | --- |
| Runtime | Python 3.11 | NAS-hosted Companion process |
| Direct runtime dependency | `aiohttp==3.13.3` | HTTP server/client and streaming transport |
| Persistent store | SQLite through Python standard-library `sqlite3` | Device, pairing, revocation, and schema-version state |
| Package layout | `Companion/pyproject.toml` plus `src/hermex_companion/` | PEP 621 repository package |
| Locking/environment | `uv.lock`; `uv sync --frozen` creates `Companion/.venv` | Reproducible isolation from system Python and Hermes Agent |
| Deployment | XDG user directories plus a repository systemd unit template | Restart-safe direct NAS deployment without Docker |

`aiohttp` is the only approved direct third-party runtime dependency. Adding
another direct runtime or test dependency requires separate approval. The
Companion must not reuse the Hermes Agent virtual environment.

The deployment layout is:

- configuration under `$XDG_CONFIG_HOME/hermex-companion/`, including an
  owner-only environment file;
- SQLite and mutable state under `$XDG_STATE_HOME/hermex-companion/`;
- installed releases under `$XDG_DATA_HOME/hermex-companion/`, with a
  replaceable `current` release pointer;
- a versioned systemd unit template in the repository, rendered with the
  configured service user/group and XDG paths during installation;
- service user/group supplied through owner-local deployment configuration,
  never hardcoded into tracked files;
- loopback binding by default;
- `Restart=on-failure`;
- ordering after network/Gateway startup without requiring the Gateway service,
  so Companion can remain reachable and report a degraded state when Gateway
  is unavailable.

Owner-specific paths, credentials, rendered service configuration, the
Companion database, and virtual environments remain outside git.

---

## 3. Architecture

```text
┌──────────────────────────────┐      HTTPS REST + SSE
│ Hermex Direct on iPhone/iPad │ ─────────────────────────────┐
│ SwiftUI + feature interfaces │                              │
│ device credential in Keychain│                              ▼
│ SwiftData read-only cache    │                 ┌─────────────────────────┐
└──────────────────────────────┘                 │ Hermex Companion on NAS │
                                               │ device auth + capability│
                                               │ Gateway proxy           │
                                               │ workspace/upload        │
                                               │ built-in Memory         │
                                               └────────────┬────────────┘
                                                            │ loopback
                                                            │ REST + SSE
                                                            ▼
                                               ┌─────────────────────────┐
                                               │ Hermes Agent API Server │
                                               │ hermes gateway :8642    │
                                               │ sessions/runs/jobs/etc. │
                                               └─────────────────────────┘
```

The Companion is the App's only remote endpoint. Hermes Agent API Server should
remain on loopback and must not be separately exposed merely for the App.

### 3.1 App seams

Views must not construct paths or decode wire payloads. Networking is split by
user capability rather than by one giant backend protocol:

- `CompanionConnectionService`: pairing, device authentication, health,
  capability discovery, and revocation state.
- `SessionRepository`: list/create/read/update/delete/fork/messages.
- `ConversationRunService`: start/stream/status/stop/approval.
- `ModelCatalogService`: OpenAI-compatible models and rich Hermes options.
- `AutomationCatalogService`: Jobs, Skills, and Toolsets.
- `WorkspaceRepository`: approved roots, browse, preview, download, and upload.
- `MemoryRepository`: built-in Memory read and controlled mutations.

The existing UI may continue to use concrete types during migration, but new
Companion code must enter through these seams. Views must not know whether a
result came from Companion-native storage or a proxied Gateway route.

### 3.2 Companion modules

The Companion must remain a small, deep module rather than becoming another
general WebUI backend. Its external interface hides:

- one-time local pairing and revocable per-device credentials;
- Gateway key custody and loopback connectivity;
- sanitized capability merging;
- transparent REST/SSE proxying without a second run lifecycle;
- workspace allowlists, sensitive-path filtering, and path canonicalization;
- bounded streaming upload with temporary files and atomic completion;
- built-in Memory locking, validation, limits, and atomic writes.

Gateway-compatible paths may be forwarded without semantic rewriting.
Companion-native operations use an explicitly versioned namespace. Exact paths,
payloads, error shapes, and pairing protocol are defined and tested in their
implementation issues; this specification does not invent them.

### 3.3 Capability gating

After authenticated Companion onboarding, the App stores a tolerant Companion
capability snapshot. That snapshot includes the Companion version/features and
a sanitized representation of the connected Gateway's `/v1/capabilities`.

- Core UI requires the capabilities needed by the current migration stage.
- Optional destinations are shown only when their endpoint/feature is
  advertised.
- A missing optional capability disables only that feature.
- Unknown capability fields are ignored.
- Companion unavailable, device unauthorized/revoked, Gateway unavailable,
  Gateway unauthorized, and incompatible versions are distinct states.
- The app must not probe speculative paths to guess support.

### 3.4 Authority and lifecycle

- Hermes Gateway is authoritative for sessions, messages, runs, approvals,
  Jobs, Skills/Toolsets, models, and agent-produced output.
- The Companion is authoritative for devices, allowed workspace roots,
  uploaded-file metadata, and built-in Memory mutations it performs.
- The App owns only presentation state and a read-only/offline cache.
- The Companion must preserve Gateway `run_id`, session identity, terminal
  status, ordering, SSE comments, and unknown event types.
- A disconnected App must reconnect or poll through the Companion using the
  existing Gateway identity; neither App nor Companion may resubmit a prompt
  automatically.

### 3.5 UI preservation boundary

The backend migration is behavior-preserving for supported surfaces. Except for
the intentional Companion pairing/onboarding change and removal of unsupported
WebUI-only destinations, retain the inherited:

- Sessions → Chat navigation hierarchy.
- Compact composer layout and normal text-send interaction.
- User/assistant message presentation.
- Markdown, code, math, reasoning, and tool-card presentation.
- Stop, scroll-to-bottom, offline-cache, theme, Dynamic Type, and VoiceOver
  affordances where the Companion/Gateway protocol can support them.

Review each migrated UI slice against `master` with matched fixtures. A visual
redesign, navigation rewrite, or removal of a supported interaction is separate
scope requiring owner approval.

---

## 4. Companion and Gateway contract

The Gateway paths in this section are documented candidates from current
official Hermes Agent API Server documentation. They are not yet a compatibility
claim for the owner's installed server. Each implementation issue must confirm
the installed version/commit, sanitized `/v1/capabilities`, and exact live wire
shape before relying on a path or payload.

The App sends Gateway-compatible requests to the Companion base URL; it never
constructs the Gateway loopback URL. The Companion forwards supported
Gateway-compatible routes and adds separately versioned native operations.

Companion URL examples:

- private reverse proxy: `https://hermex.example.com`
- Tailscale with valid TLS: `https://nas-name.tailnet-name.ts.net`
- simulator-only local development: an implementation-defined localhost port

The App authenticates with its device credential. The Companion authenticates
to Gateway with `API_SERVER_KEY`. The two credentials must never be
interchangeable, returned to the other side, put in a query string, or logged.

### 4.1 Companion connection and discovery

Companion foundation must provide a versioned, testable interface for:

- unauthenticated bounded liveness without secret or path disclosure;
- one-time local pairing and device naming;
- authenticated Companion/Gateway readiness;
- tolerant capabilities and version discovery;
- listing and revoking paired devices.

Pairing must require a short-lived, single-use secret created on the NAS. It may
be transferred by QR code or manual entry. Pairing must not require a Hermex
account, hosted claim server, or relay. The exact wire contract is owned by
Issue #1.

### 4.2 Proxied Gateway discovery

The Companion verifies and sanitizes the following upstream Gateway surfaces:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Gateway liveness |
| GET | `/health/detailed` | Bounded authenticated Gateway readiness |
| GET | `/v1/capabilities` | Gateway feature and endpoint discovery |
| GET | `/v1/models` | OpenAI-compatible model aliases |
| GET | `/api/model/options` | Rich provider/model/reasoning metadata |

Companion onboarding completes only after device authentication succeeds and
the Companion returns a decodable capability document. A temporarily unavailable
Gateway may leave Companion administration reachable in a clearly degraded
state.

### 4.3 Sessions

The upstream session-control surface carried through the Companion is:

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

### 4.4 Runs and human control

The upstream long-running control surface carried through the Companion is:

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

### 4.5 Streaming rules

The Gateway can emit event families such as assistant/message deltas,
reasoning, tool started/completed, approval requests, run completed/failed, and
stream termination.

The Companion transport and App client together must:

- parse the SSE `event:` field and JSON `data:` independently;
- ignore comment/keepalive lines beginning with `:`;
- ignore unknown event types without ending the run;
- preserve upstream ordering and Gateway run/session identity;
- avoid response buffering that delays visible progress;
- keep stable tool-call identity when updating a tool card;
- coalesce presentation updates rather than publishing every token to SwiftUI;
- finalize from authoritative terminal/status data when available;
- never resend the user's prompt automatically after a disconnect;
- reconnect or poll status using the existing `run_id`;
- distinguish completed, failed, cancelled, stopping, and transport-disconnected
  states.

Exact event names and payloads are locked per implementation issue using live
server evidence, official documentation, and matching upstream tests.

### 4.6 First-release Gateway surfaces

These are part of the approved first-release roadmap but remain
capability-gated and require live verification:

| Surface | Documented paths |
| --- | --- |
| Jobs | `/api/jobs` and job detail/update/delete/pause/resume/run routes |
| Skills | `GET /v1/skills` |
| Toolsets | `GET /v1/toolsets` |
| Models | `GET /v1/models` and `GET /api/model/options` |
| Inline images | Verified multimodal session/run input |

Skills/Toolsets are read-only unless a future advertised Gateway or Companion
capability explicitly supports mutation.

### 4.7 Companion workspace and upload

The Companion first release supports:

- NAS-configured allowed workspace roots that the App cannot broaden;
- paged directory browsing under those roots;
- bounded text/binary metadata preview and authenticated download;
- streaming upload to a selected allowed destination;
- upload progress, cancellation, collision handling, and stable metadata;
- making a completed upload available to a subsequent Hermes turn without
  pretending the Gateway supports `file`, `input_file`, or `file_id`.

All paths are canonicalized after symlink resolution and checked against an
allowed root. Sensitive files and directories are denied even if nested under
an allowed root. The first release does not include arbitrary delete, recursive
mutation, shell access, or Git mutation.

Uploads stream into a sibling temporary file, enforce a configured byte limit,
and atomically publish only after success. Exact attachment-reference and
turn-coordination shapes require a dedicated contract issue and live Gateway
verification.

### 4.8 Companion built-in Memory management

The Companion first release supports controlled management of Hermes built-in
`MEMORY.md` and `USER.md`:

- read current content and bounded metadata;
- add, replace, remove, and reset with explicit confirmation where destructive;
- preserve Hermes section/character-limit semantics;
- lock across concurrent App and Agent writes;
- use atomic writes and reject stale conflicting updates.

Raw filesystem overwrite is not the Memory interface. External Memory providers
are not implied by built-in Memory support and require separate capability
adapters.

### 4.9 Explicitly unsupported in Companion v1

The following inherited features are outside the approved first release:

- arbitrary NAS filesystem or secret-file access;
- file deletion, recursive directory mutation, terminal, and Git mutations;
- WebUI projects, pin/archive actions, profile cookies, personalities, usage
  dashboard, and bridge slash-command metadata;
- Hermes Bridge Kanban/Boards;
- WebUI approval/clarify side streams;
- cookie login, logout, CSRF handling, and WebUI version checks.

Existing code for these features may remain during migration, but Companion
mode must hide or clearly mark unavailable features. It must never call an old
WebUI route against either the Companion or Agent API Server.

---

## 5. Security and networking

### 5.1 NAS configuration

Hermes Gateway remains configured with a long random key:

```dotenv
API_SERVER_ENABLED=true
API_SERVER_KEY=<long-random-secret>
```

Start with:

```bash
hermes gateway
```

The documented Gateway default is `127.0.0.1:8642`. Keep it on loopback so only
the Companion can reach it. The Companion owns its separate configuration,
device registry, allowed workspace roots, and Gateway credential. Exact
configuration keys and service commands are defined only when the Companion
implementation issue locks them.

### 5.2 Remote transport

Preferred options:

1. Tailscale with HTTPS via a tailnet certificate or Tailscale Serve.
2. HTTPS through an owner-controlled reverse proxy or Cloudflare Tunnel.

A blanket iOS App Transport Security exception is not part of the release
configuration. Simulator-only HTTP may use a narrowly scoped debug setting.
The Companion should bind loopback by default and be exposed only through the
selected private/TLS transport.

### 5.3 Credential handling

- Store Companion URL, device ID, and device credential in App Keychain.
- Never place `API_SERVER_KEY` on the iPhone or in a pairing payload.
- Store Companion device and Gateway secrets with owner-only NAS permissions.
- Do not persist secrets in SwiftData.
- Do not include secrets in URLs, query strings, crash text, analytics, or logs.
- Clear the App credential when the user removes the server or the device is
  revoked.
- Treat `401` and `403` as authentication/authorization failures without
  deleting offline cached transcripts automatically.
- Self-signed TLS trust is a separate transport decision; v1 prefers a
  system-trusted certificate rather than disabling certificate validation.

### 5.4 Device lifecycle

- Pairing secrets are single-use, short-lived, and generated on the NAS.
- Each installed App receives a distinct revocable credential.
- Revocation affects only the selected device.
- Device listing exposes labels and bounded activity metadata, never credential
  material.
- Companion logs identify a device by a non-secret stable identifier and redact
  request bodies that may contain prompts, Memory, or file content.

### 5.5 File and Memory safety

- Resolve and validate a filesystem path server-side; never trust an App path
  string as authorization.
- Deny traversal, symlink escapes, special files, and sensitive-path patterns.
- Bound directory pages, preview bytes, upload bytes, Memory bytes, request
  time, and concurrent work.
- Use temporary files, fsync/close as appropriate, and atomic replacement.
- Never expose `.env`, auth stores, Companion state, Apple material, private
  keys, or Gateway logs through workspace browsing.
- Destructive Memory reset requires an explicit App confirmation and a
  Companion request designed to resist accidental replay.

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

Performance remediation is intentionally independent from Companion/Gateway
protocol migration. Backend correctness must not be judged from scroll
smoothness, and UI optimization must not silently change protocol behavior.

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
- Batch transport deltas before publishing to the view.
- Preserve a progressive word/fade effect through a presentation queue whose
  cadence is independent of raw SSE event frequency.
- Bound presentation updates to a measured refresh rate and collapse queued
  animation when it falls behind.
- Disable or simplify streaming animation while the user scrolls, when Reduce
  Motion is enabled, in background/low-power states, or when the queue exceeds
  its latency budget.
- Disable text selection only while a message is actively streaming.
- Preserve stable message/tool identities so existing rows do not rebuild.
- Cache or precompute expensive finalized-message presentation data where
  practical.
- Threshold/debounce scroll geometry updates.
- Keep auto-scroll suspended while the user is reading older content.
- Profile changes with Instruments on macOS/device when available.

### 7.3 Acceptance scenarios

The performance issue must include a repeatable benchmark harness and fixtures
for:

- a short plain-text conversation;
- at least 200 mixed messages;
- Markdown with multiple code blocks, a table, math, and tool activity;
- an actively streaming long response;
- scrolling upward while streaming continues.

Success means no correctness regression, bounded memory growth, and visibly
responsive scrolling on the selected iPhone test target. Numeric frame-time
and stream-to-presentation latency targets are recorded only after a baseline
can be measured on macOS/device. The benchmark records fixture version, device,
OS, build configuration, message count, content mix, streaming cadence, peak
memory, dropped/hitch frames where available, and time to settle after stream
completion.

---

## 8. Migration plan

Each slice gets one GitHub Issue, one `issue/<n>-...` branch, tests, and a PR.
Do not implement all phases at once.

### Phase A — specification and evidence

Tracking issue: https://github.com/KiRito02/hermex/issues/2

- [x] Retire the inherited WebUI product contract.
- [x] Verify the Gateway capability and file/Memory gaps.
- [x] Select the self-hosted Companion architecture.
- [x] Align specification, working agreements, roadmap, and Issue #1.
- [x] Record the owner's Hermes Agent version/commit without storing secrets:
  Hermes Agent v0.19.0; running checkout HEAD
  `087732c8c60860888f6c8ac8b9e22271d5269e96` (the CLI separately reports
  release upstream `199f5580`).
- [x] Record the sanitized live capability response without storing secrets:
  bearer auth; Sessions, Runs/SSE, stop, approval, Skills, and Toolsets are
  advertised; `jobs_admin` and `memory_write_api` are false.

### Phase B — Companion contract and foundation

Tracking issue: https://github.com/KiRito02/hermex/issues/1

- [x] Approve the Companion runtime language, direct runtime dependency,
  persistence, isolated environment, and systemd host deployment.
- [x] Approve repository/package layout, exact dependency version/locking, and
  systemd unit/install layout.
- [ ] Define versioned health, pairing, device-auth, capability, error, and
  revocation contracts with tests.
- [ ] Start the minimal NAS Companion without a hosted relay.
- [ ] Connect Companion to Gateway over loopback while keeping
  `API_SERVER_KEY` NAS-local.
- [ ] Replace password/cookie/API-key onboarding with Companion URL and
  one-time local pairing.
- [ ] Store only the device credential in App Keychain and redact secrets/logs.
- [ ] Distinguish Companion, device-auth, Gateway, and compatibility failures.

This is the first implementation issue.

### Phase C — Gateway proxy and capability merge

- [ ] Transparently forward the verified Gateway REST surface.
- [ ] Transparently carry SSE without buffering or identity rewriting.
- [ ] Merge sanitized Gateway capabilities into Companion capabilities.
- [ ] Add bounded readiness and diagnostics without leaking paths or secrets.
- [ ] Build contract fixtures against a pinned Hermes Agent commit.

### Phase D — sessions

- [ ] List and page `/api/sessions`.
- [ ] Create, read, update, delete, and fork supported sessions.
- [ ] Load paginated message history.
- [ ] Map wire models to stable App-domain models.
- [ ] Preserve read-only offline cache behavior.

### Phase E — streaming, control, and presentation pipeline

- [ ] Select the verified session-chat/run coordination strategy.
- [ ] Stream assistant, reasoning, and tool lifecycle events.
- [ ] Stop, status-poll, and reconnect without resending.
- [ ] Surface approval requests and responses when supported.
- [ ] Reconcile final messages with server-authoritative state.
- [ ] Coalesce transport deltas and drive the bounded progressive animation
  queue without tying SwiftUI updates to raw SSE frequency.

### Phase F — first-release Gateway capabilities and adaptive UI

- [ ] Rich model/provider/reasoning picker.
- [ ] Jobs CRUD/control advertised by the installed Gateway.
- [ ] Read-only Skills and Toolsets.
- [ ] Inline image input.
- [ ] Adaptive iPhone/iPad navigation, composer, sheets, and transcript layout.

### Phase G — Companion files, upload, and built-in Memory

- [ ] Configure NAS-side allowed roots.
- [ ] Browse, preview, and download bounded allowed files.
- [ ] Stream uploads with progress, cancellation, limits, and atomic completion.
- [ ] Lock the verified upload-to-turn attachment strategy.
- [ ] Read and safely mutate built-in `MEMORY.md` and `USER.md`.
- [ ] Add stale-write, concurrent-write, size-limit, and destructive-reset tests.

### Phase H — long-chat performance

- [ ] Establish fixtures/baseline.
- [ ] Lazy/windowed transcript.
- [ ] Batched transport and bounded progressive rendering.
- [ ] Reduce heavy Markdown and scroll-observer work.
- [ ] Record repeatable post-change benchmark results.

### Phase I — personal sideload and release acceptance

- [ ] Add personal signing configuration and app-only scheme.
- [ ] Add macOS CI build/test and sideload artifact workflow.
- [ ] Document Windows AltStore/SideStore installation.
- [ ] Deploy Companion reproducibly on the owner's NAS with restart-safe state.
- [ ] Verify on the owner's iPhone and iPad-compatible layout.

---

## 9. Testing and validation

### 9.1 Unit tests

- Companion URL, device-auth, and Gateway-proxy header construction.
- Keychain device-credential lifecycle without logging secrets.
- Companion/Gateway capability decoding with missing/unknown fields.
- Session and message tolerant decoding.
- SSE framing, unknown events, comments, split frames, and malformed data.
- Run state transitions, reconnect, stop, and approval handling.
- Stream batching and transcript identity stability.
- Pairing expiry/replay, per-device revocation, and error classification.
- Workspace canonicalization, root confinement, symlink escape, sensitive-path
  denial, pagination, and size limits.
- Upload cancellation, partial-file cleanup, collision policy, and atomic
  completion.
- Built-in Memory locking, stale writes, limits, mutation, and reset.

### 9.2 Contract tests

App contract tests target a pinned Companion contract. Proxy contract tests
target a pinned Hermes Agent commit/version and cover only advertised
endpoints. Public CI uses fakes/fixtures and must never require owner secrets.

When live credentials are available locally:

- capture sanitized request/response fixtures;
- record Companion version, Hermes version/commit, and sanitized capabilities;
- compare exact method, path, status, content type, and required fields;
- verify that `API_SERVER_KEY` is never returned to the App;
- never commit device credentials, bearer tokens, private hostnames,
  filesystem paths, Memory content, file content, or prompts.

### 9.3 Companion validation

- Run unit and contract suites on Linux/NAS.
- Verify Gateway proxy streaming with split frames, keepalives, reconnect, and
  slow subscribers.
- Verify the service restarts without losing paired-device/revocation state or
  exposing secret material.
- Validate allowed-root behavior against real NAS filesystem and container
  mount layouts.
- Run a live smoke only with owner-approved local credentials and sanitized
  output.

### 9.4 Xcode validation

Green full-suite macOS CI is required before review of code-affecting changes.
Because the primary development machines are Linux/Windows, the handoff may
explicitly carry signed simulator/device validation as owed. For UI changes,
signed simulator launch is required before merge or final acceptance when
applicable; the work must not be described as fully UI-validated until that
check occurs. Physical-device checks are required for sideload signing,
Keychain entitlements, performance, microphone, and background behavior.

For each migrated supported screen, manual validation compares the same
fixture/state on `master` and the Companion branch. Expected differences are
limited to Companion onboarding/capability wording, the approved first-release
features, and explicitly unsupported destinations.

---

## 10. Definition of done for Companion v1

Companion v1 is complete when the owner can deploy the NAS Companion, sideload
the App, and:

- pair locally without a vendor account or relay;
- connect using a revocable device credential while `API_SERVER_KEY` remains
  on the NAS;
- pass Companion, Gateway, authentication, and capability checks;
- list/create/open supported Hermes sessions;
- load conversation history;
- send a turn and watch assistant/tool/reasoning progress;
- recover status after transient disconnect without duplicate submission;
- stop a run and answer an approval when advertised;
- use the app without any `hermes-webui` process;
- manage advertised Jobs, browse Skills/Toolsets, choose models, and send
  inline images;
- browse allowed NAS files, upload a file with progress, and make the completed
  upload available to a Hermes turn;
- view and safely manage built-in `MEMORY.md` and `USER.md`;
- retain the inherited Sessions/Chat navigation, compact composer, and
  message/Markdown/reasoning/tool-card presentation for supported behavior;
- use an adaptive layout on the owner's iPhone and iPad;
- retain a progressive streaming animation without coupling SwiftUI updates to
  every SSE delta;
- scroll a long mixed-content conversation responsively;
- reproduce the long-chat benchmark and compare it with the recorded baseline;
- rebuild and reinstall through the documented Linux/Windows/macOS-CI
  sideload workflow;
- restart/upgrade the Companion through the documented NAS workflow without
  losing device or configuration state.

No App Store listing, TestFlight build, public account system, telemetry, or
WebUI compatibility is required.

---

## 11. Open questions

Stop and ask before implementing a choice that depends on one of these:

1. Owner-specific bundle ID and Apple Team ID for the sideload configuration.
2. Whether remote transport will use Tailscale HTTPS, Cloudflare, or another
   reverse proxy.
3. Whether persisted session chat or Runs API is the primary turn transport
   after live verification.
4. Exact NAS workspace roots and upload byte limits.
5. Whether Companion v1 Memory management is built-in Memory only, as currently
   specified, or must include a named external provider.

---

## 12. References

- Hermes Agent repository:
  https://github.com/NousResearch/hermes-agent
- Official Hermes Agent API Server documentation:
  https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server
- Hermes Agent API server source:
  https://github.com/NousResearch/hermes-agent/blob/main/gateway/platforms/api_server.py
- Hermes Agent Dashboard server patterns:
  https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/web_server.py
- HermesPilot Link pattern (reference only; not a product dependency):
  https://www.npmjs.com/package/@hermespilot/link
- Cloudflare Tunnel:
  https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
- Tailscale:
  https://tailscale.com/
- AltStore:
  https://altstore.io/
- Existing locked SSE dependency:
  https://github.com/launchdarkly/swift-eventsource
