# Legacy Hermes-WebUI Contract Runbook — Retired

This file is retained only as a migration marker.

The former `hermes-webui` SHA pins, route watcher, cookie-auth smoke, and
WebUI Docker contract plan are not compatibility sources for Hermes Nest.
Their workflows, scripts, and pin files were removed during the earlier
Gateway migration.

Current contract evidence uses:

1. versioned Companion contract/tests and sanitized live Companion evidence;
2. for proxied behavior, sanitized local Gateway evidence;
3. official Hermes Agent API Server documentation;
4. matching pinned `NousResearch/hermes-agent` source and tests.

See:

- [`PROJECT_SPEC.md`](PROJECT_SPEC.md) §§0 and 4
- [`docs/agents/companion-smoke-checklist.md`](docs/agents/companion-smoke-checklist.md)
- [`docs/agents/feature-gap-index.md`](docs/agents/feature-gap-index.md)

The previous WebUI contract plan remains available in Git history.
