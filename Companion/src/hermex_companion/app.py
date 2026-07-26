"""App-facing Hermex Companion HTTP interface."""

from collections.abc import Awaitable, Callable
from datetime import datetime, UTC

from aiohttp import web

from hermex_companion import COMPANION_VERSION, CONTRACT_VERSION
from hermex_companion.gateway import GatewayDiscovery
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
    response.headers["Cache-Control"] = "no-store"
    return response


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
                    "gateway_proxy": False,
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


async def _close_registry(app: web.Application) -> None:
    app[REGISTRY_KEY].close()


def create_app(
    registry: DeviceRegistry | None = None,
    gateway: GatewayDiscovery | None = None,
) -> web.Application:
    """Create the Companion module's aiohttp adapter."""
    app = web.Application(
        client_max_size=16 * 1024,
        middlewares=[_no_store],
    )
    app[REGISTRY_KEY] = registry or DeviceRegistry(":memory:")
    app[GATEWAY_KEY] = gateway or GatewayDiscovery("http://127.0.0.1:8642", "")
    app.router.add_get(HEALTH_PATH, _health)
    app.router.add_post(PAIRING_CLAIM_PATH, _claim_pairing)
    app.router.add_get(DEVICES_PATH, _list_devices)
    app.router.add_delete(f"{DEVICES_PATH}/{{device_id}}", _revoke_device)
    app.router.add_get(CAPABILITIES_PATH, _capabilities)
    app.router.add_get(READINESS_PATH, _readiness)
    app.on_cleanup.append(_close_registry)
    return app
