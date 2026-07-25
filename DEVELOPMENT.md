# Development

Hermex Direct is developed as two cooperating deliverables:

- the native iPhone/iPad App;
- a self-hosted Companion on the owner's NAS.

The App connects only to Companion. Companion connects over loopback to the
Hermes Agent API Server started by `hermes gateway` and adds restricted file,
upload, and built-in Memory management. It requires neither `hermes-webui` nor
a hosted account/relay.

[`PROJECT_SPEC.md`](PROJECT_SPEC.md) is the product/protocol source of truth.
[`AGENTS.md`](AGENTS.md) contains the working agreement for coding agents.

The initial distribution target is personal sideloading. App Store and
TestFlight procedures inherited from upstream are not part of this fork's
development workflow.

## Development environments

### Linux/NAS and Windows

Linux/NAS and Windows are suitable for:

- source editing and Git/GitHub work;
- documentation and fixture review;
- Companion development, unit/contract tests, and live local Gateway tests;
- non-Xcode scripts and static checks;
- launching macOS GitHub Actions build/test jobs;
- downloading a sideload artifact;
- signing/installing on the owner's device with AltStore or SideStore.

They cannot compile or run a native SwiftUI iOS application locally. Xcode,
simulators, XCTest execution, and Xcode archive/development signing require
macOS. AltStore/SideStore on Windows can re-sign and install a prepared
sideload artifact.

### macOS

When a macOS environment is available, use XcodeBuildMCP for normal
simulator build/test/run work. Raw `xcodebuild` remains the fallback for
low-level diagnosis and archive-oriented validation.

## Primary deployment target

The App uses a system-trusted HTTPS Companion URL:

```text
https://<your-companion-host>
```

The NAS runs Companion beside a loopback-only Gateway:

```dotenv
API_SERVER_ENABLED=true
API_SERVER_KEY=<long-random-secret>
```

Start the server with:

```bash
hermes gateway
```

The documented Gateway default is `127.0.0.1:8642`. Keep it on loopback.
Companion service commands, listen port, configuration names, and App-facing
paths are intentionally not documented until Issue #1 locks and tests them.
Do not invent placeholders and later treat them as a contract.

Before debugging the App, verify in order:

1. Companion process and bounded liveness;
2. App device authentication and Companion capabilities;
3. Companion-to-Gateway readiness;
4. sanitized Gateway capabilities carried by Companion.

Never put `API_SERVER_KEY` on the App device. Local Gateway diagnostics may use
it on the NAS, but it must not appear in shared logs, issues, screenshots, or
fixtures.

## Remote access

Preferred options:

1. Tailscale with HTTPS through Tailscale Serve or a valid tailnet
   certificate to Companion.
2. An owner-controlled HTTPS reverse proxy or Cloudflare Tunnel to Companion.

Do not solve connectivity by disabling TLS verification. A blanket App
Transport Security exception is not part of the personal release
configuration.

If the server appears unavailable, check in this order:

1. Companion process state;
2. reverse proxy/tunnel/Tailscale state;
3. public/private DNS and certificate validity;
4. device revocation/authentication state;
5. Companion/Gateway compatibility;
6. `hermes gateway` process and loopback listener;
7. Companion-local Gateway-key mismatch.

Local port inspection on Linux/macOS:

```bash
lsof -i :8642
```

or:

```bash
ss -ltnp | grep 8642
```

## Simulator-only local fallback

On a Mac running Companion and Hermes Agent locally, the simulator may use a
narrowly scoped Debug-only HTTP Companion URL. The actual port/path is defined
by Issue #1 and its development configuration.

This is a Debug-only convenience. Physical devices need a reachable HTTPS
hostname or an intentionally configured private-network route.

Follow the official Hermes Agent installation and API Server documentation:

- https://hermes-agent.nousresearch.com/docs/
- https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server

Do not expose Gateway directly to the App and do not copy old `hermes-webui`,
Dashboard, or HermesPilot Link routes into the Companion contract.

## Protocol contract evidence

For every App-facing endpoint or SSE payload, use this precedence:

1. Versioned Companion contract and tests.
2. Sanitized evidence from the owner's running Companion.
3. For proxied behavior, sanitized local Gateway evidence.
4. Official Hermes Agent API Server documentation.
5. Matching Hermes Agent source and tests at a recorded commit.

The read-only upstream checkout lives at:

```text
.codex-tmp/hermes-agent/
```

Clone it when absent:

```bash
git clone https://github.com/NousResearch/hermes-agent .codex-tmp/hermes-agent
```

Before relying on it, record:

```bash
git -C .codex-tmp/hermes-agent status --short
git -C .codex-tmp/hermes-agent rev-parse HEAD
```

Primary source/test locations:

```text
gateway/platforms/api_server.py
tests/gateway/
website/docs/user-guide/features/api-server.md
```

Dashboard filesystem/Memory code may be studied as implementation evidence, but
its private route shapes are not a Companion contract. HermesPilot Link is an
architecture reference only. Neither source may be copied into the App-facing
wire contract by assumption.

## SSE and reconnect verification

Streaming is implemented only after the selected issue verifies whether
persisted session chat or the Runs API is the primary turn transport for the
owner's installed Hermes Agent version and proves that Companion forwarding
does not buffer or rewrite the stream.

Regardless of the selected endpoint, validation must cover:

- SSE comments/keepalives beginning with `:` are ignored;
- unknown event types do not fail the stream;
- assistant/reasoning deltas and tool lifecycle events preserve stable
  identity;
- Companion preserves ordering, comments, unknown events, `run_id`, and session
  identity;
- a transport disconnect does not resend the user's prompt;
- status/reconnect uses the existing server identifier;
- stop and approval state reconcile with authoritative server status;
- background/foreground does not duplicate the turn.

Record the installed Hermes Agent version/commit and sanitized capability
response alongside the implementation issue. Record the Companion version and
contract fixture version as well.

## XcodeBuildMCP validation

The repository defaults are in `.xcodebuildmcp/config.yaml`:

- Project: `HermesMobile.xcodeproj`
- Scheme: `HermesMobile`
- Configuration: `Debug`
- Reference simulator: `iPhone 17`

For a completed code slice:

1. Run focused XCTest targets while iterating.
2. Run the full XCTest suite before review.
3. Build and launch the app when UI/runtime behavior changed.
4. Capture logs/screenshots only when they are useful evidence.
5. Report any device-only validation still owed.

Agent/MCP flow:

- inspect the current defaults before the first build;
- use `test_sim` for XCTest validation;
- use `build_run_sim` for a signed Debug simulator install;
- choose a nearby iPhone simulator if `iPhone 17` is unavailable and report
  the substitution.

Never install a simulator build produced with
`CODE_SIGNING_ALLOWED=NO`. It lacks the entitlements required for Keychain
testing.

Human/CLI equivalents:

```bash
xcodebuildmcp simulator list --enabled
```

```bash
xcodebuildmcp simulator test --output jsonl
```

```bash
xcodebuildmcp simulator build-and-run --output jsonl
```

## Raw xcodebuild fallback

List available simulators:

```bash
xcrun simctl list devices available
```

Run the full suite:

```bash
xcodebuild test \
  -project HermesMobile.xcodeproj \
  -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Compile-only CI may disable signing, but signed simulator/manual validation
must not:

```bash
xcodebuild build \
  -project HermesMobile.xcodeproj \
  -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO
```

## Swift file-size policy

Run:

```bash
scripts/check-swift-file-sizes
```

Current policy:

- warn on production app Swift files over 500 LOC;
- keep the check warning-only;
- scope it to `HermesMobile/` production sources;
- use warnings to guide small, behavior-preserving extractions.

Override the local warning threshold when useful:

```bash
HERMES_SWIFT_FILE_SIZE_LIMIT=300 scripts/check-swift-file-sizes
```

## Personal signing and sideloading

Never commit the owner's Apple Team ID or private bundle identity. Put local
overrides in gitignored `Config/Local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
APP_BUNDLE_IDENTIFIER = com.yourname.hermex
// Temporary while using the inherited multi-target scheme:
APP_GROUP_IDENTIFIER = group.com.yourname.hermex
```

The planned personal-sideload configuration will build the main app only and
will disable Share Extension, Live Activity widget, and App Group requirements.
Until that issue lands, the inherited multi-target scheme may still require
the temporary App Group override above.

The intended owner workflow is:

1. Push an explicitly approved branch.
2. Manually run the `PR CI` workflow on that branch for macOS build/test.
   Packaging is added later in the personal-sideload Phase I issue.
3. After Phase I lands, download the sideload artifact on Windows.
4. Sign/install it with AltStore or SideStore using the owner's Apple account.
5. Re-sign when the provisioning period expires.

Do not add App Store Connect secrets or revive inherited TestFlight workflows
without a new explicit distribution decision.

## Manual regression checklist

Run the sections relevant to the current migration phase.

### Companion connection foundation

- Fresh install shows Companion URL plus local pairing onboarding.
- A valid single-use pairing secret creates one device credential.
- Expired/replayed pairing and revoked device credentials fail distinctly.
- Healthy but incompatible Companion reports an incompatibility state.
- Companion-up/Gateway-down differs from tunnel/network failure.
- `API_SERVER_KEY` never reaches the App or visible diagnostics.
- Reconfigure clears the stored device credential but not offline transcript
  cache.
- No WebUI login/cookie or legacy feature route is probed.

### UI preservation

Compare matched fixtures against `master`:

- Sessions → Chat navigation remains recognizable.
- Composer layout and ordinary text send remain intact.
- User/assistant bubbles, Markdown, code, math, reasoning, and tool cards retain
  their presentation.
- Capability-gated destinations match Companion/Gateway support.
- Light/dark mode, Dynamic Type, and VoiceOver core paths remain functional.

### Sessions and streaming (after their issues land)

- List, page, create, open, update, fork, and delete supported sessions.
- Load paginated message history.
- Send and stream a normal turn.
- Stop and reconnect without duplicate submission.
- Resolve approval when advertised.
- Background/foreground during an active turn.
- Offline cached transcript remains read-only.

### Companion files and Memory

- Directory browsing cannot escape a NAS-configured allowed root.
- Sensitive paths, symlink escapes, special files, and oversized previews fail
  safely.
- Upload reports progress, supports cancellation, and leaves no partial
  published file.
- A completed upload is available to the next verified Hermes turn.
- Built-in Memory read/mutation preserves limits and rejects stale writes.
- Destructive Memory reset requires explicit confirmation.

### Long-chat performance (separate issue)

- Short plain-text fixture.
- At least 200 mixed messages.
- Multiple code blocks, table, math, and tool activity.
- Long actively streaming response.
- Scroll upward while streaming continues.
- Progressive animation remains bounded and collapses backlog instead of
  delaying completed text.
- Record the repeatable baseline and post-change measurements.

## Git workflow

1. Start from a selected GitHub Issue.
2. Branch from `master` as `issue/<number>-<slug>`.
3. Keep the slice focused and test-backed.
4. Run local checks and commit. On Linux/Windows, ask before pushing the
   branch, then manually run `PR CI` for the full macOS XCTest gate.
5. Ask separately before opening/updating a PR.
6. Link the issue in the PR and report exact validation and any device-only
   checks still owed.

`master` is the protected integration branch. It is not automatically an App
Store or TestFlight release candidate in this fork.
