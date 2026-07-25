# Contributing to Hermex

Thanks for your interest in contributing! This document covers local setup,
running tests, code signing for contributors, and the PR workflow. Please also
read the [Code of Conduct](CODE_OF_CONDUCT.md).

## Local setup

- **Xcode 26 or newer** (the project builds with the iOS 18 SDK or later; the
  deployment target is iOS 18).
- Clone the repo and open `HermesMobile.xcodeproj`. Dependencies resolve
  automatically via Swift Package Manager — the dependency list is locked in
  `PROJECT_SPEC.md`; do not add new ones without maintainer approval.
- Build and run the **`HermesMobile`** scheme on an iPhone simulator
  (`iPhone 17` is the reference device; any recent iPhone simulator works).
- To actually use the app you need your own
  [Hermes Agent API Server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server)
  started by `hermes gateway`. See [`DEVELOPMENT.md`](DEVELOPMENT.md) for
  reachable-server options and the simulator-only `http://127.0.0.1:8642`
  fallback.

## Running tests

The full XCTest suite is the repo's green bar — it must pass before any PR:

```zsh
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile -destination 'platform=iOS Simulator,name=iPhone 17'
```

If that simulator name isn't installed, pick a nearby iPhone from
`xcrun simctl list devices available`. The same suite runs with code signing
disabled for every code-affecting pull request; docs-only PRs use the cheap
gate, and a manually dispatched `PR CI` run always executes the full suite.
Fork CI needs no secrets.

## Code signing for contributors

Never edit `project.pbxproj` just to sign with your own team. Override signing
locally instead:

1. Create `Config/Local.xcconfig` (it is gitignored, so it never lands in a PR):

   ```xcconfig
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   APP_BUNDLE_IDENTIFIER = com.yourname.hermex
   // Temporary while using the inherited multi-target scheme:
   APP_GROUP_IDENTIFIER = group.com.yourname.hermex
   ```

2. Build normally. `Config/Shared.xcconfig` is wired into the project and ends
   with `#include? "Local.xcconfig"`, so your local values override the
   committed defaults without putting personal identity in git.

The planned personal-sideload configuration is app-only. After it lands, Share
extensions, widgets/Live Activities, and App Groups are not part of the initial
signing requirement; until then, the inherited multi-target scheme may still
require the temporary App Group override shown above.

For simulator-only development you usually don't need any of this: simulator
builds don't require a paid team. Note that unit tests and CI run with
`CODE_SIGNING_ALLOWED=NO`; installing such a build on a simulator for *manual*
testing breaks Keychain entitlements — use a normally-signed build for that
(see `AGENTS.md`).

## What PRs we welcome (and what we don't)

Bug fixes, test coverage, and focused improvements are always welcome. For
anything larger than a small fix, **open an issue first and wait for a
maintainer nod before writing code** — it protects your time as much as the
review queue. Drive-by rewrites, reformat-the-world diffs, and unannounced
architecture overhauls will be closed without detailed review.

Keep each PR to **one logical change** with a reviewable diff. If a change is
independently useful, it deserves its own PR.

## App bug or server bug?

Hermex Direct is a client of
[Hermes Agent](https://github.com/NousResearch/hermes-agent), so some apparent
app bugs are server-contract bugs. Before filing:

- Capture the HTTP status/content type and a sanitized response from the same
  endpoint with `curl`; never include the API key.
- Compare the behavior with `/v1/capabilities`, the official API Server docs,
  and the matching Hermes Agent source/tests.
- If the server violates its advertised contract, file it
  [upstream](https://github.com/NousResearch/hermes-agent/issues) and link that
  ticket here when the app also needs a graceful fallback.
- If the wire contract is correct and only the app fails, file it here.

## PR workflow

1. **Start from an issue.** Every change should trace to a GitHub issue —
   comment on it so work isn't duplicated, or open one first (bug/feature
   templates are provided).
2. **Branch** from `master` as `issue/<number>-<short-slug>` (e.g.
   `issue/42-fix-session-search`).
3. **Make the change**, keeping these repo hard rules (full list in
   [`AGENTS.md`](AGENTS.md)):
   - **Tolerant decoding:** every `Codable` model uses optionals for fields the
     server might add or rename — never crash on unknown fields.
   - **Never invent API endpoints or JSON shapes** — verify against your running
     server, the official Hermes Agent API Server docs, and matching pinned
     Hermes Agent source/tests, in that order.
   - **No new third-party dependencies** without approval.
4. **Run the full test suite** (command above) and make sure it passes.
5. **Open a PR** against `master` using the PR template — link the issue with
   `Fixes #<number>`, describe what changed and how you tested it. CI must be
   green; automated review bots may comment, and the maintainer reviews and
   merges.
6. **Disclose AI usage** in one line of the PR description: the tool/model
   used (e.g. "built with Claude Code"), or "human-authored". This repo is
   itself built with coding agents, so it's normal context for review — not a
   gate.

`master` is the protected integration branch. The initial distribution target
is personal sideloading; App Store and TestFlight work is out of scope unless
the owner explicitly changes that decision.

## Questions

Open an issue in [this fork](https://github.com/KiRito02/hermex/issues) if
something here is unclear or wrong — documentation fixes are welcome too.
