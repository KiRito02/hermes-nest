# Hermes Nest Companion Contract

This document and the contract tests under `tests/` define the versioned
App-facing Companion interface. Companion-native routes use
`/companion/v1`; verified Gateway-compatible routes may later be forwarded
without moving into this namespace.

## Conventions

- Request and response bodies are UTF-8 JSON unless an endpoint explicitly
  documents another media type.
- Successful JSON responses include only documented fields. Clients must
  tolerate additive fields.
- Credentials are carried only in the `Authorization` header. They never
  appear in URLs, query strings, or error bodies.
- Companion responses use `Cache-Control: no-store`.

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
      "gateway_proxy": false
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
