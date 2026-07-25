# Hermes Agent Direct Live-Smoke Checklist

Owner-run, read-only smoke for the direct Hermes Agent API Server contract.

Use it when implementing or revalidating the direct connection foundation.
Later session/run issues extend this checklist with their own disposable-data
steps; do not preemptively probe or mutate undocumented routes here.

## Safety

- Run against the owner's intended NAS endpoint.
- Never paste or commit `API_SERVER_KEY`.
- Never put the key in a URL/query string.
- Do not capture shell tracing (`set -x`) or verbose curl headers containing
  `Authorization`.
- This checklist performs no server mutation.
- Sanitize hostnames and any deployment-specific metadata before attaching
  evidence to an Issue/PR.

## Setup

```bash
BASE="https://<your-hermes-host>"
read -rs -p "Hermes API key: " API_KEY
echo
```

The read-only upstream source checkout belongs at:

```text
.codex-tmp/hermes-agent/
```

Clone it if missing:

```bash
git clone https://github.com/NousResearch/hermes-agent .codex-tmp/hermes-agent
```

Record its state before using it as evidence:

```bash
git -C .codex-tmp/hermes-agent status --short
git -C .codex-tmp/hermes-agent rev-parse HEAD
```

Do not modify the pinned checkout.

## Step 1 — Record the installed server identity

Record the Hermes Agent version, package/container version, or source commit
using the same deployment method that installed the NAS server. If the
deployment cannot report a reliable commit, record that limitation instead of
guessing.

Also record:

- test date/time and timezone;
- transport type (reverse proxy, Cloudflare, Tailscale HTTPS, or local);
- whether the certificate is system trusted;
- upstream source commit used for comparison.

Do not record the private hostname in a public Issue unless the owner approves.

## Step 2 — Public liveness

```bash
curl -sS \
  -w '\nHTTP %{http_code}  Content-Type %{content_type}\n' \
  "$BASE/health"
```

Green:

- HTTP 200;
- JSON content type;
- a decodable JSON object whose documented status is healthy.

This does not prove authentication or compatibility.

## Step 3 — Authenticated capabilities

```bash
curl -sS \
  -H "Authorization: Bearer $API_KEY" \
  -w '\nHTTP %{http_code}  Content-Type %{content_type}\n' \
  "$BASE/v1/capabilities"
```

Green:

- HTTP 200;
- JSON content type;
- a decodable object;
- authentication metadata and feature/endpoint information are present when
  advertised by the installed server;
- unknown/additive fields are accepted.

Save only a sanitized response fixture. The app must not require optional
fields that the live server omits.

## Step 4 — Authentication failure classification

Use an intentionally wrong disposable value, never the real key:

```bash
curl -sS \
  -H 'Authorization: Bearer intentionally-wrong-smoke-key' \
  -w '\nHTTP %{http_code}  Content-Type %{content_type}\n' \
  "$BASE/v1/capabilities"
```

Green:

- server returns 401 or 403;
- response does not echo either the wrong key or deployment secrets;
- the app fixture can classify this separately from network failure and
  healthy-but-incompatible decoding.

## Step 5 — Optional bounded readiness

Run only if `/v1/capabilities` or the installed version documents
`/health/detailed`:

```bash
curl -sS \
  -H "Authorization: Bearer $API_KEY" \
  -w '\nHTTP %{http_code}  Content-Type %{content_type}\n' \
  "$BASE/health/detailed"
```

Before saving evidence, inspect it for hostnames, paths, provider details, or
other deployment metadata and redact conservatively.

## Step 6 — Compare sources

Compare the live behavior with:

1. https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server
2. `.codex-tmp/hermes-agent/gateway/platforms/api_server.py`
3. matching tests under `.codex-tmp/hermes-agent/tests/gateway/`

Record exact method, path, status, content type, required fields, and the
upstream commit. Do not translate or consult a `hermes-webui` route as the
direct contract.

## Green criteria

The direct connection smoke is green when:

1. `/health` is reachable and decodable.
2. The real bearer key produces a decodable `/v1/capabilities` response.
3. A wrong key produces a distinct 401/403 response.
4. No key appears in URLs, output saved to the repo, fixtures, or logs.
5. Installed server identity and matching upstream source commit are recorded.
6. Any mismatch between live wire, docs, and source is explicitly resolved or
   blocks implementation.

Record the outcome in the selected Issue/PR and local `CURRENT.md`.

Cleanup:

```bash
unset API_KEY
```
