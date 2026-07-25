<div align="center">

<img src="docs/assets/readme/hermex-icon.png" alt="Hermex app icon" width="96" />

# Hermex Direct

**A native iOS client for a self-hosted Hermes Agent API Server.**

Personal fork · direct NAS connection · no hosted relay

[![iOS 18+](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](LICENSE)

[Roadmap](PROJECT_SPEC.md) · [Issue tracker](https://github.com/KiRito02/hermex/issues) · [Development](DEVELOPMENT.md)

</div>

## Status

This fork is **in migration**. The inherited Hermex SwiftUI interface is
present, but direct Hermes Agent API Server networking is not complete yet.
Do not treat the current branch as a finished direct client.

- Product direction documented; live API contract verification is pending
  Issue #1.
- First implementation slice:
  [Issue #1 — bearer auth, capabilities, and onboarding](https://github.com/KiRito02/hermex/issues/1).
- Distribution target: personal sideload, not App Store/TestFlight.
- Current development branch changes remain local until explicitly approved
  for push.

## Goal

Hermex Direct connects an iPhone directly to
[Hermes Agent](https://github.com/NousResearch/hermes-agent) running on the
owner's NAS through the API Server started by `hermes gateway`.

The fork preserves the useful native Hermex interaction model while replacing
the inherited `hermes-webui` backend:

- native Sessions → Chat navigation and compact composer;
- Markdown, code, math, reasoning, and tool-call presentation;
- bearer-authenticated direct capability discovery;
- direct sessions, streaming runs, reconnect, stop, and approvals;
- offline read-only cache;
- a separate performance track for long, streaming conversations.

`hermes-webui` is not required by the target architecture.

## Direct-v1 scope

Required:

- Server URL + API key onboarding.
- `/health` plus authenticated `/v1/capabilities`.
- Direct session list/history and persisted conversation turns.
- Structured streaming, status recovery, stop, and approvals when advertised.
- Tolerant decoding and capability-gated UI.
- Responsive long-chat scrolling.
- Personal Windows sideload workflow backed by macOS CI.

Not promised in direct v1:

- Workspace/file/Git browser.
- General file/PDF upload.
- Hermes Bridge Kanban/Boards.
- WebUI projects, cookie profiles, memory, or insights panels.
- Public App Store/TestFlight distribution.

See [`PROJECT_SPEC.md`](PROJECT_SPEC.md) for the authoritative scope.

## Server

Configure Hermes Agent on the NAS:

```dotenv
API_SERVER_ENABLED=true
API_SERVER_KEY=<long-random-secret>
```

Start it:

```bash
hermes gateway
```

The documented default listener is `127.0.0.1:8642`. Expose it through a
system-trusted HTTPS reverse proxy/tunnel or Tailscale HTTPS.

Verify liveness:

```bash
curl https://<your-hermes-host>/health
```

Verify authenticated capabilities without sharing the key:

```bash
curl \
  -H "Authorization: Bearer $HERMEX_API_KEY" \
  https://<your-hermes-host>/v1/capabilities
```

Official API Server documentation:
https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server

## Development workflow

The owner's primary machines are Linux/NAS and Windows:

1. Edit and commit source on Linux/Windows.
2. Ask before pushing a branch.
3. Manually run `PR CI` on a macOS GitHub Actions runner for Xcode
   build/XCTest.
4. After Phase G adds packaging, download the prepared artifact on Windows.
5. Re-sign/install it with AltStore or SideStore.

Local Xcode development requires macOS. Open `HermesMobile.xcodeproj` and use
the `HermesMobile` scheme. The reference simulator is iPhone 17.

Full instructions:

- [`DEVELOPMENT.md`](DEVELOPMENT.md)
- [`CONTRIBUTING.md`](CONTRIBUTING.md)
- [`AGENTS.md`](AGENTS.md)

## Repository workflow

- `master` is the protected integration branch.
- Active work lives in GitHub Issues.
- One Issue → one `issue/<n>-slug` branch → one PR.
- Push, PR creation/update, and merge require explicit owner approval.
- Never invent endpoints or JSON shapes.
- Never commit server keys, Apple credentials, or owner-specific signing IDs.

## Upstream acknowledgement

This fork is based on the open-source
[Hermex](https://github.com/uzairansaruzi/hermex) iOS application and preserves
its MIT license and third-party notices.

Hermex Direct targets
[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) as
its backend. It is an independent personal client and is not an official Nous
Research or upstream Hermex release.

## License

MIT — see [LICENSE](LICENSE).
