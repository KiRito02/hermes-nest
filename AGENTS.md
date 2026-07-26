# AGENTS.md — working agreement for Hermes Nest

Hermes Nest is a native SwiftUI iPhone/iPad app (Xcode target/scheme
`HermesMobile`) plus a self-hosted NAS Companion. The App connects only to the
Companion; the Companion connects over loopback to the Hermes Agent API Server
started by `hermes gateway` and adds restricted file/upload/built-in-Memory
capabilities. No `hermes-webui`, vendor account, or hosted relay is required.
`PROJECT_SPEC.md` is the product/protocol source of truth — if a request
conflicts with it, stop and ask.
Read by every agent (Codex, Claude Code, …); keep it tool-agnostic.

## Session start & wrap-up
- Read `CURRENT.md` first if it exists — it holds the latest resumable state. It is
  local-only (gitignored), never committed; a fresh clone won't have one.
- Read only the `PROJECT_SPEC.md` sections named in CURRENT.md's **Spec Read** field;
  never the whole ~850-line spec unless told to.
- Active work lives in GitHub Issues. Implement only the issue the human selects, one
  labeled `ready-for-agent`, or one named in CURRENT.md — not every open issue.
- On "wrap up": verify repo/build/test state, overwrite `CURRENT.md` with the new
  state (it stays uncommitted), then commit the code.
  History lives in `git log` and merged PRs; there is no append-only log.

## How work flows
- One issue → one short `issue/<n>-slug` branch → one PR (branches with no issue use
  `chore/` or `fix/`). Issue/triage/domain conventions live in `docs/agents/`.
- `master` is the protected integration branch: keep it buildable, never do
  feature work on it.
- Pushing a branch or merging needs explicit human approval. Once a branch is
  pushed, creating or updating its PR does not need separate approval under the
  owner's standing authorization. Triage bot/review comments before accepting
  them.

## Review depth
- Small documentation, configuration, fixture, and isolated single-file
  changes use focused tests plus a direct diff/self-review. Do not invoke the
  full dual-axis `code-review` workflow for these by default.
- Ordinary issue branches receive one Standards + Spec dual-axis review at the
  push/PR boundary, after implementation and local checks are complete.
- Protocol, authentication, security, persistence, signing, migration, and
  concurrency changes receive the full dual-axis review. Rerun both axes only
  when fixes materially alter one of those high-risk seams; otherwise verify
  the findings with focused tests and a targeted final inspection.
- CI and unresolved PR feedback remain required regardless of review tier.

## Hard rules
1. **Never invent endpoints or JSON shapes.** For App-facing behavior verify:
   (a) the versioned Companion contract/tests; (b) `curl` the owner's running
   Companion — final App-facing arbiter. For proxied Gateway behavior then
   verify: (c) the local Gateway; (d) the official API docs at
   https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server;
   (e) the matching pinned Hermes Agent source and tests under
   `.codex-tmp/hermes-agent/`, especially
   `gateway/platforms/api_server.py` and `tests/gateway/` (clone it if missing:
   `git clone https://github.com/NousResearch/hermes-agent .codex-tmp/hermes-agent`).
   Record the upstream commit before relying on it. That copy is read-only —
   never modify it (refreshing via `git pull` is fine). Never translate a
   WebUI, Dashboard, or HermesPilot Link route into a Companion contract.
2. **No new third-party dependencies** beyond the spec's locked list without approval.
3. **Tolerant decoding:** every `Codable` model uses optionals for fields
   Companion or Gateway might add/rename. Never crash on unknown fields.
4. **No destructive commands** (`rm -rf`, `git push --force`, anything touching
   `~/Library/LaunchAgents/` or restarting Mac services). Suggest them; let the human run them.
5. **Don't commit broken builds.** If a build or test fails, fix it before writing more code.

## Tooling
- The maintainer works in Agentic Development Environments (Codex, Claude Code), not the Xcode UI — prefer terminal validation;
  ask to open Xcode only when the terminal can't answer.
- Use **XcodeBuildMCP** for simulator build/test/run/log; fall back to raw
  `xcodebuild`/`xcrun simctl` for release/archive or low-level diagnosis. Defaults live
  in `.xcodebuildmcp/config.yaml` (scheme `HermesMobile`, sim
  **iPhone 17 Pro Max**); if that sim is missing, pick a nearby iPhone Pro and
  say which. Adaptive-layout changes also require an available 13-inch iPad Pro
  simulator build/launch before merge.
- **Simulator installs must be signed.** Never install a `CODE_SIGNING_ALLOWED=NO`
  build on the simulator for manual testing — that flag is for compile-only checks
  (see `DEVELOPMENT.md`) and strips entitlements, so Keychain writes fail with
  `errSecMissingEntitlement` and login breaks. Put the app on the sim via XcodeBuildMCP
  `build_run_sim` or a plain signed Debug build (no signing-disabling flags), then install/launch.
- On macOS, run the full XCTest suite before asking for review and build +
  launch the app for the human's manual simulator test when UI changed. On
  Linux/Windows, a local commit may precede CI: after explicit approval to push,
  use the macOS GitHub Actions build/test gate. Green full-suite CI is required
  before review/merge, and the handoff must state any simulator or
  physical-device validation still owed.
- Companion unit/contract tests run on Linux/NAS. Gateway proxy tests pin the
  upstream Hermes Agent commit; public CI uses fixtures and never owner secrets.
- The App must never receive or store `API_SERVER_KEY`. It stores only its
  revocable Companion device credential in Keychain.

## Personal signing identity

Owner-specific Team ID and bundle IDs belong in gitignored
`Config/Local.xcconfig`; do not commit them or reuse the upstream maintainer's
identity. Phase I will add a one-app personal-sideload configuration that
disables Share Extension, widgets/Live Activities, and App Groups. Until it
lands, the inherited multi-target scheme and committed upstream defaults still
exist and may require local overrides; do not describe them as the desired
personal distribution state.

App Store and TestFlight work is out of scope until the owner explicitly
changes the distribution decision. Building a sideload artifact or Companion
package is not a git push; pushing any branch still requires explicit human
approval.

## Working with the human
- Surface tradeoffs in plain English before non-obvious choices; when in doubt, ask.
- Ask before touching anything under the spec's "Open questions."
- After each slice, report: (1) files changed (2) build/test command run (3) result
  (4) next suggested step — plus a short manual simulator test plan when UI changed.

## Keep this file honest
If something here surprises you or contradicts the project, tell the developer and
**propose** an AGENTS.md edit — don't silently edit it. This file is a Band-Aid for what
can't be fixed in code/tests/tooling; your proposed edits are also a signal of what to fix structurally.
