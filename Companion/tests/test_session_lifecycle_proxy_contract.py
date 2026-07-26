import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from hermex_companion.app import create_app
from hermex_companion.gateway import GatewayDiscovery
from hermex_companion.registry import DeviceRegistry


class SessionLifecycleProxyContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.gateway_requests: list[dict[str, object]] = []
        self.gateway_mode = "ok"
        gateway_app = web.Application()
        gateway_app.router.add_post("/api/sessions", self._gateway_create)
        gateway_app.router.add_get(
            "/api/sessions/{session_id}",
            self._gateway_resource,
        )
        gateway_app.router.add_patch(
            "/api/sessions/{session_id}",
            self._gateway_resource,
        )
        gateway_app.router.add_delete(
            "/api/sessions/{session_id}",
            self._gateway_resource,
        )
        gateway_app.router.add_get(
            "/api/sessions/{session_id}/messages",
            self._gateway_messages,
        )
        gateway_app.router.add_post(
            "/api/sessions/{session_id}/fork",
            self._gateway_fork,
        )
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

    async def test_lifecycle_methods_preserve_success_bodies_and_gateway_identity(
        self,
    ) -> None:
        headers = {
            "Authorization": f"Bearer {self.device_credential}",
            "X-Private-Client-Header": "must-not-cross-boundary",
        }

        create = await self.client.post(
            "/api/sessions",
            json={"title": "Mobile chat", "source": "ios"},
            headers=headers,
        )
        detail = await self.client.get("/api/sessions/session-1", headers=headers)
        update = await self.client.patch(
            "/api/sessions/session-1",
            json={"title": "Renamed"},
            headers=headers,
        )
        messages = await self.client.get(
            "/api/sessions/session-1/messages",
            headers=headers,
        )
        fork = await self.client.post(
            "/api/sessions/session-1/fork",
            json={"title": "Alternative"},
            headers=headers,
        )
        delete = await self.client.delete(
            "/api/sessions/session-1",
            headers=headers,
        )

        self.assertEqual(201, create.status)
        self.assertEqual("session-1", (await create.json())["session"]["id"])
        self.assertEqual(200, detail.status)
        self.assertEqual("api_server", (await detail.json())["session"]["source"])
        self.assertEqual(200, update.status)
        self.assertEqual("Renamed", (await update.json())["session"]["title"])
        self.assertEqual(
            {
                "object": "list",
                "session_id": "session-1",
                "data": [
                    {
                        "id": 41,
                        "session_id": "session-1",
                        "role": "assistant",
                        "content": "Hello",
                        "future_message_field": {"ignored": True},
                    }
                ],
                "future_page_field": "preserved",
            },
            await messages.json(),
        )
        self.assertEqual(201, fork.status)
        self.assertEqual(
            "session-1",
            (await fork.json())["session"]["parent_session_id"],
        )
        self.assertEqual(
            {
                "object": "hermes.session.deleted",
                "id": "session-1",
                "deleted": True,
            },
            await delete.json(),
        )

        self.assertEqual(
            [
                ("POST", "/api/sessions", {"title": "Mobile chat", "source": "ios"}),
                ("GET", "/api/sessions/session-1", None),
                ("PATCH", "/api/sessions/session-1", {"title": "Renamed"}),
                ("GET", "/api/sessions/session-1/messages", None),
                ("POST", "/api/sessions/session-1/fork", {"title": "Alternative"}),
                ("DELETE", "/api/sessions/session-1", None),
            ],
            [
                (request["method"], request["path"], request["body"])
                for request in self.gateway_requests
            ],
        )
        for request in self.gateway_requests:
            self.assertEqual(
                "Bearer gateway-test-key",
                request["authorization"],
            )
            self.assertIsNone(request["private_header"])
            self.assertEqual([], request["query"])

    async def test_exact_allowlist_and_request_bounds_precede_gateway(self) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}

        without_device = await self.client.get("/api/sessions/session-1")
        implicit_detail_head = await self.client.head(
            "/api/sessions/session-1",
            headers=headers,
        )
        implicit_messages_head = await self.client.head(
            "/api/sessions/session-1/messages",
            headers=headers,
        )
        unsupported_method = await self.client.put(
            "/api/sessions/session-1",
            json={"title": "No"},
            headers=headers,
        )
        unsupported_suffix = await self.client.get(
            "/api/sessions/session-1/export",
            headers=headers,
        )
        unsupported_query = await self.client.get(
            "/api/sessions/session-1/messages?limit=1",
            headers=headers,
        )
        non_json = await self.client.patch(
            "/api/sessions/session-1",
            data="title=No",
            headers={**headers, "Content-Type": "text/plain"},
        )

        self.assertEqual(401, without_device.status)
        self.assertEqual(405, implicit_detail_head.status)
        self.assertEqual(405, implicit_messages_head.status)
        self.assertEqual(405, unsupported_method.status)
        self.assertEqual(404, unsupported_suffix.status)
        self.assertEqual(400, unsupported_query.status)
        self.assertEqual(
            "invalid_query",
            (await unsupported_query.json())["error"]["code"],
        )
        self.assertEqual(415, non_json.status)
        self.assertEqual([], self.gateway_requests)

    async def test_gateway_client_error_is_preserved_but_bad_success_is_bounded(
        self,
    ) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}
        self.gateway_mode = "not_found"
        missing = await self.client.get(
            "/api/sessions/missing",
            headers=headers,
        )

        self.assertEqual(404, missing.status)
        self.assertEqual(
            {
                "error": {
                    "code": "session_not_found",
                    "message": "Session not found: missing",
                }
            },
            await missing.json(),
        )

        self.gateway_mode = "incompatible_success"
        incompatible = await self.client.get(
            "/api/sessions/session-1",
            headers=headers,
        )
        self.assertEqual(502, incompatible.status)
        self.assertEqual(
            "gateway_incompatible",
            (await incompatible.json())["error"]["code"],
        )

    async def _pair_device(self) -> str:
        secret = self.registry.create_pairing_secret(300)
        response = await self.client.post(
            "/companion/v1/pairings/claim",
            json={"secret": secret, "device_name": "Lifecycle Contract Test"},
        )
        self.assertEqual(201, response.status)
        return (await response.json())["credential"]

    async def _record(
        self,
        request: web.Request,
    ) -> dict[str, object] | None:
        body = await request.json() if request.can_read_body else None
        self.gateway_requests.append(
            {
                "method": request.method,
                "path": request.path,
                "query": list(request.query.items()),
                "body": body,
                "authorization": request.headers.get("Authorization"),
                "private_header": request.headers.get("X-Private-Client-Header"),
            }
        )
        return body

    async def _gateway_create(self, request: web.Request) -> web.Response:
        body = await self._record(request)
        return web.json_response(
            {
                "object": "hermes.session",
                "session": {
                    "id": "session-1",
                    "source": body.get("source"),
                    "title": body.get("title"),
                },
            },
            status=201,
        )

    async def _gateway_resource(self, request: web.Request) -> web.Response:
        body = await self._record(request)
        if self.gateway_mode == "not_found":
            return web.json_response(
                {
                    "error": {
                        "code": "session_not_found",
                        "message": f"Session not found: {request.match_info['session_id']}",
                        "private_path": "/volume/private/state.db",
                    },
                    "private_gateway_detail": {"loopback": "127.0.0.1:8642"},
                },
                status=404,
            )
        if self.gateway_mode == "incompatible_success":
            return web.json_response({"object": "unexpected"})
        if request.method == "DELETE":
            return web.json_response(
                {
                    "object": "hermes.session.deleted",
                    "id": request.match_info["session_id"],
                    "deleted": True,
                }
            )
        return web.json_response(
            {
                "object": "hermes.session",
                "session": {
                    "id": request.match_info["session_id"],
                    "source": "api_server",
                    "title": body.get("title") if body else "Mobile chat",
                },
            }
        )

    async def _gateway_messages(self, request: web.Request) -> web.Response:
        await self._record(request)
        return web.json_response(
            {
                "object": "list",
                "session_id": request.match_info["session_id"],
                "data": [
                    {
                        "id": 41,
                        "session_id": request.match_info["session_id"],
                        "role": "assistant",
                        "content": "Hello",
                        "future_message_field": {"ignored": True},
                    }
                ],
                "future_page_field": "preserved",
            }
        )

    async def _gateway_fork(self, request: web.Request) -> web.Response:
        body = await self._record(request)
        return web.json_response(
            {
                "object": "hermes.session",
                "session": {
                    "id": "session-fork",
                    "source": "api_server",
                    "title": body.get("title"),
                    "parent_session_id": request.match_info["session_id"],
                },
            },
            status=201,
        )
