# Changelog

Notable changes to Hermes Nest. Version headings correspond to formal releases;
unreleased changes accumulate at the top. Format follows
[Keep a Changelog](https://keepachangelog.com/) with Added / Changed / Fixed /
Security sections per release.

## [Unreleased]

## [0.1.0] - 2026-08-02

### Added
- Native iPhone/iPad client for self-hosted Hermes Agent through the restricted
  Companion service; no vendor account, hosted relay, or `hermes-webui` runtime
  is required.
- Local pairing with revocable device credentials while the Gateway API key
  stays on the Hermes host.
- Native session list, session creation, persisted history, model and reasoning
  selection, Skills/Toolsets discovery, Jobs, approvals, inline images, allowed-root
  file upload, and built-in Memory management.
- Structured live run presentation for assistant text, reasoning, tool calls,
  reconnect, stop, and active-run recovery.
- Adaptive SwiftUI shell for iPhone and iPad, with dark mode, localization,
  accessible controls, and compact ChatGPT-inspired conversation composition.
- Reproducible Python 3.11 Companion installation and an app-only unsigned IPA
  workflow for personal AltStore/SideStore signing.

### Changed
- Renamed the user-facing product from Hermex to Hermes Nest and replaced the
  inherited WebUI-backed navigation with the Companion-native product shell.
- Batched and paced transcript presentation to keep long, streaming conversations
  responsive without coupling SwiftUI rendering to every SSE delta.

### Fixed
- Session switching and history recovery no longer block composing or sending
  messages when one conversation is slow to load.
- Long-running responses recover after transient stream disconnects without
  duplicate submission or disappearing transcript content.
- The composer follows keyboard changes, new turns, reasoning, tool activity,
  and progressively presented assistant output.

[Unreleased]: https://github.com/KiRito02/hermes-nest/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/KiRito02/hermes-nest/releases/tag/v0.1.0
