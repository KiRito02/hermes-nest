# Hermex — Project Intent

This file is for fast orientation only. `PROJECT_SPEC.md` remains the source of truth for product scope, API behavior, build phases, dependencies, and open decisions.

Hermex is a native iPhone/iPad control surface plus a self-hosted NAS Companion
for a Hermes AI agent stack. The App is the interaction/review surface;
Companion is its only remote endpoint; Hermes Gateway remains the execution
plane behind Companion on loopback.

## Mental Model

- Start or continue Hermes sessions from iOS.
- Watch streaming agent work without using the desktop browser UI.
- Steer, stop, inspect, and recover work while away from the Mac.
- Keep authentication, navigation, composer controls, attachments, and offline read-only cache feeling native.
- Avoid dangerous write/admin surfaces until the mobile UX is explicit and safe.

## Boundaries

- Native SwiftUI app, not a webview wrapper.
- App plus a small NAS Companion; do not turn Companion into a general WebUI,
  terminal, arbitrary filesystem API, or hosted relay.
- Versioned Companion contract plus verified Gateway behavior only; never
  invent endpoint paths or JSON shapes.
- Tolerant decoding over brittle model purity; upstream JSON can drift.
- Gateway owns agent execution. Companion owns device auth and approved
  NAS-local capabilities. The App owns mobile interaction quality.

## Product Feel

The intended feel is dense, calm, operator-grade, and mobile-native. Prefer scan-friendly screens, compact controls, clear status, safe confirmations, and direct recovery paths over marketing-style UI.

## Fresh-Session Reading

Follow `AGENTS.md`: read `CURRENT.md` first if it exists (it is local-only and gitignored — a fresh clone won't have one), then only the `PROJECT_SPEC.md` sections listed there. Read this file only when product intent or tradeoffs are unclear.
