<div align="center">

<img src="docs/assets/readme/hermex-icon.png" alt="Hermes Nest app icon" width="96" />

# Hermes Nest

**Forked from [uzairansaruzi/hermex](https://github.com/uzairansaruzi/hermex).**

[![iOS 18+](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](LICENSE)

[Roadmap](PROJECT_SPEC.md) · [Issue tracker](https://github.com/KiRito02/hermes-nest/issues) · [Personal sideload](docs/personal-sideload.md) · [Development](DEVELOPMENT.md)

</div>

## Status

Hermes Nest v0.1.0 is the first formal personal-sideload release. It uses the
approved App → self-hosted Companion → loopback Hermes Gateway architecture.
The personal product builds only the native iPhone/iPad App; inherited WebUI
login/control routes and extension targets are not part of its runtime.

- Distribution target: personal sideload, not App Store/TestFlight.
- Download the unsigned IPA from the
  [latest GitHub Release](https://github.com/KiRito02/hermes-nest/releases/latest),
  then sign and install it with AltStore or SideStore.

## Goal

Hermes Nest connects an iPhone or iPad to a small Companion running on the
Hermes Agent host. Companion keeps the Gateway key local, calls
[Hermes Agent](https://github.com/NousResearch/hermes-agent) on loopback, and
adds restricted file/upload/built-in-Memory capabilities.

The fork preserves the useful native Hermex interaction model while replacing
the inherited `hermes-webui` backend:

- native Sessions → Chat navigation and compact composer;
- Markdown, code, math, reasoning, and tool-call presentation;
- local pairing and revocable per-device credentials;
- merged Companion/Gateway capability discovery;
- sessions, streaming runs, reconnect, stop, and approvals;
- Jobs, Skills/Toolsets, models, inline images, adaptive iPad layout;
- restricted host file browsing, streaming upload, and built-in Memory
  management;
- offline read-only cache;
- a separate performance track for long, streaming conversations.

`hermes-webui`, a vendor account, and a hosted relay are not required.

## Companion-v1 scope

Required:

- Companion URL plus one-time local pairing.
- Revocable device authentication; `API_SERVER_KEY` stays on the Hermes Agent host.
- Companion/Gateway readiness and tolerant merged capabilities.
- Session list/history and persisted conversation turns.
- Structured streaming, status recovery, stop, and approvals when advertised.
- Jobs, read-only Skills/Toolsets, models, inline images, and iPad layout.
- Allowed-root file browsing, upload, and built-in Memory management.
- Progressive streaming animation plus a repeatable long-chat benchmark.
- Personal Windows sideload workflow backed by macOS CI.

Not promised in Companion v1:

- Arbitrary filesystem access, delete, terminal, or Git mutation.
- Hermes Bridge Kanban/Boards.
- WebUI projects, cookie profiles, personalities, or insights panels.
- Hosted account/relay service.
- Public App Store/TestFlight distribution.

See [`PROJECT_SPEC.md`](PROJECT_SPEC.md) for the authoritative scope.

## Hermes Agent host deployment

Configure Hermes Agent on its host and keep Gateway on loopback:

```dotenv
API_SERVER_ENABLED=true
API_SERVER_KEY=<long-random-secret>
```

Start it:

```bash
hermes gateway
```

The documented Gateway listener is `127.0.0.1:8642`. Companion calls it
locally; only Companion is exposed. The primary owner deployment uses Lucky as
an HTTPS reverse proxy, with Tailscale HTTPS also supported.

Companion uses Python 3.11, pinned `aiohttp`, standard-library SQLite, a
`uv`-locked isolated environment, XDG-owned configuration/state/releases, and a
systemd service installed directly on the Hermes Agent host. Install it from a
clean checkout with `Companion/companionctl install`; later use `upgrade`,
`rollback`, `backup`, `restore`, `status`, and `pair`. The command preserves
loopback binding and degraded operation when Gateway is unavailable. Do not
expose Gateway directly or place `API_SERVER_KEY` on the iPhone.

Official API Server documentation:
https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server

## Development workflow

The owner's primary development machines are Linux and Windows:

1. Edit and commit source on Linux/Windows.
2. Ask before pushing a branch.
3. Manually run `PR CI` on a macOS GitHub Actions runner for Xcode
   build/XCTest.
4. Run `Personal Sideload Artifact` and download the prepared artifact on
   Windows.
5. Re-sign/install it with AltStore or SideStore.

See the bilingual [personal sideload guide](docs/personal-sideload.md).

Local Xcode development requires macOS. Open `HermesMobile.xcodeproj` and use
the `HermesMobile` scheme. The reference simulator is iPhone 17 Pro Max;
adaptive layout changes are also checked on a 13-inch iPad Pro simulator.

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
- Never commit Companion/Gateway keys, Apple credentials, or owner-specific
  signing IDs.

## Upstream acknowledgement

This fork is based on the open-source
[Hermex](https://github.com/uzairansaruzi/hermex) iOS application and preserves
its MIT license and third-party notices.

Hermes Nest uses
[NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
behind its self-hosted Companion. It is an independent personal client and is
not an official Nous Research, HermesPilot, or upstream Hermex release.

## License

MIT — see [LICENSE](LICENSE).
