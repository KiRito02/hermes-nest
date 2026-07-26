"""App-facing Hermes Nest Companion HTTP interface."""

import asyncio
from collections.abc import Awaitable, Callable
from datetime import datetime, UTC
import json

from aiohttp import web

from hermex_companion import COMPANION_VERSION, CONTRACT_VERSION
from hermex_companion.gateway import (
    GatewayDiscovery,
    GatewayProxyError,
    GatewayRunHTTPError,
    SESSION_LIST_PATH,
)
from hermex_companion.run_proxy_contract import (
    RUN_REQUEST_MAX_BODY_BYTES,
    RUNS_PATH,
    validate_approval_payload,
)
from hermex_companion.registry import (
    DeviceRegistry,
    RegisteredDevice,
    RegistryError,
)

HEALTH_PATH = "/companion/v1/health"
PAIRING_CLAIM_PATH = "/companion/v1/pairings/claim"
DEVICES_PATH = "/companion/v1/devices"
CAPABILITIES_PATH = "/companion/v1/capabilities"
READINESS_PATH = "/companion/v1/readiness"
REGISTRY_KEY = web.AppKey("registry", DeviceRegistry)
GATEWAY_KEY = web.AppKey("gateway", GatewayDiscovery)
DEFAULT_REQUEST_MAX_BODY_BYTES = 16 * 1024


@web.middleware
async def _no_store(
    request: web.Request,
    handler: Callable[[web.Request], Awaitable[web.StreamResponse]],
) -> web.StreamResponse:
    try:
        response = await handler(request)
    except web.HTTPException as response:
        # aiohttp owns framework-generated 404/405/413 responses, so they do
        # not pass through `_json_response`.
        response.headers["Cache-Control"] = "no-store"
        raise
    if response.content_type == "text/event-stream":
        response.headers.setdefault("Cache-Control", "no-cache")
    else:
        response.headers["Cache-Control"] = "no-store"
    return response


@web.middleware
async def _bounded_request_body(
    request: web.Request,
    handler: Callable[[web.Request], Awaitable[web.StreamResponse]],
) -> web.StreamResponse:
    if request.method == "POST" and request.path == RUNS_PATH:
        return await handler(request)
    return await handler(
        request.clone(client_max_size=DEFAULT_REQUEST_MAX_BODY_BYTES + 1)
    )


async def _health(_request: web.Request) -> web.Response:
    return _json_response(
        {
            "status": "ok",
            "service": "hermex-companion",
            "companion_version": COMPANION_VERSION,
            "contract_version": CONTRACT_VERSION,
        },
    )


async def _claim_pairing(request: web.Request) -> web.Response:
    try:
        payload = await request.json()
    except (ValueError, TypeError):
        return _error_response(
            RegistryError(400, "invalid_request", "A JSON object is required.")
        )
    if not isinstance(payload, dict):
        return _error_response(
            RegistryError(400, "invalid_request", "A JSON object is required.")
        )

    try:
        claimed = request.app[REGISTRY_KEY].claim_pairing_secret(
            payload.get("secret"),
            payload.get("device_name"),
        )
    except RegistryError as error:
        return _error_response(error)

    return _json_response(
        {
            "device": {
                "id": claimed.id,
                "name": claimed.name,
            },
            "credential": claimed.credential,
            "credential_type": "Bearer",
        },
        status=201,
    )


async def _list_devices(request: web.Request) -> web.Response:
    try:
        _authenticate(request)
    except RegistryError as error:
        return _error_response(error)
    return _json_response(
        {
            "devices": [
                _device_payload(device)
                for device in request.app[REGISTRY_KEY].list_devices()
            ]
        }
    )


async def _revoke_device(request: web.Request) -> web.Response:
    try:
        _authenticate(request)
        request.app[REGISTRY_KEY].revoke_device(request.match_info["device_id"])
    except RegistryError as error:
        return _error_response(error)
    return web.Response(status=204, headers={"Cache-Control": "no-store"})


async def _capabilities(request: web.Request) -> web.Response:
    try:
        _authenticate(request)
    except RegistryError as error:
        return _error_response(error)

    gateway = await request.app[GATEWAY_KEY].capabilities()
    return _json_response(
        {
            "object": "hermex.companion.capabilities",
            "contract_version": CONTRACT_VERSION,
            "companion": {
                "version": COMPANION_VERSION,
                "features": {
                    "pairing": True,
                    "device_auth": True,
                    "device_revocation": True,
                    "gateway_discovery": True,
                    "gateway_proxy": True,
                    "run_approval_proxy": True,
                },
                "endpoints": {
                    "health": {"method": "GET", "path": HEALTH_PATH},
                    "pairing_claim": {
                        "method": "POST",
                        "path": PAIRING_CLAIM_PATH,
                    },
                    "devices": {"method": "GET", "path": DEVICES_PATH},
                    "device_revoke": {
                        "method": "DELETE",
                        "path": f"{DEVICES_PATH}/{{device_id}}",
                    },
                    "capabilities": {"method": "GET", "path": CAPABILITIES_PATH},
                    "readiness": {"method": "GET", "path": READINESS_PATH},
                    "run_approval": {
                        "method": "POST",
                        "path": f"{RUNS_PATH}/{{run_id}}/approval",
                    },
                },
            },
            "gateway": {
                "status": gateway.status,
                "capabilities": gateway.capabilities,
            },
        }
    )


async def _readiness(request: web.Request) -> web.Response:
    try:
        _authenticate(request)
    except RegistryError as error:
        return _error_response(error)

    gateway = await request.app[GATEWAY_KEY].readiness()
    return _json_response(
        {
            "status": "ok" if gateway.status == "ok" else "degraded",
            "companion": {
                "status": "ok",
                "version": COMPANION_VERSION,
                "contract_version": CONTRACT_VERSION,
            },
            "gateway": {
                "status": gateway.status,
                "platform": gateway.platform,
                "version": gateway.version,
            },
        }
    )


async def _list_sessions(request: web.Request) -> web.Response:
    try:
        _authenticate(request)
        body = await request.app[GATEWAY_KEY].list_sessions(
            list(request.query.items())
        )
    except RegistryError as error:
        return _error_response(error)
    except GatewayProxyError as error:
        return _proxy_error_response(error)

    return web.Response(
        body=body,
        status=200,
        content_type="application/json",
        headers={"Cache-Control": "no-store"},
    )


async def _session_request(
    request: web.Request,
    *,
    action: str | None = None,
) -> web.Response:
    try:
        _authenticate(request)
        if request.query:
            raise GatewayProxyError(
                400,
                "invalid_query",
                "Session resource requests do not accept query parameters.",
            )

        body: bytes | None = None
        if request.method in {"PATCH", "POST"}:
            if request.content_type != "application/json":
                raise GatewayProxyError(
                    415,
                    "invalid_content_type",
                    "Session request bodies must use application/json.",
                )
            body = await request.read()
            try:
                payload = json.loads(body)
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise GatewayProxyError(
                    400,
                    "invalid_json",
                    "The session request body must be valid JSON.",
                ) from None
            if not isinstance(payload, dict):
                raise GatewayProxyError(
                    400,
                    "invalid_json",
                    "The session request body must be a JSON object.",
                )

        response = await request.app[GATEWAY_KEY].session_request(
            request.method,
            session_id=request.match_info.get("session_id"),
            action=action,
            body=body,
        )
    except RegistryError as error:
        return _error_response(error)
    except GatewayProxyError as error:
        return _proxy_error_response(error)

    return web.Response(
        body=response.body,
        status=response.status,
        content_type="application/json",
        headers={"Cache-Control": "no-store"},
    )


async def _create_session(request: web.Request) -> web.Response:
    return await _session_request(request)


async def _session_resource(request: web.Request) -> web.Response:
    return await _session_request(request)


async def _session_messages(request: web.Request) -> web.Response:
    return await _session_request(request, action="messages")


async def _fork_session(request: web.Request) -> web.Response:
    return await _session_request(request, action="fork")


async def _run_request(
    request: web.Request,
    *,
    action: str | None = None,
) -> web.Response:
    try:
        _authenticate(request)
        if request.query:
            raise GatewayProxyError(
                400,
                "invalid_query",
                "Run resource requests do not accept query parameters.",
            )

        body: bytes | None = None
        if request.match_info.get("run_id") is None:
            if request.content_type != "application/json":
                raise GatewayProxyError(
                    415,
                    "invalid_content_type",
                    "Run request bodies must use application/json.",
                )
            body = await request.read()
            if len(body) > RUN_REQUEST_MAX_BODY_BYTES:
                raise GatewayProxyError(
                    413,
                    "request_too_large",
                    "The run request exceeded the supported size.",
                )
            try:
                payload = json.loads(body)
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise GatewayProxyError(
                    400,
                    "invalid_json",
                    "The run request body must be valid JSON.",
                ) from None
            if not isinstance(payload, dict):
                raise GatewayProxyError(
                    400,
                    "invalid_json",
                    "The run request body must be a JSON object.",
                )
        elif action == "approval":
            if request.content_type != "application/json":
                raise GatewayProxyError(
                    415,
                    "invalid_content_type",
                    "Approval request bodies must use application/json.",
                )
            body = await request.read()
            try:
                payload = json.loads(body)
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise GatewayProxyError(
                    400,
                    "invalid_json",
                    "The approval request body must be valid JSON.",
                ) from None
            validate_approval_payload(payload)
        elif request.can_read_body:
            raise GatewayProxyError(
                400,
                "invalid_request",
                "This run resource does not accept a request body.",
            )

        response = await request.app[GATEWAY_KEY].run_request(
            request.method,
            run_id=request.match_info.get("run_id"),
            action=action,
            body=body,
        )
    except RegistryError as error:
        return _error_response(error)
    except GatewayProxyError as error:
        return _proxy_error_response(error)

    return web.Response(
        body=response.body,
        status=response.status,
        content_type="application/json",
        headers={"Cache-Control": "no-store"},
    )


async def _start_run(request: web.Request) -> web.Response:
    return await _run_request(request)


async def _run_status(request: web.Request) -> web.Response:
    return await _run_request(request)


async def _stop_run(request: web.Request) -> web.Response:
    return await _run_request(request, action="stop")


async def _approve_run(request: web.Request) -> web.Response:
    return await _run_request(request, action="approval")


async def _run_events(request: web.Request) -> web.StreamResponse:
    stream = None
    try:
        _authenticate(request)
        if request.query:
            raise GatewayProxyError(
                400,
                "invalid_query",
                "Run event streams do not accept query parameters.",
            )
        if request.can_read_body:
            raise GatewayProxyError(
                400,
                "invalid_request",
                "Run event streams do not accept a request body.",
            )
        stream = await request.app[GATEWAY_KEY].open_run_events(
            request.match_info["run_id"]
        )
    except RegistryError as error:
        return _error_response(error)
    except GatewayRunHTTPError as error:
        return web.Response(
            body=error.response.body,
            status=error.response.status,
            content_type="application/json",
            headers={"Cache-Control": "no-store"},
        )
    except GatewayProxyError as error:
        return _proxy_error_response(error)

    response = web.StreamResponse(
        status=200,
        headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
    try:
        await response.prepare(request)
        async for chunk in stream.response.content.iter_any():
            await response.write(chunk)
        await response.write_eof()
    except (ConnectionResetError, asyncio.CancelledError):
        pass
    finally:
        await stream.close()
    return response


def _authenticate(request: web.Request) -> RegisteredDevice:
    scheme, separator, credential = request.headers.get("Authorization", "").partition(
        " "
    )
    if not separator or scheme.lower() != "bearer":
        credential = ""
    return request.app[REGISTRY_KEY].authenticate(credential)


def _device_payload(device: RegisteredDevice) -> dict[str, object]:
    return {
        "id": device.id,
        "name": device.name,
        "created_at": _timestamp(device.created_at),
        "last_seen_at": (
            _timestamp(device.last_seen_at) if device.last_seen_at is not None else None
        ),
        "revoked": device.revoked_at is not None,
    }


def _timestamp(value: int) -> str:
    return datetime.fromtimestamp(value, UTC).isoformat().replace("+00:00", "Z")


def _json_response(payload: object, *, status: int = 200) -> web.Response:
    return web.json_response(
        payload,
        status=status,
        headers={"Cache-Control": "no-store"},
    )


def _error_response(error: RegistryError) -> web.Response:
    response = _json_response(
        {
            "error": {
                "code": error.code,
                "message": error.message,
            }
        },
        status=error.status,
    )
    if error.status == 401:
        response.headers["WWW-Authenticate"] = "Bearer"
    return response


def _proxy_error_response(error: GatewayProxyError) -> web.Response:
    return _json_response(
        {
            "error": {
                "code": error.code,
                "message": error.message,
            }
        },
        status=error.status,
    )


async def _close_registry(app: web.Application) -> None:
    app[REGISTRY_KEY].close()


def create_app(
    registry: DeviceRegistry | None = None,
    gateway: GatewayDiscovery | None = None,
) -> web.Application:
    """Create the Companion module's aiohttp adapter."""
    app = web.Application(
        client_max_size=RUN_REQUEST_MAX_BODY_BYTES + 1,
        middlewares=[_no_store, _bounded_request_body],
    )
    app[REGISTRY_KEY] = registry or DeviceRegistry(":memory:")
    app[GATEWAY_KEY] = gateway or GatewayDiscovery("http://127.0.0.1:8642", "")
    app.router.add_get(HEALTH_PATH, _health)
    app.router.add_post(PAIRING_CLAIM_PATH, _claim_pairing)
    app.router.add_get(DEVICES_PATH, _list_devices)
    app.router.add_delete(f"{DEVICES_PATH}/{{device_id}}", _revoke_device)
    app.router.add_get(CAPABILITIES_PATH, _capabilities)
    app.router.add_get(READINESS_PATH, _readiness)
    app.router.add_get(SESSION_LIST_PATH, _list_sessions, allow_head=False)
    app.router.add_post(SESSION_LIST_PATH, _create_session)
    app.router.add_get(
        f"{SESSION_LIST_PATH}/{{session_id}}",
        _session_resource,
        allow_head=False,
    )
    app.router.add_patch(
        f"{SESSION_LIST_PATH}/{{session_id}}",
        _session_resource,
    )
    app.router.add_delete(
        f"{SESSION_LIST_PATH}/{{session_id}}",
        _session_resource,
    )
    app.router.add_get(
        f"{SESSION_LIST_PATH}/{{session_id}}/messages",
        _session_messages,
        allow_head=False,
    )
    app.router.add_post(
        f"{SESSION_LIST_PATH}/{{session_id}}/fork",
        _fork_session,
    )
    app.router.add_post(RUNS_PATH, _start_run)
    app.router.add_get(
        f"{RUNS_PATH}/{{run_id}}",
        _run_status,
        allow_head=False,
    )
    app.router.add_get(
        f"{RUNS_PATH}/{{run_id}}/events",
        _run_events,
        allow_head=False,
    )
    app.router.add_post(
        f"{RUNS_PATH}/{{run_id}}/stop",
        _stop_run,
    )
    app.router.add_post(
        f"{RUNS_PATH}/{{run_id}}/approval",
        _approve_run,
    )
    app.on_cleanup.append(_close_registry)
    return app
