import json
import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from hermex_companion.app import create_app
from hermex_companion.gateway import GatewayDiscovery
from hermex_companion.registry import DeviceRegistry


class DiscoveryProxyContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.gateway_requests: list[dict[str, object]] = []
        self.gateway_mode = "ok"

        gateway_app = web.Application()
        gateway_app.router.add_get("/v1/skills", self._gateway_skills)
        gateway_app.router.add_get("/v1/toolsets", self._gateway_toolsets)
        self.gateway_server = TestServer(gateway_app)
        await self.gateway_server.start_server()

        self.registry = DeviceRegistry(":memory:")
        companion_app = create_app(
            self.registry,
            GatewayDiscovery(
                str(self.gateway_server.make_url("")).rstrip("/"),
                "gateway-discovery-key",
            ),
        )
        self.client = TestClient(TestServer(companion_app))
        await self.client.start_server()
        self.device_credential = await self._pair_device()

    async def asyncTearDown(self) -> None:
        await self.client.close()
        await self.gateway_server.close()

    async def test_read_lists_replace_auth_and_preserve_verified_metadata(
        self,
    ) -> None:
        headers = {
            "Authorization": f"Bearer {self.device_credential}",
            "X-Private-Client-Header": "must-not-cross-boundary",
        }
        skills = await self.client.get("/v1/skills", headers=headers)
        toolsets = await self.client.get("/v1/toolsets", headers=headers)

        self.assertEqual(200, skills.status)
        self.assertEqual(
            {
                "object": "list",
                "data": [
                    {
                        "name": "ios-review",
                        "description": "Review native Swift changes.\\nUse tests.",
                        "category": "coding",
                        "future": {"tolerated": True},
                    },
                    {
                        "name": "uncategorized",
                        "description": "",
                        "category": None,
                    },
                ],
                "future_top_level": ["tolerated"],
            },
            await skills.json(),
        )
        self.assertEqual(200, toolsets.status)
        self.assertEqual(
            {
                "object": "list",
                "platform": "api_server",
                "data": [
                    {
                        "name": "file",
                        "label": "File Tools",
                        "description": "Read and write files.\\nNames stay local.",
                        "enabled": True,
                        "configured": True,
                        "tools": ["read_file", "write_file"],
                        "future": "tolerated",
                    },
                    {
                        "name": "optional",
                        "label": "Optional",
                        "description": "",
                        "enabled": False,
                        "configured": False,
                        "tools": [],
                    },
                ],
                "future_top_level": {"tolerated": True},
            },
            await toolsets.json(),
        )
        self.assertEqual(
            [
                {
                    "path": "/v1/skills",
                    "authorization": "Bearer gateway-discovery-key",
                    "query": [],
                    "private_header": None,
                },
                {
                    "path": "/v1/toolsets",
                    "authorization": "Bearer gateway-discovery-key",
                    "query": [],
                    "private_header": None,
                },
            ],
            self.gateway_requests,
        )

    async def test_allowlist_rejects_unverified_requests_before_gateway(
        self,
    ) -> None:
        without_device = await self.client.get("/v1/skills")
        self.assertEqual(401, without_device.status)

        headers = {"Authorization": f"Bearer {self.device_credential}"}
        responses = (
            await self.client.head("/v1/skills", headers=headers),
            await self.client.post("/v1/skills", headers=headers),
            await self.client.get("/v1/skills?private=1", headers=headers),
            await self.client.request(
                "GET",
                "/v1/skills",
                data=b"private-body",
                headers=headers,
            ),
            await self.client.head("/v1/toolsets", headers=headers),
            await self.client.post("/v1/toolsets", headers=headers),
            await self.client.get("/v1/toolsets?private=1", headers=headers),
            await self.client.request(
                "GET",
                "/v1/toolsets",
                data=b"private-body",
                headers=headers,
            ),
        )

        for response in (responses[0], responses[1], responses[4], responses[5]):
            self.assertEqual(405, response.status)
        for response in (responses[2], responses[6]):
            self.assertEqual(400, response.status)
            self.assertEqual(
                "invalid_query",
                (await response.json())["error"]["code"],
            )
        for response in (responses[3], responses[7]):
            self.assertEqual(400, response.status)
            self.assertEqual(
                "invalid_request",
                (await response.json())["error"]["code"],
            )
        self.assertEqual([], self.gateway_requests)

    async def test_incompatible_gateway_payloads_return_bounded_errors(
        self,
    ) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}
        for mode, status, code in (
            ("malformed", 502, "gateway_malformed_response"),
            ("wrong_content_type", 502, "gateway_incompatible"),
            ("wrong_envelope", 502, "gateway_incompatible"),
            ("bad_skill", 502, "gateway_incompatible"),
            ("bad_toolset", 502, "gateway_incompatible"),
            ("too_many_rows", 502, "gateway_incompatible"),
            ("too_large", 502, "gateway_response_too_large"),
            ("unauthorized", 502, "gateway_unauthorized"),
            ("unavailable", 503, "gateway_unavailable"),
        ):
            with self.subTest(mode=mode):
                self.gateway_mode = mode
                path = (
                    "/v1/toolsets"
                    if mode == "bad_toolset"
                    else "/v1/skills"
                )
                response = await self.client.get(path, headers=headers)
                self.assertEqual(status, response.status)
                body = await response.json()
                self.assertEqual(code, body["error"]["code"])
                self.assertLessEqual(len(body["error"]["message"]), 160)
                serialized = repr(body)
                self.assertNotIn("gateway-discovery-key", serialized)
                self.assertNotIn("private-upstream-detail", serialized)

    async def test_capabilities_advertise_exact_read_only_surface(self) -> None:
        response = await self.client.get(
            "/companion/v1/capabilities",
            headers={"Authorization": f"Bearer {self.device_credential}"},
        )

        self.assertEqual(200, response.status)
        companion = (await response.json())["companion"]
        self.assertIs(True, companion["features"]["skills_proxy"])
        self.assertIs(True, companion["features"]["toolsets_proxy"])
        self.assertEqual(
            {"method": "GET", "path": "/v1/skills"},
            companion["endpoints"]["skills"],
        )
        self.assertEqual(
            {"method": "GET", "path": "/v1/toolsets"},
            companion["endpoints"]["toolsets"],
        )

    async def _pair_device(self) -> str:
        secret = self.registry.create_pairing_secret(300)
        response = await self.client.post(
            "/companion/v1/pairings/claim",
            json={"secret": secret, "device_name": "Discovery Contract Test"},
        )
        self.assertEqual(201, response.status)
        return (await response.json())["credential"]

    async def _gateway_skills(self, request: web.Request) -> web.Response:
        self._record_request(request)
        special = self._special_response(request)
        if special is not None:
            return special
        if self.gateway_mode == "wrong_envelope":
            return web.json_response({"object": "skills", "data": []})
        if self.gateway_mode == "bad_skill":
            return web.json_response(
                {
                    "object": "list",
                    "data": [
                        {
                            "name": "",
                            "description": "private-upstream-detail",
                            "category": "coding",
                        }
                    ],
                }
            )
        if self.gateway_mode == "too_many_rows":
            return web.json_response(
                {
                    "object": "list",
                    "data": [
                        {
                            "name": f"skill-{index}",
                            "description": "",
                            "category": None,
                        }
                        for index in range(2_049)
                    ],
                }
            )
        return web.json_response(
            {
                "object": "list",
                "data": [
                    {
                        "name": "ios-review",
                        "description": "Review native Swift changes.\\nUse tests.",
                        "category": "coding",
                        "future": {"tolerated": True},
                    },
                    {
                        "name": "uncategorized",
                        "description": "",
                        "category": None,
                    },
                ],
                "future_top_level": ["tolerated"],
            }
        )

    async def _gateway_toolsets(self, request: web.Request) -> web.Response:
        self._record_request(request)
        special = self._special_response(request)
        if special is not None:
            return special
        if self.gateway_mode == "bad_toolset":
            return web.json_response(
                {
                    "object": "list",
                    "platform": "api_server",
                    "data": [
                        {
                            "name": "file",
                            "label": "File",
                            "description": "private-upstream-detail",
                            "enabled": "yes",
                            "configured": True,
                            "tools": ["read_file"],
                        }
                    ],
                }
            )
        return web.json_response(
            {
                "object": "list",
                "platform": "api_server",
                "data": [
                    {
                        "name": "file",
                        "label": "File Tools",
                        "description": "Read and write files.\\nNames stay local.",
                        "enabled": True,
                        "configured": True,
                        "tools": ["read_file", "write_file"],
                        "future": "tolerated",
                    },
                    {
                        "name": "optional",
                        "label": "Optional",
                        "description": "",
                        "enabled": False,
                        "configured": False,
                        "tools": [],
                    },
                ],
                "future_top_level": {"tolerated": True},
            }
        )

    def _record_request(self, request: web.Request) -> None:
        self.gateway_requests.append(
            {
                "path": request.path,
                "authorization": request.headers.get("Authorization"),
                "query": list(request.query.items()),
                "private_header": request.headers.get(
                    "X-Private-Client-Header"
                ),
            }
        )

    def _special_response(self, _request: web.Request) -> web.Response | None:
        if self.gateway_mode == "malformed":
            return web.Response(
                body=b"{",
                content_type="application/json",
            )
        if self.gateway_mode == "wrong_content_type":
            return web.Response(text="private-upstream-detail")
        if self.gateway_mode == "too_large":
            return web.Response(
                body=b'{"object":"list","data":[]}' + b" " * (2 * 1024 * 1024),
                content_type="application/json",
            )
        if self.gateway_mode == "unauthorized":
            return web.json_response(
                {"error": "private-upstream-detail"},
                status=401,
            )
        if self.gateway_mode == "unavailable":
            return web.json_response(
                {"error": "private-upstream-detail"},
                status=503,
            )
        return None
