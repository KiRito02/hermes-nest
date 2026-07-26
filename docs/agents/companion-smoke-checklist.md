# Hermes Nest Companion Live-Smoke Checklist

Owner-run smoke for the App → Companion → loopback Gateway contract.

Issue #1's implementation contract is `Companion/CONTRACT.md`. Run the commands
from `Companion/README.md`; this checklist defines only the sanitized evidence
to retain.

## Safety

- Run against the owner's intended Hermes Agent host deployment.
- Never put `API_SERVER_KEY` on the App-facing side.
- Never paste or commit a device credential, pairing secret, Gateway key,
  private hostname, filesystem path, Memory content, prompt, or uploaded file.
- Never put credentials in a URL/query string or enable shell tracing.
- Use disposable test data under a dedicated allowed workspace root.
- Sanitize all evidence before attaching it to an Issue/PR.

## Setup evidence

Record without secrets:

- Companion version/commit and contract fixture version;
- Hermes Agent version/package/container commit;
- pinned upstream source commit used for comparison;
- test date/time, timezone, transport, and certificate trust;
- whether Companion and Gateway share a host/container network;
- configured allowed-root count, not private root paths.

The read-only upstream checkout belongs at `.codex-tmp/hermes-agent/`. Record
its clean status and commit before using it as evidence. Never modify it.

## Step 1 — Companion liveness

Probe `GET /companion/v1/health` through loopback and the selected Lucky or
Tailscale HTTPS origin.

Green:

- bounded success response with version/protocol metadata;
- no device, Gateway, path, config, or secret disclosure;
- Gateway-down can be represented without making Companion liveness undecodable.

## Step 2 — Pairing and device authentication

Generate a short-lived, single-use pairing secret on the Hermes Agent host
using the
`python -m hermex_companion pairing create --expires-in 300` command documented
in `Companion/README.md`.

Green:

- first claim produces one device identity/credential;
- replay and expiry fail;
- valid device auth returns Companion capabilities;
- wrong/revoked device auth is distinct from network and Gateway failure;
- App-facing evidence never contains `API_SERVER_KEY`.

Use a disposable test device identity and revoke it during cleanup.

## Step 3 — Gateway readiness and capability merge

Green:

- Companion reports Gateway reachable/authorized/compatible separately;
- sanitized Gateway capabilities are present when reachable;
- unknown/additive Companion and Gateway fields decode;
- local Gateway 401/403 never echoes the Gateway key;
- App never needs direct access to port 8642.

For comparison, probe Gateway only from the Hermes Agent host and follow the
evidence order in
`AGENTS.md`.

## Step 4 — SSE passthrough

Use a disposable run/session after its implementation issue lands.

Green:

- comments, split frames, unknown events, and ordering survive Companion;
- `run_id`, session identity, stop, approval, and terminal state remain
  Gateway-authoritative;
- Companion does not buffer visible progress excessively;
- reconnect/status uses the existing identity and never resends the prompt.

## Step 5 — allowed workspace and upload

Use a disposable allowed root containing safe text, image, binary, symlink, and
oversized fixtures.

Green:

- browse/preview/download remain within the allowed root;
- traversal, symlink escape, sensitive path, special file, and oversize fail;
- upload streams with progress and cancellation;
- failure/cancel leaves no published partial file;
- success is atomic and collision behavior matches the contract;
- an existing authorized host file stages server-side without a phone
  download/upload round trip;
- the verified upload-to-turn strategy makes the file available to Hermes.

## Step 6 — built-in Memory

Use an isolated Hermes home/profile fixture, never the owner's real Memory for
destructive smoke.

Green:

- read returns bounded content/metadata;
- add/replace/remove preserve Hermes limits and structure;
- stale and concurrent writes fail or reconcile exactly as specified;
- reset requires explicit confirmation and affects only the selected target;
- no Memory content appears in logs.

## Step 7 — compare sources

Compare the live behavior with:

1. versioned Companion contract/tests;
2. the owner's running Companion;
3. for proxied behavior, local Gateway evidence;
4. official Hermes Agent API Server documentation;
5. pinned `gateway/platforms/api_server.py` and matching tests.

Dashboard and HermesPilot Link code are implementation references only; their
route names are not Companion contract evidence.

## Green criteria

The smoke is green when:

1. Companion liveness, pairing, device auth, revocation, and capabilities pass.
2. Gateway readiness and capabilities are sanitized and correctly classified.
3. SSE identity/ordering/reconnect semantics remain Gateway-authoritative.
4. Workspace/upload and built-in Memory safety tests pass in isolated fixtures.
5. No secret or private content appears in URLs, logs, fixtures, or the repo.
6. Every live/docs/source mismatch is resolved or blocks implementation.

Record the sanitized outcome in the selected Issue/PR and local `CURRENT.md`.
