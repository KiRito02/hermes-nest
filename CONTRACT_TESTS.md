# Legacy Hermes-WebUI Contract Runbook — Retired

This file is retained only as a migration marker.

The former `hermes-webui` SHA pins, route watcher, cookie-auth smoke, and
WebUI Docker contract plan are not compatibility sources for Hermex Direct.
Their workflows, scripts, and pin files were removed during the direct Hermes
Agent API transition.

Current direct contract evidence uses:

1. sanitized live responses from the owner's Hermes Agent API Server;
2. official Hermes Agent API Server documentation;
3. matching pinned `NousResearch/hermes-agent` source and tests.

See:

- [`PROJECT_SPEC.md`](PROJECT_SPEC.md) §§0 and 4
- [`docs/agents/direct-api-smoke-checklist.md`](docs/agents/direct-api-smoke-checklist.md)
- [`docs/agents/feature-gap-index.md`](docs/agents/feature-gap-index.md)

The previous WebUI contract plan remains available in Git history.

