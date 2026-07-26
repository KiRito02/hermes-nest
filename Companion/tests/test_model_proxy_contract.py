import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from hermex_companion.app import create_app
from hermex_companion.gateway import GatewayDiscovery
from hermex_companion.registry import DeviceRegistry


class ModelProxyContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.gateway_requests: list[dict[str, object]] = []
        self.gateway_mode = "ok"

        gateway_app = web.Application()
        gateway_app.router.add_get(
            "/api/model/options",
            self._gateway_model_options,
        )
        gateway_app.router.add_post(
            "/api/sessions/{session_id}/model",
            self._gateway_model_lock,
        )
        self.gateway_server = TestServer(gateway_app)
        await self.gateway_server.start_server()

        self.registry = DeviceRegistry(":memory:")
        companion_app = create_app(
            self.registry,
            GatewayDiscovery(
                str(self.gateway_server.make_url("")).rstrip("/"),
                "gateway-model-key",
            ),
        )
        self.client = TestClient(TestServer(companion_app))
        await self.client.start_server()
        self.device_credential = await self._pair_device()

    async def asyncTearDown(self) -> None:
        await self.client.close()
        await self.gateway_server.close()

    async def test_model_options_preserves_inventory_and_replaces_auth(
        self,
    ) -> None:
        response = await self.client.get(
            "/api/model/options?refresh=1",
            headers={
                "Authorization": f"Bearer {self.device_credential}",
                "X-Private-Client-Header": "must-not-cross-boundary",
            },
        )

        self.assertEqual(200, response.status)
        self.assertEqual(
            {
                "providers": [
                    {
                        "slug": "openrouter",
                        "name": "OpenRouter",
                        "models": ["anthropic/claude-sonnet-4.6"],
                        "total_models": 1,
                        "authenticated": True,
                        "capabilities": {
                            "anthropic/claude-sonnet-4.6": {
                                "fast": False,
                                "reasoning": True,
                                "future_capability": "tolerated",
                            }
                        },
                        "future_provider_field": {"tolerated": True},
                    }
                ],
                "model": "anthropic/claude-sonnet-4.6",
                "provider": "openrouter",
                "future_top_level_field": ["tolerated"],
            },
            await response.json(),
        )
        self.assertEqual(
            [
                {
                    "authorization": "Bearer gateway-model-key",
                    "query": [("refresh", "1")],
                    "private_header": None,
                }
            ],
            self.gateway_requests,
        )

    async def test_model_options_allowlist_rejects_unverified_requests(
        self,
    ) -> None:
        without_device = await self.client.get("/api/model/options")
        self.assertEqual(401, without_device.status)

        headers = {"Authorization": f"Bearer {self.device_credential}"}
        implicit_head = await self.client.head(
            "/api/model/options",
            headers=headers,
        )
        wrong_method = await self.client.post(
            "/api/model/options",
            headers=headers,
        )
        unsupported_query = await self.client.get(
            "/api/model/options?private=true",
            headers=headers,
        )
        repeated_query = await self.client.get(
            "/api/model/options?refresh=1&refresh=0",
            headers=headers,
        )
        invalid_boolean = await self.client.get(
            "/api/model/options?refresh=sometimes",
            headers=headers,
        )

        self.assertEqual(405, implicit_head.status)
        self.assertEqual(405, wrong_method.status)
        for response in (
            unsupported_query,
            repeated_query,
            invalid_boolean,
        ):
            self.assertEqual(400, response.status)
            self.assertEqual(
                "invalid_query",
                (await response.json())["error"]["code"],
            )
        self.assertEqual([], self.gateway_requests)

    async def test_model_options_accepts_verified_boolean_spellings(
        self,
    ) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}

        for value in ("0", "1", "false", "no", "off", "on", "true", "yes"):
            with self.subTest(value=value):
                response = await self.client.get(
                    f"/api/model/options?refresh={value}",
                    headers=headers,
                )
                self.assertEqual(200, response.status)

        self.assertEqual(
            [[("refresh", value)] for value in (
                "0",
                "1",
                "false",
                "no",
                "off",
                "on",
                "true",
                "yes",
            )],
            [request["query"] for request in self.gateway_requests],
        )

    async def test_model_options_rejects_incompatible_gateway_payloads(
        self,
    ) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}

        for mode, status, code in (
            ("malformed", 502, "gateway_malformed_response"),
            ("wrong_shape", 502, "gateway_incompatible"),
            ("bad_provider", 502, "gateway_incompatible"),
            ("unauthorized", 502, "gateway_unauthorized"),
            ("unavailable", 503, "gateway_unavailable"),
        ):
            with self.subTest(mode=mode):
                self.gateway_mode = mode
                response = await self.client.get(
                    "/api/model/options",
                    headers=headers,
                )
                self.assertEqual(status, response.status)
                self.assertEqual(
                    code,
                    (await response.json())["error"]["code"],
                )

    async def test_capabilities_advertise_exact_model_options_surface(
        self,
    ) -> None:
        response = await self.client.get(
            "/companion/v1/capabilities",
            headers={"Authorization": f"Bearer {self.device_credential}"},
        )

        self.assertEqual(200, response.status)
        companion = (await response.json())["companion"]
        self.assertIs(True, companion["features"]["model_options_proxy"])
        self.assertEqual(
            {"method": "GET", "path": "/api/model/options"},
            companion["endpoints"]["model_options"],
        )
        self.assertIs(True, companion["features"]["session_model_lock_proxy"])
        self.assertEqual(
            {
                "method": "POST",
                "path": "/api/sessions/{session_id}/model",
            },
            companion["endpoints"]["session_model_lock"],
        )

    async def test_session_model_lock_forwards_only_verified_selection(
        self,
    ) -> None:
        body = {
            "model": "anthropic/claude-sonnet-4.6",
            "provider": "openrouter",
            "model_options": {
                "reasoning": {"enabled": True, "effort": "high"},
                "reasoning_effort": "high",
            },
        }
        response = await self.client.post(
            "/api/sessions/session-1/model",
            json=body,
            headers={
                "Authorization": f"Bearer {self.device_credential}",
                "X-Private-Client-Header": "must-not-cross-boundary",
            },
        )

        self.assertEqual(200, response.status)
        payload = await response.json()
        self.assertEqual("hermes.session.model_lock", payload["object"])
        self.assertEqual("session-1", payload["session_id"])
        self.assertEqual(
            "anthropic/claude-sonnet-4.6",
            payload["runtime"]["model"],
        )
        self.assertEqual(
            {
                "method": "POST",
                "path": "/api/sessions/session-1/model",
                "query": [],
                "body": body,
                "authorization": "Bearer gateway-model-key",
                "private_header": None,
            },
            self.gateway_requests[-1],
        )

    async def test_session_model_lock_rejects_unverified_body_before_gateway(
        self,
    ) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}
        invalid_bodies = (
            {},
            {"model": "m"},
            {"model": "m", "provider": "p", "api_key": "must-not-pass"},
            {"model": "m", "provider": "p", "model_options": "high"},
            {
                "model": "m",
                "provider": "p",
                "model_options": {"reasoning_effort": "extreme"},
            },
            {
                "model": "m",
                "provider": "p",
                "model_options": {
                    "reasoning": {"enabled": True, "effort": "high"},
                    "reasoning_effort": "high",
                    "service_tier": "priority",
                },
            },
            {
                "model": "m",
                "provider": "p",
                "model_options": {
                    "reasoning": {"enabled": True, "effort": "low"},
                    "reasoning_effort": "high",
                },
            },
        )

        request_count = len(self.gateway_requests)
        for body in invalid_bodies:
            with self.subTest(body=body):
                response = await self.client.post(
                    "/api/sessions/session-1/model",
                    json=body,
                    headers=headers,
                )
                self.assertEqual(400, response.status)
                self.assertEqual(
                    "invalid_model_selection",
                    (await response.json())["error"]["code"],
                )

        query = await self.client.post(
            "/api/sessions/session-1/model?private=1",
            json={"model": "m", "provider": "p"},
            headers=headers,
        )
        wrong_content = await self.client.post(
            "/api/sessions/session-1/model",
            data="model=m",
            headers={**headers, "Content-Type": "text/plain"},
        )
        self.assertEqual(400, query.status)
        self.assertEqual(415, wrong_content.status)
        self.assertEqual(request_count, len(self.gateway_requests))

    async def _pair_device(self) -> str:
        secret = self.registry.create_pairing_secret(300)
        response = await self.client.post(
            "/companion/v1/pairings/claim",
            json={"secret": secret, "device_name": "Model Contract Test"},
        )
        self.assertEqual(201, response.status)
        return (await response.json())["credential"]

    async def _gateway_model_options(
        self,
        request: web.Request,
    ) -> web.Response:
        self.gateway_requests.append(
            {
                "authorization": request.headers.get("Authorization"),
                "query": list(request.query.items()),
                "private_header": request.headers.get(
                    "X-Private-Client-Header"
                ),
            }
        )
        if self.gateway_mode == "malformed":
            return web.Response(text="{", content_type="application/json")
        if self.gateway_mode == "wrong_shape":
            return web.json_response({"object": "list", "data": []})
        if self.gateway_mode == "bad_provider":
            return web.json_response(
                {
                    "providers": [{"slug": "", "models": "not-a-list"}],
                    "model": "m",
                    "provider": "p",
                }
            )
        if self.gateway_mode == "unauthorized":
            return web.json_response({"private": "detail"}, status=403)
        if self.gateway_mode == "unavailable":
            return web.json_response({"private": "detail"}, status=503)
        return web.json_response(
            {
                "providers": [
                    {
                        "slug": "openrouter",
                        "name": "OpenRouter",
                        "models": ["anthropic/claude-sonnet-4.6"],
                        "total_models": 1,
                        "authenticated": True,
                        "capabilities": {
                            "anthropic/claude-sonnet-4.6": {
                                "fast": False,
                                "reasoning": True,
                                "future_capability": "tolerated",
                            }
                        },
                        "future_provider_field": {"tolerated": True},
                    }
                ],
                "model": "anthropic/claude-sonnet-4.6",
                "provider": "openrouter",
                "future_top_level_field": ["tolerated"],
            }
        )

    async def _gateway_model_lock(
        self,
        request: web.Request,
    ) -> web.Response:
        body = await request.json()
        self.gateway_requests.append(
            {
                "method": request.method,
                "path": request.path,
                "query": list(request.query.items()),
                "body": body,
                "authorization": request.headers.get("Authorization"),
                "private_header": request.headers.get(
                    "X-Private-Client-Header"
                ),
            }
        )
        return web.json_response(
            {
                "object": "hermes.session.model_lock",
                "session_id": request.match_info["session_id"],
                "runtime": {
                    "provider": body["provider"],
                    "model": body["model"],
                    "model_lock": "accepted",
                    "future_runtime_field": True,
                },
                "future_field": {"tolerated": True},
            }
        )
