"""Sanitized discovery of the loopback Hermes Gateway."""

import asyncio
from dataclasses import dataclass
import io
import json
import re
from collections.abc import Sequence
from urllib.parse import urlsplit

from aiohttp import ClientError, ClientResponse, ClientSession, ClientTimeout
from hermex_companion.model_proxy_contract import (
    MODEL_OPTIONS_PATH,
    MODEL_OPTIONS_TIMEOUT_SECONDS,
    is_model_lock_payload,
    is_model_options_payload,
    validated_model_options_query,
)
from hermex_companion.run_proxy_contract import (
    RUN_REQUEST_MAX_BODY_BYTES,
    is_run_payload,
    run_events_path,
    run_request_contract,
)
from hermex_companion.session_proxy_contract import (
    GatewayProxyError,
    GatewayProxyResponse,
    SESSION_LIST_PATH,
    SESSION_REQUEST_MAX_BODY_BYTES,
    is_session_list_payload,
    is_session_payload,
    read_bounded_session_response,
    sanitized_gateway_error,
    session_request_contract,
    validated_session_list_query,
)

CAPABILITIES_OBJECT = "hermes.api_server.capabilities"
CAPABILITIES_PATH = "/v1/capabilities"
READINESS_PATH = "/health/detailed"
LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}
SAFE_NAME = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
SAFE_HEADER_NAME = re.compile(r"^X-[!#$%&'*+\-.^_`|~0-9A-Za-z]{1,126}$")
SAFE_PATH = re.compile(r"^/[A-Za-z0-9._~!$&'()*+,;=:@%/{}/-]{0,255}$")
SAFE_METHODS = {"DELETE", "GET", "PATCH", "POST", "PUT"}


@dataclass(frozen=True)
class GatewayCapabilitySnapshot:
    status: str
    capabilities: dict[str, object] | None


@dataclass(frozen=True)
class GatewayReadinessSnapshot:
    status: str
    platform: str | None
    version: str | None


@dataclass
class GatewayRunEventStream:
    """Owned upstream response whose bytes must be consumed incrementally."""

    session: ClientSession
    response: ClientResponse

    async def close(self) -> None:
        self.response.close()
        await self.session.close()


class GatewayRunHTTPError(Exception):
    """Sanitized non-success response received before SSE headers."""

    def __init__(self, response: GatewayProxyResponse) -> None:
        super().__init__(f"Gateway run events returned {response.status}")
        self.response = response


class GatewayDiscovery:
    """Hide Gateway authentication, transport errors, and sanitization."""

    def __init__(self, base_url: str, api_key: str, *, timeout: float = 3.0) -> None:
        parsed = urlsplit(base_url)
        if (
            parsed.scheme != "http"
            or parsed.hostname not in LOOPBACK_HOSTS
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("Gateway URL must be an HTTP loopback URL")
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._timeout_seconds = timeout
        self._timeout = ClientTimeout(total=timeout)

    async def capabilities(self) -> GatewayCapabilitySnapshot:
        status, payload = await self._get_json(CAPABILITIES_PATH)
        if status != "ok":
            return GatewayCapabilitySnapshot(status, None)

        sanitized = _sanitize_capabilities(payload)
        if sanitized is None:
            return GatewayCapabilitySnapshot("incompatible", None)
        return GatewayCapabilitySnapshot("ok", sanitized)

    async def readiness(self) -> GatewayReadinessSnapshot:
        status, payload = await self._get_json(READINESS_PATH)
        if status != "ok":
            return GatewayReadinessSnapshot(status, None, None)

        if not isinstance(payload, dict):
            return GatewayReadinessSnapshot("incompatible", None, None)
        readiness_status = payload.get("status")
        platform = payload.get("platform")
        version = payload.get("version")
        if (
            readiness_status not in {"ok", "degraded"}
            or platform != "hermes-agent"
            or not isinstance(version, str)
            or not version
            or len(version) > 64
        ):
            return GatewayReadinessSnapshot("incompatible", None, None)
        return GatewayReadinessSnapshot(readiness_status, platform, version)

    async def list_sessions(
        self,
        query_items: Sequence[tuple[str, str]],
    ) -> bytes:
        """Forward the verified session-list surface with Gateway-only auth."""
        query = validated_session_list_query(query_items)
        _, response_body, payload = await self._proxy_json_request(
            "GET",
            SESSION_LIST_PATH,
            allowed_statuses=frozenset({200}),
            query=query,
        )
        if not is_session_list_payload(payload):
            raise GatewayProxyError(
                502,
                "gateway_incompatible",
                "The Hermes Gateway session-list shape is incompatible.",
            )
        return response_body

    async def model_options(
        self,
        query_items: Sequence[tuple[str, str]],
    ) -> bytes:
        """Forward the verified native Hermes model-picker inventory."""
        query = validated_model_options_query(query_items)
        _, response_body, payload = await self._proxy_json_request(
            "GET",
            MODEL_OPTIONS_PATH,
            allowed_statuses=frozenset({200}),
            query=query,
            timeout=ClientTimeout(total=MODEL_OPTIONS_TIMEOUT_SECONDS),
        )
        if not is_model_options_payload(payload):
            raise GatewayProxyError(
                502,
                "gateway_incompatible",
                "The Hermes Gateway model-options shape is incompatible.",
            )
        return response_body

    async def lock_session_model(
        self,
        session_id: str,
        body: bytes,
    ) -> GatewayProxyResponse:
        """Persist one verified model selection on an existing session."""
        session_path = session_request_contract(
            "GET",
            session_id=session_id,
            action=None,
        ).path
        status, response_body, payload = await self._proxy_json_request(
            "POST",
            f"{session_path}/model",
            allowed_statuses=frozenset({200, 400, 404, 409}),
            body=body,
        )
        if status == 200:
            if not is_model_lock_payload(payload, session_id=session_id):
                raise GatewayProxyError(
                    502,
                    "gateway_incompatible",
                    "The Hermes Gateway model-lock response is incompatible.",
                )
        else:
            sanitized_error = sanitized_gateway_error(payload)
            if sanitized_error is None:
                raise GatewayProxyError(
                    502,
                    "gateway_incompatible",
                    "The Hermes Gateway error response is incompatible.",
                )
            response_body = json.dumps(
                sanitized_error,
                separators=(",", ":"),
            ).encode("utf-8")
        return GatewayProxyResponse(status, response_body)

    async def session_request(
        self,
        method: str,
        *,
        session_id: str | None = None,
        action: str | None = None,
        body: bytes | None = None,
    ) -> GatewayProxyResponse:
        """Forward one exact verified session lifecycle resource."""
        contract = session_request_contract(
            method,
            session_id=session_id,
            action=action,
        )
        if body is not None and len(body) > SESSION_REQUEST_MAX_BODY_BYTES:
            raise GatewayProxyError(
                413,
                "request_too_large",
                "The session request exceeded the supported size.",
            )

        status, response_body, payload = await self._proxy_json_request(
            method,
            contract.path,
            allowed_statuses=contract.success_statuses | {400, 404, 409},
            body=body,
        )
        if status in contract.success_statuses:
            if not is_session_payload(payload, contract.payload_kind):
                raise GatewayProxyError(
                    502,
                    "gateway_incompatible",
                    "The Hermes Gateway session response is incompatible.",
                )
        else:
            sanitized_error = sanitized_gateway_error(payload)
            if sanitized_error is None:
                raise GatewayProxyError(
                    502,
                    "gateway_incompatible",
                    "The Hermes Gateway error response is incompatible.",
                )
            response_body = json.dumps(
                sanitized_error,
                separators=(",", ":"),
            ).encode("utf-8")
        return GatewayProxyResponse(status, response_body)

    async def run_request(
        self,
        method: str,
        *,
        run_id: str | None = None,
        action: str | None = None,
        body: bytes | None = None,
    ) -> GatewayProxyResponse:
        """Forward one exact verified Runs JSON resource."""
        contract = run_request_contract(
            method,
            run_id=run_id,
            action=action,
        )
        if body is not None and len(body) > RUN_REQUEST_MAX_BODY_BYTES:
            raise GatewayProxyError(
                413,
                "request_too_large",
                "The run request exceeded the supported size.",
            )

        status, response_body, payload = await self._proxy_json_request(
            method,
            contract.path,
            allowed_statuses=(
                contract.success_statuses | {400, 404, 409, 429}
            ),
            body=body,
        )
        if status in contract.success_statuses:
            if (
                not is_run_payload(payload, contract.payload_kind)
                or (
                    run_id is not None
                    and isinstance(payload, dict)
                    and payload.get("run_id") != run_id
                )
            ):
                raise GatewayProxyError(
                    502,
                    "gateway_incompatible",
                    "The Hermes Gateway run response is incompatible.",
                )
        else:
            sanitized_error = sanitized_gateway_error(payload)
            if sanitized_error is None:
                raise GatewayProxyError(
                    502,
                    "gateway_incompatible",
                    "The Hermes Gateway error response is incompatible.",
                )
            response_body = json.dumps(
                sanitized_error,
                separators=(",", ":"),
            ).encode("utf-8")
        return GatewayProxyResponse(status, response_body)

    async def open_run_events(self, run_id: str) -> GatewayRunEventStream:
        """Open the verified SSE resource without reading or rewriting it."""
        path = run_events_path(run_id)
        session = ClientSession(
            timeout=ClientTimeout(
                total=None,
                sock_connect=self._timeout_seconds,
                sock_read=None,
            )
        )
        try:
            response = await session.get(
                self._base_url + path,
                headers={
                    "Accept": "text/event-stream",
                    "Accept-Encoding": "identity",
                    "Authorization": f"Bearer {self._api_key}",
                    "Cache-Control": "no-cache, no-transform",
                },
                allow_redirects=False,
            )
            if response.status in {401, 403}:
                raise GatewayProxyError(
                    502,
                    "gateway_unauthorized",
                    "The Hermes Gateway rejected its NAS-local credential.",
                )
            if response.status >= 500:
                raise GatewayProxyError(
                    503,
                    "gateway_unavailable",
                    "The Hermes Gateway is temporarily unavailable.",
                )
            if response.status != 200:
                if response.status not in {400, 404, 409, 429}:
                    raise GatewayProxyError(
                        502,
                        "gateway_incompatible",
                        "The Hermes Gateway returned an unsupported response.",
                    )
                if response.content_type != "application/json":
                    raise GatewayProxyError(
                        502,
                        "gateway_incompatible",
                        "The Hermes Gateway returned an unsupported content type.",
                    )
                response_body = await read_bounded_session_response(response)
                try:
                    payload = json.loads(response_body)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    raise GatewayProxyError(
                        502,
                        "gateway_malformed_response",
                        "The Hermes Gateway returned malformed JSON.",
                    ) from None
                sanitized_error = sanitized_gateway_error(payload)
                if sanitized_error is None:
                    raise GatewayProxyError(
                        502,
                        "gateway_incompatible",
                        "The Hermes Gateway error response is incompatible.",
                    )
                raise GatewayRunHTTPError(
                    GatewayProxyResponse(
                        response.status,
                        json.dumps(
                            sanitized_error,
                            separators=(",", ":"),
                        ).encode("utf-8"),
                    )
                )
            if response.content_type != "text/event-stream":
                raise GatewayProxyError(
                    502,
                    "gateway_incompatible",
                    "The Hermes Gateway returned an unsupported content type.",
                )
            return GatewayRunEventStream(session, response)
        except (GatewayProxyError, GatewayRunHTTPError):
            await session.close()
            raise
        except asyncio.TimeoutError:
            await session.close()
            raise GatewayProxyError(
                504,
                "gateway_timeout",
                "The Hermes Gateway run stream took too long to connect.",
            ) from None
        except (ClientError, OSError):
            await session.close()
            raise GatewayProxyError(
                503,
                "gateway_transport_failure",
                "The Companion could not reach the Hermes Gateway.",
            ) from None

    async def _proxy_json_request(
        self,
        method: str,
        path: str,
        *,
        allowed_statuses: frozenset[int] | set[int],
        query: Sequence[tuple[str, str]] = (),
        body: bytes | None = None,
        timeout: ClientTimeout | None = None,
    ) -> tuple[int, bytes, object]:
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self._api_key}",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        outbound_body = io.BytesIO(body) if body is not None else None
        try:
            async with ClientSession(
                timeout=timeout or self._timeout
            ) as session:
                async with session.request(
                    method,
                    self._base_url + path,
                    params=query,
                    data=outbound_body,
                    headers=headers,
                    allow_redirects=False,
                ) as response:
                    if response.status in {401, 403}:
                        raise GatewayProxyError(
                            502,
                            "gateway_unauthorized",
                            "The Hermes Gateway rejected its NAS-local credential.",
                        )
                    if response.status >= 500:
                        raise GatewayProxyError(
                            503,
                            "gateway_unavailable",
                            "The Hermes Gateway is temporarily unavailable.",
                        )
                    if response.status not in allowed_statuses:
                        raise GatewayProxyError(
                            502,
                            "gateway_incompatible",
                            "The Hermes Gateway returned an unsupported response.",
                        )
                    if response.content_type != "application/json":
                        raise GatewayProxyError(
                            502,
                            "gateway_incompatible",
                            "The Hermes Gateway returned an unsupported content type.",
                        )
                    status = response.status
                    response_body = await read_bounded_session_response(response)
                    try:
                        payload = json.loads(response_body)
                    except (UnicodeDecodeError, json.JSONDecodeError):
                        raise GatewayProxyError(
                            502,
                            "gateway_malformed_response",
                            "The Hermes Gateway returned malformed JSON.",
                        ) from None
        except GatewayProxyError:
            raise
        except asyncio.TimeoutError:
            raise GatewayProxyError(
                504,
                "gateway_timeout",
                "The Hermes Gateway request timed out.",
            ) from None
        except (ClientError, OSError):
            raise GatewayProxyError(
                503,
                "gateway_transport_failure",
                "The Companion could not reach the Hermes Gateway.",
            ) from None
        finally:
            if outbound_body is not None:
                outbound_body.close()
        return status, response_body, payload

    async def _get_json(self, path: str) -> tuple[str, object | None]:
        headers = (
            {"Authorization": f"Bearer {self._api_key}"} if self._api_key else {}
        )
        try:
            async with ClientSession(timeout=self._timeout) as session:
                async with session.get(
                    self._base_url + path,
                    headers=headers,
                ) as response:
                    if response.status in {401, 403}:
                        return "unauthorized", None
                    if response.status != 200:
                        status = (
                            "unavailable" if response.status >= 500 else "incompatible"
                        )
                        return status, None
                    try:
                        payload = await response.json()
                    except (TypeError, ValueError):
                        return "incompatible", None
        except (asyncio.TimeoutError, ClientError, OSError):
            return "unavailable", None
        return "ok", payload


def _sanitize_capabilities(payload: object) -> dict[str, object] | None:
    if not isinstance(payload, dict):
        return None
    if (
        payload.get("object") != CAPABILITIES_OBJECT
        or payload.get("platform") != "hermes-agent"
    ):
        return None

    return {
        "object": CAPABILITIES_OBJECT,
        "platform": "hermes-agent",
        "auth": _sanitize_auth(payload.get("auth")),
        "runtime": _sanitize_runtime(payload.get("runtime")),
        "features": _sanitize_features(payload.get("features")),
        "endpoints": _sanitize_endpoints(payload.get("endpoints")),
    }


def _sanitize_auth(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        return {}
    sanitized: dict[str, object] = {}
    auth_type = value.get("type")
    required = value.get("required")
    if isinstance(auth_type, str) and len(auth_type) <= 32:
        sanitized["type"] = auth_type
    if type(required) is bool:
        sanitized["required"] = required
    return sanitized


def _sanitize_runtime(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        return {}
    sanitized: dict[str, object] = {}
    for key in ("mode", "tool_execution"):
        field = value.get(key)
        if isinstance(field, str) and len(field) <= 64:
            sanitized[key] = field
    split_runtime = value.get("split_runtime")
    if type(split_runtime) is bool:
        sanitized["split_runtime"] = split_runtime
    return sanitized


def _sanitize_features(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        return {}
    sanitized: dict[str, object] = {}
    for key, field in value.items():
        if not isinstance(key, str) or SAFE_NAME.fullmatch(key) is None:
            continue
        if type(field) is bool:
            sanitized[key] = field
        elif (
            key.endswith("_header")
            and isinstance(field, str)
            and SAFE_HEADER_NAME.fullmatch(field) is not None
        ):
            sanitized[key] = field
    return sanitized


def _sanitize_endpoints(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        return {}
    sanitized: dict[str, object] = {}
    for name, descriptor in value.items():
        if (
            not isinstance(name, str)
            or SAFE_NAME.fullmatch(name) is None
            or not isinstance(descriptor, dict)
        ):
            continue
        method = descriptor.get("method")
        path = descriptor.get("path")
        if (
            isinstance(method, str)
            and method in SAFE_METHODS
            and isinstance(path, str)
            and not path.startswith("//")
            and "?" not in path
            and "#" not in path
            and "\\" not in path
            and SAFE_PATH.fullmatch(path) is not None
        ):
            sanitized[name] = {"method": method, "path": path}
    return sanitized
