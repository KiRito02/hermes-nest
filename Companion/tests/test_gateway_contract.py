import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from hermex_companion.app import create_app
from hermex_companion.gateway import GatewayDiscovery
from hermex_companion.registry import DeviceRegistry


class GatewayCapabilityContractTests(unittest.IsolatedAsyncioTestCase):
    def test_gateway_url_must_be_bare_http_loopback_origin(self) -> None:
        for value in (
            "https://127.0.0.1:8642",
            "http://gateway.example.test:8642",
            "http://user:secret@127.0.0.1:8642",
            "http://127.0.0.1:8642/private",
            "http://127.0.0.1:8642?key=secret",
        ):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    GatewayDiscovery(value, "gateway-test-key")

    async def asyncSetUp(self) -> None:
        self.gateway_authorization: str | None = None
        self.gateway_mode = "ok"
        gateway_app = web.Application()
        gateway_app.router.add_get("/v1/capabilities", self._gateway_capabilities)
        gateway_app.router.add_get("/health/detailed", self._gateway_readiness)
        self.gateway_server = TestServer(gateway_app)
        await self.gateway_server.start_server()

        self.registry = DeviceRegistry(":memory:")
        companion_app = create_app(
            self.registry,
            GatewayDiscovery(
                str(self.gateway_server.make_url("")).rstrip("/"),
                "gateway-test-key",
            ),
        )
        self.client = TestClient(TestServer(companion_app))
        await self.client.start_server()
        self.device_credential = await self._pair_device()

    async def asyncTearDown(self) -> None:
        await self.client.close()
        await self.gateway_server.close()

    async def test_capabilities_are_authenticated_and_sanitized(self) -> None:
        response = await self.client.get(
            "/companion/v1/capabilities",
            headers={"Authorization": f"Bearer {self.device_credential}"},
        )

        self.assertEqual(200, response.status)
        body = await response.json()
        self.assertEqual("hermex.companion.capabilities", body["object"])
        self.assertEqual("1", body["contract_version"])
        self.assertTrue(body["companion"]["features"]["device_auth"])
        self.assertFalse(body["companion"]["features"]["gateway_proxy"])
        self.assertEqual("ok", body["gateway"]["status"])
        self.assertEqual(
            "hermes.api_server.capabilities",
            body["gateway"]["capabilities"]["object"],
        )
        self.assertTrue(
            body["gateway"]["capabilities"]["features"]["session_resources"]
        )
        self.assertTrue(
            body["gateway"]["capabilities"]["features"]["future_boolean"]
        )
        self.assertEqual(
            "X-Hermes-Session-Id",
            body["gateway"]["capabilities"]["features"][
                "session_continuity_header"
            ],
        )
        self.assertEqual(
            {"method": "GET", "path": "/api/sessions"},
            body["gateway"]["capabilities"]["endpoints"]["sessions"],
        )
        serialized = repr(body)
        self.assertNotIn("private-model", serialized)
        self.assertNotIn("private runtime detail", serialized)
        self.assertNotIn("nested-secret", serialized)
        self.assertNotIn("injected-header", serialized)
        self.assertNotIn("private control path", serialized)
        self.assertNotIn("gateway-test-key", serialized)
        self.assertNotIn("API_SERVER_KEY", serialized)
        self.assertEqual("Bearer gateway-test-key", self.gateway_authorization)

    async def test_readiness_drops_gateway_process_details(self) -> None:
        response = await self.client.get(
            "/companion/v1/readiness",
            headers={"Authorization": f"Bearer {self.device_credential}"},
        )

        self.assertEqual(200, response.status)
        body = await response.json()
        self.assertEqual(
            {
                "status": "ok",
                "companion": {
                    "status": "ok",
                    "version": "0.1.0",
                    "contract_version": "1",
                },
                "gateway": {
                    "status": "ok",
                    "platform": "hermes-agent",
                    "version": "0.19.0",
                },
            },
            body,
        )
        serialized = repr(body)
        self.assertNotIn("pid", serialized)
        self.assertNotIn("platforms", serialized)
        self.assertNotIn("private readiness detail", serialized)

    async def test_gateway_failure_states_are_distinct_from_device_auth(self) -> None:
        without_device = await self.client.get("/companion/v1/readiness")
        self.assertEqual(401, without_device.status)
        self.assertEqual(
            "device_credential_invalid",
            (await without_device.json())["error"]["code"],
        )

        headers = {"Authorization": f"Bearer {self.device_credential}"}
        for mode, expected in (
            ("unavailable", "unavailable"),
            ("unauthorized", "unauthorized"),
            ("incompatible", "incompatible"),
        ):
            with self.subTest(mode=mode):
                self.gateway_mode = mode
                readiness = await self.client.get(
                    "/companion/v1/readiness", headers=headers
                )
                capabilities = await self.client.get(
                    "/companion/v1/capabilities", headers=headers
                )
                self.assertEqual(200, readiness.status)
                self.assertEqual(200, capabilities.status)
                readiness_body = await readiness.json()
                capabilities_body = await capabilities.json()
                self.assertEqual("degraded", readiness_body["status"])
                self.assertEqual(expected, readiness_body["gateway"]["status"])
                self.assertIsNone(readiness_body["gateway"]["platform"])
                self.assertIsNone(readiness_body["gateway"]["version"])
                self.assertEqual(expected, capabilities_body["gateway"]["status"])
                self.assertIsNone(capabilities_body["gateway"]["capabilities"])

    async def _pair_device(self) -> str:
        secret = self.registry.create_pairing_secret(300)
        response = await self.client.post(
            "/companion/v1/pairings/claim",
            json={"secret": secret, "device_name": "Contract Test"},
        )
        self.assertEqual(201, response.status)
        return (await response.json())["credential"]

    async def _gateway_capabilities(self, request: web.Request) -> web.Response:
        self.gateway_authorization = request.headers.get("Authorization")
        if self.gateway_mode == "unavailable":
            return web.json_response({"error": "temporary"}, status=503)
        if self.gateway_mode == "unauthorized":
            return web.json_response({"error": "invalid key"}, status=401)
        if self.gateway_mode == "incompatible":
            return web.json_response({"object": "unknown"})
        return web.json_response(
            {
                "object": "hermes.api_server.capabilities",
                "platform": "hermes-agent",
                "model": "private-model",
                "auth": {"type": "bearer", "required": True},
                "runtime": {
                    "mode": "server_agent",
                    "tool_execution": "server",
                    "split_runtime": False,
                    "description": "private runtime detail",
                },
                "features": {
                    "session_resources": True,
                    "future_boolean": True,
                    "session_continuity_header": "X-Hermes-Session-Id",
                    "injected_header": "X-Good\r\ninjected-header",
                    "future_nested": {"credential": "nested-secret"},
                },
                "endpoints": {
                    "sessions": {"method": "GET", "path": "/api/sessions"},
                    "future": {"method": "POST", "path": "/v1/future"},
                    "invalid": {"method": "GET", "path": "https://private-host"},
                    "control": {
                        "method": "GET",
                        "path": "/private control path",
                    },
                },
                "unexpected": {"API_SERVER_KEY": "nested-secret"},
            }
        )

    async def _gateway_readiness(self, request: web.Request) -> web.Response:
        self.gateway_authorization = request.headers.get("Authorization")
        if self.gateway_mode == "unavailable":
            return web.json_response({"error": "temporary"}, status=503)
        if self.gateway_mode == "unauthorized":
            return web.json_response({"error": "invalid key"}, status=401)
        if self.gateway_mode == "incompatible":
            return web.json_response(
                {"status": "ok", "platform": "unknown", "version": "x"}
            )
        return web.json_response(
            {
                "status": "ok",
                "platform": "hermes-agent",
                "version": "0.19.0",
                "pid": 1234,
                "platforms": {"private": {"state": "connected"}},
                "readiness": {"detail": "private readiness detail"},
            }
        )
