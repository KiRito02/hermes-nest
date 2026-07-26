import asyncio
import io
import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

from hermex_companion.app import create_app
from hermex_companion.gateway import GatewayDiscovery
from hermex_companion.registry import DeviceRegistry
from hermex_companion.run_proxy_contract import RUN_REQUEST_MAX_BODY_BYTES


class RunProxyContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.gateway_requests: list[dict[str, object]] = []
        self.gateway_mode = "ok"
        self.release_stream = asyncio.Event()
        self.first_stream_chunk = (
            b": keepalive\n\n"
            b'data: {"event":"message.delta","text":"First"}\n\n'
        )
        self.final_stream_chunk = (
            b"event: future.transport.type\n"
            b'data: {"event":"run.completed","run_id":"run-1"}\n\n'
            b": stream closed\n\n"
        )

        gateway_app = web.Application(client_max_size=3 * 1024 * 1024)
        gateway_app.router.add_post("/v1/runs", self._gateway_start)
        gateway_app.router.add_get("/v1/runs/{run_id}", self._gateway_status)
        gateway_app.router.add_get(
            "/v1/runs/{run_id}/events",
            self._gateway_events,
        )
        gateway_app.router.add_post(
            "/v1/runs/{run_id}/stop",
            self._gateway_stop,
        )
        self.gateway_server = TestServer(gateway_app)
        await self.gateway_server.start_server()

        self.registry = DeviceRegistry(":memory:")
        companion_app = create_app(
            self.registry,
            GatewayDiscovery(
                str(self.gateway_server.make_url("")).rstrip("/"),
                "gateway-run-key",
            ),
        )
        self.client = TestClient(TestServer(companion_app))
        await self.client.start_server()
        self.device_credential = await self._pair_device()

    async def asyncTearDown(self) -> None:
        self.release_stream.set()
        await self.client.close()
        await self.gateway_server.close()

    async def test_run_rest_contract_preserves_identity_body_and_gateway_auth(
        self,
    ) -> None:
        headers = {
            "Authorization": f"Bearer {self.device_credential}",
            "X-Private-Client-Header": "must-not-cross-boundary",
        }
        long_history = "h" * (20 * 1024)
        start_body = {
            "input": "Continue",
            "session_id": "session-1",
            "conversation_history": [
                {"role": "user", "content": long_history},
            ],
        }

        started = await self.client.post(
            "/v1/runs",
            json=start_body,
            headers=headers,
        )
        status = await self.client.get("/v1/runs/run-1", headers=headers)
        stopped = await self.client.post(
            "/v1/runs/run-1/stop",
            headers=headers,
        )

        self.assertEqual(202, started.status)
        self.assertEqual(
            {"run_id": "run-1", "status": "started"},
            await started.json(),
        )
        self.assertEqual(200, status.status)
        self.assertEqual("session-1", (await status.json())["session_id"])
        self.assertEqual(200, stopped.status)
        self.assertEqual(
            {"run_id": "run-1", "status": "stopping"},
            await stopped.json(),
        )

        self.assertEqual(
            [
                ("POST", "/v1/runs", start_body),
                ("GET", "/v1/runs/run-1", None),
                ("POST", "/v1/runs/run-1/stop", None),
            ],
            [
                (item["method"], item["path"], item["body"])
                for item in self.gateway_requests
            ],
        )
        for item in self.gateway_requests:
            self.assertEqual(
                "Bearer gateway-run-key",
                item["authorization"],
            )
            self.assertIsNone(item["private_header"])
            self.assertEqual([], item["query"])

    async def test_sse_is_forwarded_incrementally_and_byte_for_byte(self) -> None:
        headers = {
            "Authorization": f"Bearer {self.device_credential}",
            "X-Private-Client-Header": "must-not-cross-boundary",
        }

        response = await self.client.get(
            "/v1/runs/run-1/events",
            headers=headers,
        )
        self.assertEqual(200, response.status)
        self.assertEqual("text/event-stream", response.headers["Content-Type"])
        self.assertEqual("no-cache", response.headers["Cache-Control"])
        self.assertEqual("no", response.headers["X-Accel-Buffering"])

        first = await asyncio.wait_for(
            response.content.readexactly(len(self.first_stream_chunk)),
            timeout=1,
        )
        self.assertEqual(self.first_stream_chunk, first)

        self.release_stream.set()
        remainder = await asyncio.wait_for(response.read(), timeout=1)
        self.assertEqual(self.final_stream_chunk, remainder)
        self.assertEqual(
            [
                {
                    "method": "GET",
                    "path": "/v1/runs/run-1/events",
                    "query": [],
                    "body": None,
                    "authorization": "Bearer gateway-run-key",
                    "private_header": None,
                }
            ],
            self.gateway_requests,
        )

    async def test_run_allowlist_rejects_unverified_requests_before_gateway(
        self,
    ) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}

        without_device = await self.client.get("/v1/runs/run-1")
        start_head = await self.client.head("/v1/runs", headers=headers)
        status_head = await self.client.head(
            "/v1/runs/run-1",
            headers=headers,
        )
        events_head = await self.client.head(
            "/v1/runs/run-1/events",
            headers=headers,
        )
        wrong_method = await self.client.delete(
            "/v1/runs/run-1",
            headers=headers,
        )
        query = await self.client.get(
            "/v1/runs/run-1?private=true",
            headers=headers,
        )
        wrong_content = await self.client.post(
            "/v1/runs",
            data="input=No",
            headers={**headers, "Content-Type": "text/plain"},
        )
        stop_body = await self.client.post(
            "/v1/runs/run-1/stop",
            json={"unexpected": True},
            headers=headers,
        )

        self.assertEqual(401, without_device.status)
        self.assertEqual(405, start_head.status)
        self.assertEqual(405, status_head.status)
        self.assertEqual(405, events_head.status)
        self.assertEqual(405, wrong_method.status)
        self.assertEqual(400, query.status)
        self.assertEqual("invalid_query", (await query.json())["error"]["code"])
        self.assertEqual(415, wrong_content.status)
        self.assertEqual(400, stop_body.status)
        self.assertEqual(
            "invalid_request",
            (await stop_body.json())["error"]["code"],
        )
        self.assertEqual([], self.gateway_requests)

    async def test_run_errors_are_sanitized_and_bad_success_is_rejected(
        self,
    ) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}
        self.gateway_mode = "not_found"

        missing = await self.client.get(
            "/v1/runs/missing",
            headers=headers,
        )
        self.assertEqual(404, missing.status)
        self.assertEqual(
            {
                "error": {
                    "code": "run_not_found",
                    "message": "Run not found: missing",
                }
            },
            await missing.json(),
        )

        self.gateway_mode = "incompatible_success"
        incompatible = await self.client.get(
            "/v1/runs/run-1",
            headers=headers,
        )
        self.assertEqual(502, incompatible.status)
        self.assertEqual(
            "gateway_incompatible",
            (await incompatible.json())["error"]["code"],
        )

    async def test_start_request_limit_is_inclusive(self) -> None:
        headers = {
            "Authorization": f"Bearer {self.device_credential}",
            "Content-Type": "application/json",
        }
        prefix = b'{"input":"'
        suffix = b'"}'
        exact_body = (
            prefix
            + b"x" * (RUN_REQUEST_MAX_BODY_BYTES - len(prefix) - len(suffix))
            + suffix
        )
        self.assertEqual(RUN_REQUEST_MAX_BODY_BYTES, len(exact_body))

        accepted = await self.client.post(
            "/v1/runs",
            data=io.BytesIO(exact_body),
            headers=headers,
        )
        rejected = await self.client.post(
            "/v1/runs",
            data=io.BytesIO(exact_body + b" "),
            headers=headers,
        )

        self.assertEqual(202, accepted.status)
        self.assertEqual(413, rejected.status)
        self.assertEqual(1, len(self.gateway_requests))

    async def _pair_device(self) -> str:
        secret = self.registry.create_pairing_secret(300)
        response = await self.client.post(
            "/companion/v1/pairings/claim",
            json={"secret": secret, "device_name": "Run Contract Test"},
        )
        self.assertEqual(201, response.status)
        return (await response.json())["credential"]

    async def _record(self, request: web.Request) -> object | None:
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

    async def _gateway_start(self, request: web.Request) -> web.Response:
        await self._record(request)
        if self.gateway_mode == "incompatible_success":
            return web.json_response({"status": "started"}, status=202)
        return web.json_response(
            {"run_id": "run-1", "status": "started"},
            status=202,
        )

    async def _gateway_status(self, request: web.Request) -> web.Response:
        await self._record(request)
        if self.gateway_mode == "not_found":
            return web.json_response(
                {
                    "error": {
                        "code": "run_not_found",
                        "message": (
                            f"Run not found: {request.match_info['run_id']}"
                        ),
                        "private_path": "/volume/private/run-state.json",
                    },
                    "private_gateway_detail": "loopback-only",
                },
                status=404,
            )
        if self.gateway_mode == "incompatible_success":
            return web.json_response({"object": "unexpected"})
        return web.json_response(
            {
                "object": "hermes.run",
                "run_id": request.match_info["run_id"],
                "status": "running",
                "session_id": "session-1",
                "created_at": 100.0,
                "updated_at": 101.0,
                "future_status_field": {"ignored": True},
            }
        )

    async def _gateway_stop(self, request: web.Request) -> web.Response:
        await self._record(request)
        return web.json_response(
            {
                "run_id": request.match_info["run_id"],
                "status": "stopping",
            }
        )

    async def _gateway_events(self, request: web.Request) -> web.StreamResponse:
        await self._record(request)
        response = web.StreamResponse(
            headers={
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            }
        )
        await response.prepare(request)
        await response.write(self.first_stream_chunk)
        await self.release_stream.wait()
        await response.write(self.final_stream_chunk)
        await response.write_eof()
        return response
