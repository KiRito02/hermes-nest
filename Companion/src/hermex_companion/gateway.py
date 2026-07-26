"""Sanitized discovery of the loopback Hermes Gateway."""

import asyncio
from dataclasses import dataclass
import re
from urllib.parse import urlsplit

from aiohttp import ClientError, ClientSession, ClientTimeout

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
