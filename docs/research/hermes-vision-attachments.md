# Hermes Vision and Attachment Support

Research date: 2026-07-27
Upstream examined: `NousResearch/hermes-agent` `main` at
[`0fa5e41c86f022bba147797849f0b44865721476`](https://github.com/NousResearch/hermes-agent/commit/0fa5e41c86f022bba147797849f0b44865721476).

## Conclusion

- Hermes has both native multimodal routing and an auxiliary
  `vision_analyze` model path.
- Inline images are a documented and tested contract on
  `/v1/chat/completions`, `/v1/responses`,
  `/api/sessions/{session_id}/chat`, and
  `/api/sessions/{session_id}/chat/stream`.
- Inline images are **not yet a stable `/v1/runs` contract**. The Runs
  documentation specifies a simple `input` string. Its current implementation
  happens to pass the last message's `content` through, so a content-part array
  may reach the agent, but Runs does not call the multimodal validator, has no
  image-specific contract tests, and flattens earlier multimodal messages to
  text. Hermes Nest must not depend on that incidental behavior.
- Treating an image as a server-local ordinary file is viable through
  `vision_analyze`, provided Hermes can read the path. It is a tool-mediated
  fallback, not a `file_id` attachment protocol.

## Supported API shapes

| Endpoint | Stable image input | Notes |
|---|---|---|
| `/v1/chat/completions` | `text` + `image_url` | HTTP(S) or `data:image/...` |
| `/v1/responses` | `input_text` + `input_image` | HTTP(S) or `data:image/...` |
| `/api/sessions/{id}/chat[/stream]` | Both aliases, normalized to `text` + `image_url` | Covered by session API tests |
| `/v1/runs` | No documented image contract | Public contract says simple `input` string |

The common normalizer accepts `image_url` and `input_image`, canonicalizes
them, and rejects `file`, `input_file`, non-image data URLs, and unsupported
URL schemes. See
[`api_server.py` lines 466–590](https://github.com/NousResearch/hermes-agent/blob/0fa5e41c86f022bba147797849f0b44865721476/gateway/platforms/api_server.py#L466-L590)
and the
[`test_api_server_multimodal.py` contract tests](https://github.com/NousResearch/hermes-agent/blob/0fa5e41c86f022bba147797849f0b44865721476/tests/gateway/test_api_server_multimodal.py#L31-L103).
Session chat uses that same normalizer and has tests for both synchronous and
streaming requests:
[`api_server.py` lines 620–631](https://github.com/NousResearch/hermes-agent/blob/0fa5e41c86f022bba147797849f0b44865721476/gateway/platforms/api_server.py#L620-L631),
[`test_session_api.py` lines 260–317](https://github.com/NousResearch/hermes-agent/blob/0fa5e41c86f022bba147797849f0b44865721476/tests/gateway/test_session_api.py#L260-L317).

By contrast, Runs reads a simple `input`, extracts only the final message's
`content`, and does not invoke the normalizer:
[`api_server.py` lines 5983–6054](https://github.com/NousResearch/hermes-agent/blob/0fa5e41c86f022bba147797849f0b44865721476/gateway/platforms/api_server.py#L5983-L6054).
The [official API Server documentation](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server)
also documents inline images only for Chat Completions, Responses, and session
chat, while describing Runs as accepting a simple input string.

## How the vision auxiliary model is used

Hermes decides between two image-routing modes:

1. If the active main model is marked vision-capable, Hermes sends the pixels
   natively as `image_url` content.
2. Otherwise, `vision_analyze` sends the image to a configured/resolved
   auxiliary vision model and injects its text description for the text-only
   main model.

This selection is controlled by `agent.image_input_mode` (`auto`, `native`, or
`text`); automatic mode prefers native vision and uses auxiliary vision as the
fallback. See
[`image_routing.py` lines 1–36](https://github.com/NousResearch/hermes-agent/blob/0fa5e41c86f022bba147797849f0b44865721476/agent/image_routing.py#L1-L36)
and
[`image_routing.py` lines 461–506](https://github.com/NousResearch/hermes-agent/blob/0fa5e41c86f022bba147797849f0b44865721476/agent/image_routing.py#L461-L506).

`vision_analyze` is a normal Hermes tool in the `vision` toolset. Its schema
tells the model to call it for an image URL, local path, data URL, or referenced
screenshot. On vision-capable main models it can return the image itself as a
multimodal tool result; otherwise it calls the auxiliary model and returns
text. See
[`vision_tools.py` lines 1447–1523](https://github.com/NousResearch/hermes-agent/blob/0fa5e41c86f022bba147797849f0b44865721476/tools/vision_tools.py#L1447-L1523).
The auxiliary route must resolve a usable vision client or the tool is
unavailable.

## Ordinary-file fallback and limits

A Companion-uploaded image can be staged as a local file and referenced in the
Runs text, for example: “Use `vision_analyze` on `<server path>` and answer …”.
This preserves the Runs lifecycle, SSE, stop, and approval path, but has these
limits:

- The model must actually issue the tool call; there is no documented API
  Server endpoint that invokes `vision_analyze` deterministically.
- The `vision` toolset and a resolvable native/auxiliary vision backend must be
  available.
- The path must be visible to the Hermes process. With the local terminal
  backend Hermes can read host paths; with a non-local/sandbox backend, host
  reads are limited to Hermes media-cache roots and other paths are resolved
  inside the sandbox. A Companion-private path outside both is not usable.
- Image sources may be local paths, `file://`, HTTP(S), or base64 data URLs.
  Remote URLs are subject to SSRF/website-policy checks. Raw ingest is capped
  at 50 MiB and content is magic-byte checked:
  [`image_source.py` lines 1–43 and 89–145](https://github.com/NousResearch/hermes-agent/blob/0fa5e41c86f022bba147797849f0b44865721476/tools/image_source.py#L1-L145).
- This only makes image files visible to vision. PDFs, Office documents, and
  arbitrary files remain regular file/tool inputs; `file`, `input_file`, and
  `file_id` content parts are explicitly rejected by the API Server.

## Recommendation for Hermes Nest

For the first release, keep Runs as the chat control plane and implement
image handling as a capability-gated, file-backed `vision_analyze` path:
Companion stores the upload in a location Hermes is permitted to read and
injects the server-side path plus an explicit vision instruction without
exposing that path to the App.

Longer term, prefer an upstream `/v1/runs` change that reuses
`_normalize_multimodal_content`, adds Runs-specific contract tests, preserves
multimodal history, and advertises the capability. Until the owner's running
Gateway confirms such a contract, do not send `image_url`/`input_image`
directly through Runs.
