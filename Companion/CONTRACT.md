# Hermes Nest Companion Contract

This document and the contract tests under `tests/` define the versioned
App-facing Companion interface. Companion-native routes use
`/companion/v1`; verified Gateway-compatible routes are forwarded
without moving into this namespace.

## Conventions

- Request and response bodies are UTF-8 JSON unless an endpoint explicitly
  documents another media type.
- Successful JSON responses include only documented fields. Clients must
  tolerate additive fields.
- Credentials are carried only in the `Authorization` header. They never
  appear in URLs, query strings, or error bodies.
- JSON and framework responses use `Cache-Control: no-store`. Successful SSE
  responses use `Cache-Control: no-cache` and `X-Accel-Buffering: no`.

## Liveness

`GET /companion/v1/health` is unauthenticated and reports only whether the
Companion process can serve its versioned contract. Gateway availability does
not change this response.

Success: `200 application/json`

```json
{
  "status": "ok",
  "service": "hermex-companion",
  "companion_version": "0.1.0",
  "contract_version": "1"
}
```

The response must not contain device, Gateway, filesystem, configuration,
hostname, credential, or private deployment details.

## Process entrypoint

Run the development or installed source tree with:

```bash
PYTHONPATH=src python -m hermex_companion
```

The process binds `127.0.0.1:8643` by default. `--host` and `--port` provide
explicit deployment overrides; release configuration keeps the host on
loopback so Lucky or Tailscale HTTPS can proxy to it.

## Pairing

Create a short-lived, single-use pairing secret locally on the NAS:

```bash
PYTHONPATH=src python -m hermex_companion pairing create --expires-in 300
```

The command writes only the URL-safe secret to stdout. It uses
`$XDG_STATE_HOME/hermex-companion/companion.sqlite3`, falling back to the
platform XDG state default when `XDG_STATE_HOME` is unset.

Claim the secret from the App with:

`POST /companion/v1/pairings/claim`

```json
{
  "secret": "<single-use-secret>",
  "device_name": "Owner iPad"
}
```

Success: `201 application/json`

```json
{
  "device": {
    "id": "<uuid>",
    "name": "Owner iPad"
  },
  "credential": "<device-bearer-credential>",
  "credential_type": "Bearer"
}
```

The credential is returned only by this successful claim. Companion stores
only cryptographic hashes of pairing secrets and device credentials.

Pairing failure codes:

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | `invalid_request` | Missing, malformed, or out-of-bounds input |
| 401 | `pairing_secret_invalid` | Secret was never issued |
| 409 | `pairing_secret_used` | Secret was already claimed |
| 410 | `pairing_secret_expired` | Secret expired before claim |

Errors use the common shape:

```json
{
  "error": {
    "code": "pairing_secret_used",
    "message": "Pairing secret has already been used."
  }
}
```

## Device authentication and revocation

Authenticated requests carry:

```http
Authorization: Bearer <device-credential>
```

Missing, malformed, or unknown credentials return
`401 device_credential_invalid`. A known revoked credential returns
`403 device_revoked`.

`GET /companion/v1/devices` returns at most 256 device records with bounded
metadata:

```json
{
  "devices": [
    {
      "id": "<uuid>",
      "name": "Owner iPad",
      "created_at": "2026-07-25T00:00:00Z",
      "last_seen_at": "2026-07-25T00:01:00Z",
      "revoked": false
    }
  ]
}
```

Credentials and credential hashes are never included.

`DELETE /companion/v1/devices/{device_id}` revokes the selected device and
returns `204`. Revocation is idempotent. An unknown device ID returns
`404 device_not_found`.

## Capabilities

`GET /companion/v1/capabilities` requires device authentication and always
returns Companion-native capabilities. It also reports a sanitized Gateway
capability snapshot when Gateway is reachable, authorized, and compatible.

```json
{
  "object": "hermex.companion.capabilities",
  "contract_version": "1",
  "companion": {
    "version": "0.1.0",
    "features": {
      "pairing": true,
      "device_auth": true,
      "device_revocation": true,
      "gateway_discovery": true,
      "gateway_proxy": true,
      "model_options_proxy": true,
      "session_model_lock_proxy": true,
      "skills_proxy": true,
      "toolsets_proxy": true
    },
    "endpoints": {
      "health": {
        "method": "GET",
        "path": "/companion/v1/health"
      },
      "pairing_claim": {
        "method": "POST",
        "path": "/companion/v1/pairings/claim"
      },
      "devices": {
        "method": "GET",
        "path": "/companion/v1/devices"
      },
      "device_revoke": {
        "method": "DELETE",
        "path": "/companion/v1/devices/{device_id}"
      },
      "capabilities": {
        "method": "GET",
        "path": "/companion/v1/capabilities"
      },
      "readiness": {
        "method": "GET",
        "path": "/companion/v1/readiness"
      },
      "model_options": {
        "method": "GET",
        "path": "/api/model/options"
      },
      "session_model_lock": {
        "method": "POST",
        "path": "/api/sessions/{session_id}/model"
      },
      "skills": {
        "method": "GET",
        "path": "/v1/skills"
      },
      "toolsets": {
        "method": "GET",
        "path": "/v1/toolsets"
      }
    }
  },
  "gateway": {
    "status": "ok",
    "capabilities": {
      "object": "hermes.api_server.capabilities",
      "platform": "hermes-agent",
      "auth": {
        "type": "bearer",
        "required": true
      },
      "runtime": {
        "mode": "server_agent",
        "tool_execution": "server",
        "split_runtime": false
      },
      "features": {},
      "endpoints": {}
    }
  }
}
```

Gateway status is one of `ok`, `unavailable`, `unauthorized`, or
`incompatible`. When status is not `ok`, `capabilities` is `null`.

Sanitization drops model identifiers, free-form runtime descriptions, unknown
nested feature values, and all other top-level Gateway fields. It retains
boolean feature values, bounded `X-...` header-name feature values, and valid
method/path endpoint descriptors. `API_SERVER_KEY` and the Companion's
Gateway credential never appear in this response.

## Readiness

`GET /companion/v1/readiness` requires device authentication and returns
bounded Companion and Gateway state:

```json
{
  "status": "ok",
  "companion": {
    "status": "ok",
    "version": "0.1.0",
    "contract_version": "1"
  },
  "gateway": {
    "status": "ok",
    "platform": "hermes-agent",
    "version": "0.19.0"
  }
}
```

Top-level status is `ok` only when Gateway status is `ok`; otherwise it is
`degraded`. Gateway status is `ok`, `degraded`, `unavailable`,
`unauthorized`, or `incompatible`. Platform and version are `null` unless a
compatible Gateway response supplies them. Gateway PID, configured platforms,
agent counts, paths, and detailed readiness checks are never returned.

## Gateway-compatible sessions

Every route below requires device authentication. Companion removes the device
`Authorization` header, sends only its NAS-local Gateway bearer credential over
loopback, and never forwards other App request headers. Redirects are not
followed. `HEAD` is not an alias for either supported GET resource and returns
`405` without contacting Gateway.

This contract was verified against Hermes Agent `0.19.0`, upstream commit
`07e97d2f5dc3d2092cfe693ef07b2527a36cd2d8`, its session API tests, the
official API Server documentation, and the owner's running loopback Gateway.

The supported query fields are:

| Field | Bounds |
| --- | --- |
| `limit` | ASCII integer from 0 through 200 |
| `offset` | ASCII integer from 0 through 1,000,000 |
| `source` | At most 128 characters and no control characters |
| `include_children` | `0`, `1`, `false`, `no`, `off`, `on`, `true`, or `yes`, case-insensitive |

Each field may occur at most once. Unknown, repeated, or out-of-bounds fields
return `400 invalid_query` without contacting Gateway. Accepted values and
their order are forwarded unchanged; Hermes remains responsible for their
normalization and list semantics.

The exact lifecycle allowlist is:

| Method | Path | Request body |
| --- | --- | --- |
| POST | `/api/sessions` | Gateway-compatible JSON object |
| GET | `/api/sessions/{id}` | none |
| PATCH | `/api/sessions/{id}` | `title` and/or `end_reason` |
| DELETE | `/api/sessions/{id}` | none |
| GET | `/api/sessions/{id}/messages` | none |
| POST | `/api/sessions/{id}/fork` | Gateway-compatible JSON object |

Resource routes reject all query parameters. JSON bodies must be objects and
are limited to 16 KiB. Session IDs are a single bounded path segment. Unknown
methods, suffixes, repeated path segments, implicit HEAD, non-JSON bodies, and
invalid IDs never reach Gateway.

Success is `200 application/json`. After validating the bounded core shape,
Companion returns the Gateway JSON bytes without renaming fields:

```json
{
  "object": "list",
  "data": [
    {
      "id": "<session-id>",
      "title": "Example",
      "source": "api_server",
      "message_count": 3,
      "started_at": 1721000000.0,
      "last_active": 1721000100.0
    }
  ],
  "limit": 50,
  "offset": 0,
  "has_more": false
}
```

Clients tolerate additive outer and session fields. Companion requires the
documented outer field types and object rows, limits the response to 2 MiB, and
uses its bounded Gateway timeout.

Lifecycle successes preserve the Gateway status and JSON bytes after validating
the corresponding `hermes.session`, `hermes.session.deleted`, or message-list
core shape. Safe Gateway client failures (`400`, `404`, and `409`) also preserve
their status and a bounded `error.code` / `error.message` envelope so the App
can distinguish invalid metadata, a missing session, and an identity conflict.
Unknown error fields are dropped at the Companion boundary.

Hermes Agent 0.19.0 returns message history as
`{"object":"list","session_id":"...","data":[...]}` and does not implement
`limit` or `offset` on `/messages`; the owner's live Gateway ignores those
queries. Companion therefore forwards the complete bounded message response.
The App presents it in stable local pages without claiming upstream pagination,
reordering rows, or creating a Companion-owned transcript.

## Gateway-compatible model selection

Every route below requires device authentication. Companion replaces the App
device bearer with its NAS-local Gateway bearer, strips other App headers, and
does not follow redirects:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/model/options` | Read the native Hermes provider/model picker inventory |
| POST | `/api/sessions/{id}/model` | Persist a model and reasoning lock on one existing session |

This surface was implemented from Hermes Agent `main` commit
`d9f1043c3337818b1f29224a7deb5bbb17402370` and accepted against the owner's
upgraded `main` commit
`37a27664cc11a33d36739fafe864d1d084370c47`. The latter contains the former,
with no intervening changes to the API Server file or corresponding Gateway
tests. Its source and tests verify both routes; the official API Server
documentation additionally verifies model options and per-Run overrides, but
does not yet document the session model-lock route or acknowledgement.

Live acceptance at `37a27664` verified the advertised capability and exact
route, a bounded model inventory through Companion, and a disposable
session-lock acknowledgement with matching session/model/provider identity.
The disposable session was then deleted. The CLI still reports product version
`0.19.0`, so capability advertisement rather than that version string gates
the App controls.

Model options accept no query or exactly one `refresh` boolean. The accepted
spellings are `0`, `1`, `false`, `no`, `off`, `on`, `true`, and `yes`,
case-insensitive. The success body retains the Gateway's additive picker
metadata after validating the stable provider identity and model-list fields.
Responses are capped at 2 MiB; this inventory route has a 30-second timeout
because an explicit refresh may probe provider catalogs:

```json
{
  "providers": [
    {
      "slug": "openrouter",
      "name": "OpenRouter",
      "models": ["anthropic/claude-sonnet-4.6"],
      "authenticated": true,
      "capabilities": {
        "anthropic/claude-sonnet-4.6": {
          "fast": false,
          "reasoning": true
        }
      }
    }
  ],
  "model": "anthropic/claude-sonnet-4.6",
  "provider": "openrouter"
}
```

The App offers only authenticated providers with non-empty model lists.
Unconfigured provider skeletons remain decodable but are not presented as
runnable choices.

The session model-lock request has an exact Companion allowlist. `model` and
`provider` are required bounded strings. `model_options` is optional; when
present it may contain only a consistent Hermes reasoning pair:

```json
{
  "model": "anthropic/claude-sonnet-4.6",
  "provider": "openrouter",
  "model_options": {
    "reasoning": {"enabled": true, "effort": "high"},
    "reasoning_effort": "high"
  }
}
```

Effort is one of `none`, `minimal`, `low`, `medium`, `high`, or `xhigh`;
`enabled` must be false only for `none`. Companion rejects credential,
base-URL, service-tier, unknown, or inconsistent fields before Gateway. A
successful Gateway acknowledgement is
`hermes.session.model_lock`, carries the same session identity, and returns a
runtime model/provider matching the selection. The App changes its visible
selection only after this acknowledgement, then sends the same model,
provider, and reasoning options on subsequent Runs. The persisted lock remains
authoritative if another client later resumes the Hermes session.

## Gateway-compatible Skills and Toolsets discovery

`GET /v1/skills` and `GET /v1/toolsets` are the only discovery routes exposed
by this slice. Both require the App's device bearer, accept no query string or
request body, reject implicit HEAD, and replace the device bearer with the
NAS-local Gateway bearer. Companion never exposes Skill/Toolset mutation
routes or forwards other App headers.

This contract was verified against the owner's live Gateway on Hermes Agent
commit `37a27664cc11a33d36739fafe864d1d084370c47`, its matching source/tests,
and the official API Server documentation. Gateway capabilities advertise
`features.skills_api == true` plus exact `endpoints.skills` and
`endpoints.toolsets` descriptors. This upstream pin has no separate
`toolsets_api` feature. The App therefore enables discovery only when both
exact endpoint descriptors and `skills_api` are present on the Gateway
snapshot and both proxy features/endpoints are present on Companion.

Skills success is `200 application/json`:

```json
{
  "object": "list",
  "data": [
    {
      "name": "github-pr-workflow",
      "description": "Review and publish a pull request.",
      "category": "github"
    }
  ]
}
```

`name` is the stable identity. `description` is a string and `category` is a
string or null. Gateway filters disabled Skills for the active API Server
platform and sorts rows by `(category-or-empty, name)`. It does not supply an
enabled/configured field, so neither Companion nor App invents one.

Toolsets success is `200 application/json`:

```json
{
  "object": "list",
  "platform": "api_server",
  "data": [
    {
      "name": "file",
      "label": "File Tools",
      "description": "Read and write files.",
      "enabled": true,
      "configured": true,
      "tools": ["read_file", "write_file"]
    }
  ]
}
```

`name` is the stable identity. Gateway preserves its configurable-toolset
declaration order. `enabled` and `configured` are booleans. `tools` is sorted
and unique; if one upstream toolset cannot resolve, Gateway preserves its row
with an empty tools list.

Both envelopes allow additive fields but enforce the verified identity and
field types. Responses are capped at 2 MiB and 2,048 rows. Names, labels,
categories, descriptions, tool names, and per-toolset membership have fixed
bounds. Gateway auth, transport, 5xx, malformed JSON, unsupported media type,
oversize, and incompatible-shape failures use bounded sanitized errors and
never return raw upstream details.

## Gateway-compatible Runs

Every route below requires device authentication and accepts no query
parameters. Companion replaces the App device bearer with its NAS-local
Gateway bearer, strips all other App headers, and does not follow redirects.
Run IDs are single bounded path segments. Unsupported methods, suffixes,
implicit HEAD, and invalid IDs never reach Gateway.

This contract was verified against Hermes Agent `0.19.0`, upstream commit
`07e97d2f5dc3d2092cfe693ef07b2527a36cd2d8`, its Runs tests and source, the
official API Server documentation, and disposable runs on the owner's loopback
Gateway. The optional `model`, `provider`, and `model_options` request override
shown below is additionally pinned to Hermes Agent `main` commit
`d9f1043c3337818b1f29224a7deb5bbb17402370` and was live-accepted on descendant
commit `37a27664cc11a33d36739fafe864d1d084370c47`.

The exact allowlist is:

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/v1/runs` | Start a run |
| GET | `/v1/runs/{run_id}` | Read authoritative status |
| GET | `/v1/runs/{run_id}/events` | Consume ordered SSE |
| POST | `/v1/runs/{run_id}/stop` | Request interruption |
| POST | `/v1/runs/{run_id}/approval` | Resolve one pending approval |

Start requires a JSON object and permits up to and including 2 MiB so an
existing server-authoritative conversation can be supplied:

```json
{
  "input": "Continue",
  "session_id": "<session-id>",
  "conversation_history": [
    {"role": "user", "content": "Earlier question"},
    {"role": "assistant", "content": "Earlier answer"}
  ],
  "model": "anthropic/claude-sonnet-4.6",
  "provider": "openrouter",
  "model_options": {
    "reasoning": {"enabled": true, "effort": "high"},
    "reasoning_effort": "high"
  }
}
```

Optional verified Gateway fields such as `instructions`, `model`, `provider`,
`model_options`, and `previous_response_id` pass through unchanged. Companion
does not synthesize history, run IDs, or session IDs. Hermes Agent 0.19.0 uses explicit
`conversation_history` as turn context; `session_id` alone correlates and
persists the run but does not load the existing SessionDB transcript. The App
therefore reads current history before start and sends it explicitly.

Start success is `202 application/json`:

```json
{"run_id":"<run-id>","status":"started"}
```

Status success is `200 application/json` and retains terminal runs:

```json
{
  "object": "hermes.run",
  "run_id": "<run-id>",
  "status": "completed",
  "session_id": "<session-id>",
  "created_at": 1721000000.0,
  "updated_at": 1721000010.0,
  "last_event": "run.completed",
  "output": "Final response",
  "usage": {
    "input_tokens": 144,
    "output_tokens": 34,
    "total_tokens": 178
  }
}
```

Core states are `queued`, `running`, `waiting_for_approval`, `stopping`,
`completed`, `failed`, and `cancelled`. Clients tolerate additive fields and
unknown future states without collapsing them into a terminal success. When
Gateway supplies terminal token accounting, `usage` is an optional object with
optional, non-negative integer `input_tokens`, `output_tokens`, and
`total_tokens`. Companion forwards it unchanged; it does not estimate missing
values.

Stop success is `200 application/json` with
`{"run_id":"<run-id>","status":"stopping"}`. `stopping` remains distinct from
`cancelled`; the App reconciles through status or a later terminal event.
Repeated UI stop actions are coalesced and never create another run. If the
stop response is lost, the App retains the stop latch and reconciles the same
`run_id` rather than sending an ambiguous second stop request.

Approval submission is capability-gated by the Gateway
`approval_events`/`run_approval_response` features and `run_approval` endpoint.
It accepts only one canonical, server-offered decision:

```json
{"choice":"once"}
```

Supported choices are `once`, `session`, `always`, and `deny`. Companion
intentionally rejects Gateway aliases, `all`, `resolve_all`, unknown fields,
queries, and non-JSON bodies so one App action can resolve only the next
pending item on the exact existing `run_id`. Hermes Agent 0.19.0 exposes no
separate approval ID; Companion does not invent one. Success is
`200 application/json`:

```json
{
  "object": "hermes.run.approval_response",
  "run_id": "<run-id>",
  "choice": "once",
  "resolved": 1
}
```

The returned `run_id` must match the requested run. A missing run remains 404;
an inactive, already-resolved, or expired approval remains a sanitized 409.
The App reconciles either outcome through the authoritative status of that
same run and never restarts it or resends its prompt.

Events success is `200 text/event-stream`. Companion forwards each upstream
byte chunk as it arrives without JSON decoding, re-encoding, buffering, event
reordering, or automatic stop. This preserves `data:` records, future
transport `event:` fields, comments such as `: keepalive` and
`: stream closed`, and upstream event/run IDs. Current semantic event names
include `message.delta`, `reasoning.available`, `tool.started`,
`tool.completed`, `run.completed`, `run.failed`, and `run.cancelled`;
additional approval and future event families remain additive. The App parses
transport `event:` and JSON `data.event` independently, uses the JSON semantic
event when both are present, coalesces deltas behind a bounded progressive
presentation queue, and preserves a stable Tool Card when upstream supplies a
tool-call ID. Hermes Agent 0.19.0 Runs events omit that ID; current cards use
observed name/order as a best-effort fallback, so simultaneous same-name tools
cannot be correlated exactly until Gateway emits an identity.

Terminal SSE data may carry the same optional `usage` object as status. Because
some terminal events omit it, the App reads the authoritative status once after
such an event. A failed usage refresh never changes an already-observed terminal
result.

If SSE disconnects after subscription, the Gateway may release that transport
queue while retaining authoritative run status. Recovery polls the same
`run_id`. If status is `waiting_for_approval` but the original request event
is no longer available, the App presents a non-actionable waiting state rather
than guessing hidden context or submitting a blind approval. Stop remains
available. Terminal recovery refreshes session history. Neither Companion nor
App automatically resubmits the prompt.

Safe Gateway client failures (`400`, `404`, `409`, and `429`) preserve their
status and only the bounded `error.code` / `error.message` envelope. JSON
responses are capped at 2 MiB. The SSE connection has a bounded connect
timeout but no total/read timeout; Gateway keepalives and run completion own
its lifetime.

Gateway failures use the common bounded error envelope:

| Status | Code | Meaning |
| --- | --- | --- |
| 502 | `gateway_unauthorized` | Gateway rejected the NAS-local credential |
| 503 | `gateway_unavailable` | Gateway returned a server failure |
| 502 | `gateway_incompatible` | Unsupported status, media type, or success shape |
| 502 | `gateway_malformed_response` | Success body was not valid JSON |
| 502 | `gateway_response_too_large` | Response exceeded 2 MiB |
| 504 | `gateway_timeout` | Bounded Gateway request timed out |
| 503 | `gateway_transport_failure` | Companion could not establish or maintain the loopback request |

Gateway server/auth/transport details, response headers, credentials, loopback
addresses, and redirect targets are not returned to the App.
