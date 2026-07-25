# Development

Hermex Direct is developed against a self-hosted Hermes Agent API Server
started by `hermes gateway`. It does not require `hermes-webui`.

[`PROJECT_SPEC.md`](PROJECT_SPEC.md) is the product/API source of truth.
[`AGENTS.md`](AGENTS.md) contains the working agreement for coding agents.

The initial distribution target is personal sideloading. App Store and
TestFlight procedures inherited from upstream are not part of this fork's
development workflow.

## Development environments

### Linux/NAS and Windows

Linux/NAS and Windows are suitable for:

- source editing and Git/GitHub work;
- documentation and fixture review;
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

## Primary server target

Use the owner's Hermes Agent API Server through a system-trusted HTTPS URL:

```text
https://<your-hermes-host>
```

The NAS runs:

```dotenv
API_SERVER_ENABLED=true
API_SERVER_KEY=<long-random-secret>
```

Start the server with:

```bash
hermes gateway
```

The documented default listener is `127.0.0.1:8642`. Keep it on loopback and
put a TLS reverse proxy or tunnel in front where practical.

Before debugging the app, verify liveness:

```bash
curl https://<your-hermes-host>/health
```

Then verify authenticated capability discovery without printing the key:

```bash
curl \
  -H "Authorization: Bearer $HERMEX_API_KEY" \
  https://<your-hermes-host>/v1/capabilities
```

`HERMEX_API_KEY` in the example is a local shell variable containing the
server's `API_SERVER_KEY` value. Never commit the value or paste it into logs,
issues, screenshots, fixtures, or command output shared with others.

Onboarding is not considered successful merely because `/health` works. The
authenticated `/v1/capabilities` call must also succeed and decode.

## Remote access

Preferred options:

1. HTTPS reverse proxy or Cloudflare Tunnel to `127.0.0.1:8642`.
2. Tailscale with HTTPS through Tailscale Serve or a valid tailnet
   certificate.

Do not solve connectivity by disabling TLS verification. A blanket App
Transport Security exception is not part of the personal release
configuration.

If the server appears unavailable, check in this order:

1. `hermes gateway` process state;
2. local listener on port 8642;
3. reverse proxy/tunnel/Tailscale state;
4. public/private DNS and certificate validity;
5. bearer-key mismatch;
6. `/v1/capabilities` compatibility.

Local port inspection on Linux/macOS:

```bash
lsof -i :8642
```

or:

```bash
ss -ltnp | grep 8642
```

## Simulator-only local fallback

On a Mac running Hermes Agent locally, the iOS simulator can use:

```text
http://127.0.0.1:8642
```

This is a Debug-only convenience. Physical devices need a reachable HTTPS
hostname or an intentionally configured private-network route.

Follow the official Hermes Agent installation and API Server documentation:

- https://hermes-agent.nousresearch.com/docs/
- https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server

Do not copy the old `hermes-webui` server setup into this fork.

## API contract evidence

For every endpoint or SSE payload, use this precedence:

1. Sanitized `curl` evidence from the owner's running server.
2. Official Hermes Agent API Server documentation.
3. Matching Hermes Agent source and tests at a recorded commit.

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

The retired WebUI pin and contract runbook do not define the direct API
compatibility boundary. A future issue may add a Hermes Agent pin and direct
contract suite after live verification.

## SSE and reconnect verification

Direct streaming is implemented only after the selected issue verifies whether
persisted session chat or the Runs API is the primary turn transport for the
owner's installed Hermes Agent version.

Regardless of the selected endpoint, validation must cover:

- SSE comments/keepalives beginning with `:` are ignored;
- unknown event types do not fail the stream;
- assistant/reasoning deltas and tool lifecycle events preserve stable
  identity;
- a transport disconnect does not resend the user's prompt;
- status/reconnect uses the existing server identifier;
- stop and approval state reconcile with authoritative server status;
- background/foreground does not duplicate the turn.

Record the installed Hermes Agent version/commit and sanitized capability
response alongside the implementation issue.

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
   Packaging is added later in the personal-sideload Phase G issue.
3. After Phase G lands, download the sideload artifact on Windows.
4. Sign/install it with AltStore or SideStore using the owner's Apple account.
5. Re-sign when the provisioning period expires.

Do not add App Store Connect secrets or revive inherited TestFlight workflows
without a new explicit distribution decision.

## Manual regression checklist

Run the sections relevant to the current migration phase.

### Direct connection foundation

- Fresh install shows Server URL + API Key onboarding.
- Valid `/health` plus authenticated `/v1/capabilities` completes onboarding.
- Wrong API key reports unauthorized/forbidden distinctly.
- Healthy but incompatible server reports an incompatibility state.
- Server/tunnel down reports a network/reachability state.
- API key never appears in visible diagnostics or logs.
- Reconfigure clears the stored credential but not offline transcript cache.
- No WebUI login/cookie or legacy feature route is probed.

### UI preservation

Compare matched fixtures against `master`:

- Sessions → Chat navigation remains recognizable.
- Composer layout and ordinary text send remain intact.
- User/assistant bubbles, Markdown, code, math, reasoning, and tool cards retain
  their presentation.
- Unsupported WebUI-only destinations are hidden or clearly unavailable.
- Light/dark mode, Dynamic Type, and VoiceOver core paths remain functional.

### Sessions and streaming (after their issues land)

- List, page, create, open, update, fork, and delete supported sessions.
- Load paginated message history.
- Send and stream a normal turn.
- Stop and reconnect without duplicate submission.
- Resolve approval when advertised.
- Background/foreground during an active turn.
- Offline cached transcript remains read-only.

### Long-chat performance (separate issue)

- Short plain-text fixture.
- At least 200 mixed messages.
- Multiple code blocks, table, math, and tool activity.
- Long actively streaming response.
- Scroll upward while streaming continues.

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
