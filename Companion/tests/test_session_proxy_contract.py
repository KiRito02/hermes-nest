import asyncio
import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from hermex_companion.app import create_app
from hermex_companion.gateway import GatewayDiscovery
from hermex_companion.registry import DeviceRegistry


class SessionProxyContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.gateway_requests: list[dict[str, object]] = []
        self.gateway_mode = "ok"
        self.redirect_target_requests = 0
        gateway_app = web.Application()
        gateway_app.router.add_get("/api/sessions", self._gateway_sessions)
        gateway_app.router.add_get("/redirect-target", self._redirect_target)
        self.gateway_server = TestServer(gateway_app)
        await self.gateway_server.start_server()

        self.registry = DeviceRegistry(":memory:")
        companion_app = create_app(
            self.registry,
            GatewayDiscovery(
                str(self.gateway_server.make_url("")).rstrip("/"),
                "gateway-test-key",
                timeout=0.05,
            ),
        )
        self.client = TestClient(TestServer(companion_app))
        await self.client.start_server()
        self.device_credential = await self._pair_device()

    async def asyncTearDown(self) -> None:
        await self.client.close()
        await self.gateway_server.close()

    async def test_authenticated_session_list_replaces_auth_and_preserves_contract(
        self,
    ) -> None:
        response = await self.client.get(
            "/api/sessions",
            params={
                "limit": "25",
                "offset": "50",
                "source": "api_server",
                "include_children": "true",
            },
            headers={
                "Authorization": f"Bearer {self.device_credential}",
                "X-Private-Client-Header": "must-not-cross-boundary",
            },
        )

        self.assertEqual(200, response.status)
        self.assertEqual(
            {
                "object": "list",
                "data": [
                    {
                        "id": "session-1",
                        "title": "Contract fixture",
                        "source": "api_server",
                        "message_count": 3,
                        "started_at": 1_721_000_000.0,
                        "last_active": 1_721_000_100.0,
                        "future_field": {"is_tolerated": True},
                    }
                ],
                "limit": 25,
                "offset": 50,
                "has_more": False,
                "future_page_field": "is also tolerated",
            },
            await response.json(),
        )
        self.assertEqual(
            [
                {
                    "authorization": "Bearer gateway-test-key",
                    "query": [
                        ("limit", "25"),
                        ("offset", "50"),
                        ("source", "api_server"),
                        ("include_children", "true"),
                    ],
                    "private_header": None,
                }
            ],
            self.gateway_requests,
        )
        serialized = repr(await response.json())
        self.assertNotIn(self.device_credential, serialized)
        self.assertNotIn("gateway-test-key", serialized)

    async def test_device_auth_and_exact_route_allowlist_precede_gateway(self) -> None:
        without_device = await self.client.get("/api/sessions")
        self.assertEqual(401, without_device.status)
        self.assertEqual(
            "device_credential_invalid",
            (await without_device.json())["error"]["code"],
        )

        headers = {"Authorization": f"Bearer {self.device_credential}"}
        wrong_method = await self.client.put("/api/sessions", headers=headers)
        implicit_head = await self.client.head("/api/sessions", headers=headers)
        unlisted_path = await self.client.get(
            "/api/sessions/session-1/export",
            headers=headers,
        )

        self.assertEqual(405, wrong_method.status)
        self.assertEqual(405, implicit_head.status)
        self.assertEqual(404, unlisted_path.status)
        self.assertEqual([], self.gateway_requests)

    async def test_session_list_rejects_unbounded_or_unsupported_query(self) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}
        invalid_queries = (
            "future=true",
            "limit=201",
            "limit=-1",
            "offset=1000001",
            "include_children=maybe",
            "source=" + ("x" * 129),
            "limit=1&limit=2",
        )

        for query in invalid_queries:
            with self.subTest(query=query):
                response = await self.client.get(
                    f"/api/sessions?{query}",
                    headers=headers,
                )
                self.assertEqual(400, response.status)
                self.assertEqual(
                    "invalid_query",
                    (await response.json())["error"]["code"],
                )

        self.assertEqual([], self.gateway_requests)

    async def test_gateway_failures_are_distinct_bounded_errors(self) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}
        for mode, status, code in (
            ("unauthorized", 502, "gateway_unauthorized"),
            ("unavailable", 503, "gateway_unavailable"),
            ("incompatible_status", 502, "gateway_incompatible"),
            ("incompatible_content_type", 502, "gateway_incompatible"),
            ("malformed", 502, "gateway_malformed_response"),
            ("incompatible_shape", 502, "gateway_incompatible"),
            ("too_large", 502, "gateway_response_too_large"),
            ("timeout", 504, "gateway_timeout"),
        ):
            with self.subTest(mode=mode):
                self.gateway_mode = mode
                response = await self.client.get("/api/sessions", headers=headers)
                self.assertEqual(status, response.status)
                body = await response.json()
                self.assertEqual(code, body["error"]["code"])
                self.assertEqual({"code", "message"}, set(body["error"]))
                self.assertNotIn("private gateway detail", repr(body))

    async def test_gateway_redirect_is_not_followed(self) -> None:
        self.gateway_mode = "redirect"
        response = await self.client.get(
            "/api/sessions",
            headers={"Authorization": f"Bearer {self.device_credential}"},
        )

        self.assertEqual(502, response.status)
        self.assertEqual(
            "gateway_incompatible",
            (await response.json())["error"]["code"],
        )
        self.assertEqual(0, self.redirect_target_requests)

    async def test_gateway_transport_failure_is_distinct(self) -> None:
        registry = DeviceRegistry(":memory:")
        companion_app = create_app(
            registry,
            GatewayDiscovery(
                "http://127.0.0.1:1",
                "gateway-test-key",
                timeout=0.1,
            ),
        )
        client = TestClient(TestServer(companion_app))
        await client.start_server()
        try:
            secret = registry.create_pairing_secret(300)
            paired = await client.post(
                "/companion/v1/pairings/claim",
                json={"secret": secret, "device_name": "Transport Test"},
            )
            credential = (await paired.json())["credential"]

            response = await client.get(
                "/api/sessions",
                headers={"Authorization": f"Bearer {credential}"},
            )
            self.assertEqual(503, response.status)
            self.assertEqual(
                "gateway_transport_failure",
                (await response.json())["error"]["code"],
            )
        finally:
            await client.close()

    async def _pair_device(self) -> str:
        secret = self.registry.create_pairing_secret(300)
        response = await self.client.post(
            "/companion/v1/pairings/claim",
            json={"secret": secret, "device_name": "Session Contract Test"},
        )
        self.assertEqual(201, response.status)
        return (await response.json())["credential"]

    async def _gateway_sessions(self, request: web.Request) -> web.Response:
        self.gateway_requests.append(
            {
                "authorization": request.headers.get("Authorization"),
                "query": list(request.query.items()),
                "private_header": request.headers.get("X-Private-Client-Header"),
            }
        )
        if self.gateway_mode == "unauthorized":
            return web.json_response(
                {"detail": "private gateway detail"},
                status=401,
            )
        if self.gateway_mode == "unavailable":
            return web.json_response(
                {"detail": "private gateway detail"},
                status=503,
            )
        if self.gateway_mode == "incompatible_status":
            return web.json_response(
                {"detail": "private gateway detail"},
                status=418,
            )
        if self.gateway_mode == "incompatible_content_type":
            return web.Response(text='{"object":"list"}', content_type="text/plain")
        if self.gateway_mode == "malformed":
            return web.Response(text="{", content_type="application/json")
        if self.gateway_mode == "incompatible_shape":
            return web.json_response({"object": "unexpected", "data": []})
        if self.gateway_mode == "redirect":
            raise web.HTTPFound("/redirect-target")
        if self.gateway_mode == "too_large":
            return web.Response(
                body=b"x" * ((2 * 1024 * 1024) + 1),
                content_type="application/json",
            )
        if self.gateway_mode == "timeout":
            await asyncio.sleep(0.2)
        return web.json_response(
            {
                "object": "list",
                "data": [
                    {
                        "id": "session-1",
                        "title": "Contract fixture",
                        "source": "api_server",
                        "message_count": 3,
                        "started_at": 1_721_000_000.0,
                        "last_active": 1_721_000_100.0,
                        "future_field": {"is_tolerated": True},
                    }
                ],
                "limit": 25,
                "offset": 50,
                "has_more": False,
                "future_page_field": "is also tolerated",
            }
        )

    async def _redirect_target(self, _request: web.Request) -> web.Response:
        self.redirect_target_requests += 1
        return web.json_response(
            {
                "object": "list",
                "data": [],
                "limit": 50,
                "offset": 0,
                "has_more": False,
            }
        )
