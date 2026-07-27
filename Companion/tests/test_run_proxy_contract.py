import asyncio
import io
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from aiohttp import FormData, web
from aiohttp.test_utils import TestClient, TestServer

from hermex_companion.app import create_app
from hermex_companion.gateway import GatewayDiscovery
from hermex_companion.registry import DeviceRegistry
from hermex_companion.run_proxy_contract import RUN_REQUEST_MAX_BODY_BYTES
from hermex_companion.workspace import WorkspaceAccess, WorkspaceRoot


class RunProxyContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.gateway_requests: list[dict[str, object]] = []
        self.gateway_mode = "ok"
        self.gateway_start_entered = asyncio.Event()
        self.release_gateway_start = asyncio.Event()
        self.release_stream = asyncio.Event()
        self.first_stream_chunk = (
            b": keepalive\n\n"
            b'data: {"event":"message.delta","text":"First"}\n\n'
        )
        self.final_stream_chunk = (
            b"event: future.transport.type\n"
            b'data: {"event":"run.completed","run_id":"run-1",'
            b'"usage":{"input_tokens":144,"output_tokens":34,'
            b'"total_tokens":178}}\n\n'
            b": stream closed\n\n"
        )

        gateway_app = web.Application(client_max_size=3 * 1024 * 1024)
        gateway_app.router.add_post("/v1/runs", self._gateway_start)
        gateway_app.router.add_get(
            "/api/sessions/{session_id}/messages",
            self._gateway_messages,
        )
        gateway_app.router.add_get("/v1/runs/{run_id}", self._gateway_status)
        gateway_app.router.add_get(
            "/v1/runs/{run_id}/events",
            self._gateway_events,
        )
        gateway_app.router.add_post(
            "/v1/runs/{run_id}/stop",
            self._gateway_stop,
        )
        gateway_app.router.add_post(
            "/v1/runs/{run_id}/approval",
            self._gateway_approval,
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
            "model": "anthropic/claude-sonnet-4.6",
            "provider": "openrouter",
            "model_options": {
                "reasoning": {
                    "enabled": True,
                    "effort": "high",
                },
                "reasoning_effort": "high",
            },
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
        status_body = await status.json()
        self.assertEqual("session-1", status_body["session_id"])
        self.assertEqual(
            {
                "input_tokens": 144,
                "output_tokens": 34,
                "total_tokens": 178,
            },
            status_body["usage"],
        )
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

    async def test_ready_attachments_are_resolved_server_side_then_consumed(
        self,
    ) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            host_path = Path(directory) / "agent-workspace"
            incoming = host_path / "incoming"
            incoming.mkdir(parents=True)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ],
                agent_working_directory=host_path,
            )
            companion_app = create_app(
                self.registry,
                GatewayDiscovery(
                    str(self.gateway_server.make_url("")).rstrip("/"),
                    "gateway-run-key",
                ),
                workspace=workspace,
            )
            self.client = TestClient(TestServer(companion_app))
            await self.client.start_server()
            self.device_credential = await self._pair_device()
            headers = {
                "Authorization": f"Bearer {self.device_credential}",
            }
            form = FormData()
            form.add_field(
                "metadata",
                json.dumps(
                    {
                        "root_id": "projects",
                        "directory": "incoming",
                        "session_id": "session-attachments",
                    }
                ),
                content_type="application/json",
            )
            form.add_field(
                "file",
                b"attachment body",
                filename="notes.txt",
                content_type="text/plain",
            )
            uploaded = await self.client.post(
                "/companion/v1/uploads",
                data=form,
                headers=headers,
            )
            upload_id = (await uploaded.json())["upload"]["id"]
            device_id = self.registry.authenticate(
                self.device_credential
            ).id
            stored_relative_path = (
                self.registry.ready_attachment_for_device(
                    device_id=device_id,
                    attachment_id=upload_id,
                ).relative_path
            )

            started = await self.client.post(
                "/v1/runs",
                json={
                    "input": "Summarize the attachment.",
                    "session_id": "session-attachments",
                    "attachment_ids": [upload_id],
                },
                headers=headers,
            )

            self.assertEqual(202, started.status)
            forwarded = self.gateway_requests[-1]["body"]
            self.assertNotIn("attachment_ids", forwarded)
            self.assertIn(stored_relative_path, forwarded["instructions"])
            self.assertNotIn("vision_analyze", forwarded["instructions"])
            self.assertNotIn('"path":"incoming/notes.txt"', forwarded["instructions"])
            self.assertNotIn(str(host_path), forwarded["instructions"])
            pending = await self.client.get(
                "/companion/v1/uploads",
                params={"session_id": "session-attachments"},
                headers=headers,
            )
            self.assertEqual([], (await pending.json())["uploads"])
            downloaded = await self.client.get(
                f"/companion/v1/uploads/{upload_id}/content",
                headers=headers,
            )
            self.assertEqual(200, downloaded.status)
            self.assertEqual(b"attachment body", await downloaded.read())
            self.assertIn(
                'filename="notes.txt"',
                downloaded.headers["Content-Disposition"],
            )
            consumed = self.registry.list_consumed_attachments(
                session_id="session-attachments",
            )
            self.assertEqual(12, consumed[0].prior_message_id)

    async def test_image_attachment_directs_hermes_to_vision_analyze(
        self,
    ) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            host_path = Path(directory) / "agent-workspace"
            incoming = host_path / "incoming"
            incoming.mkdir(parents=True)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ],
                agent_working_directory=host_path,
            )
            companion_app = create_app(
                self.registry,
                GatewayDiscovery(
                    str(self.gateway_server.make_url("")).rstrip("/"),
                    "gateway-run-key",
                ),
                workspace=workspace,
            )
            self.client = TestClient(TestServer(companion_app))
            await self.client.start_server()
            self.device_credential = await self._pair_device()
            headers = {
                "Authorization": f"Bearer {self.device_credential}",
            }
            form = FormData()
            form.add_field(
                "metadata",
                json.dumps(
                    {
                        "root_id": "projects",
                        "directory": "incoming",
                        "session_id": "session-image",
                    }
                ),
                content_type="application/json",
            )
            form.add_field(
                "file",
                b"\x89PNG\r\n\x1a\nimage body",
                filename="diagram.png",
                content_type="application/octet-stream",
            )
            uploaded = await self.client.post(
                "/companion/v1/uploads",
                data=form,
                headers=headers,
            )
            self.assertEqual(201, uploaded.status)
            upload_id = (await uploaded.json())["upload"]["id"]
            device_id = self.registry.authenticate(
                self.device_credential
            ).id
            attachment = self.registry.ready_attachment_for_device(
                device_id=device_id,
                attachment_id=upload_id,
            )

            started = await self.client.post(
                "/v1/runs",
                json={
                    "input": "What does this diagram show?",
                    "session_id": "session-image",
                    "attachment_ids": [upload_id],
                },
                headers=headers,
            )

            self.assertEqual(202, started.status)
            forwarded = self.gateway_requests[-1]["body"]
            self.assertNotIn("attachment_ids", forwarded)
            self.assertIn(attachment.relative_path, forwarded["instructions"])
            self.assertIn("vision_analyze", forwarded["instructions"])
            self.assertNotIn(str(host_path), forwarded["instructions"])

    async def test_attachment_is_claimed_before_concurrent_gateway_start(
        self,
    ) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            host_path = Path(directory) / "agent-workspace"
            host_path.mkdir()
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ],
                agent_working_directory=host_path,
            )
            self.client = TestClient(
                TestServer(
                    create_app(
                        self.registry,
                        GatewayDiscovery(
                            str(self.gateway_server.make_url("")).rstrip("/"),
                            "gateway-run-key",
                        ),
                        workspace=workspace,
                    )
                )
            )
            await self.client.start_server()
            self.device_credential = await self._pair_device()
            headers = {
                "Authorization": f"Bearer {self.device_credential}",
            }
            form = FormData()
            form.add_field(
                "metadata",
                json.dumps(
                    {
                        "root_id": "projects",
                        "directory": "",
                        "session_id": "session-concurrent",
                    }
                ),
                content_type="application/json",
            )
            form.add_field(
                "file",
                b"attachment body",
                filename="notes.txt",
                content_type="text/plain",
            )
            uploaded = await self.client.post(
                "/companion/v1/uploads",
                data=form,
                headers=headers,
            )
            upload_id = (await uploaded.json())["upload"]["id"]
            body = {
                "input": "Read this.",
                "session_id": "session-concurrent",
                "attachment_ids": [upload_id],
            }
            self.gateway_mode = "block_start"

            first_task = asyncio.create_task(
                self.client.post("/v1/runs", json=body, headers=headers)
            )
            await asyncio.wait_for(
                self.gateway_start_entered.wait(),
                timeout=1,
            )
            second = await self.client.post(
                "/v1/runs",
                json=body,
                headers=headers,
            )
            self.release_gateway_start.set()
            first = await first_task

            self.assertEqual(202, first.status)
            self.assertEqual(409, second.status)
            self.assertEqual(
                "attachment_not_ready",
                (await second.json())["error"]["code"],
            )
            self.assertEqual(
                1,
                len(
                    [
                        request
                        for request in self.gateway_requests
                        if request["path"] == "/v1/runs"
                    ]
                ),
            )

    async def test_attachment_outside_agent_working_directory_is_rejected(
        self,
    ) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            container = Path(directory)
            agent_path = container / "agent-workspace"
            host_path = container / "browse-only"
            agent_path.mkdir()
            host_path.mkdir()
            attached_file = host_path / "notes.txt"
            attached_file.write_text("attachment", encoding="utf-8")
            self.registry = DeviceRegistry(":memory:")
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="browse-only",
                        name="Browse Only",
                        path=host_path,
                        writable=True,
                    )
                ],
                agent_working_directory=agent_path,
            )
            companion_app = create_app(
                self.registry,
                GatewayDiscovery(
                    str(self.gateway_server.make_url("")).rstrip("/"),
                    "gateway-run-key",
                ),
                workspace=workspace,
            )
            self.client = TestClient(TestServer(companion_app))
            await self.client.start_server()
            self.device_credential = await self._pair_device()
            device = self.registry.authenticate(self.device_credential)
            attachment_id = self.registry.reserve_attachment(
                device_id=device.id,
                session_id="session-outside",
                root_id="browse-only",
                relative_path="notes.txt",
                name="notes.txt",
                content_type="text/plain",
            )
            self.registry.add_attachment_bytes(
                attachment_id,
                attached_file.stat().st_size,
            )
            self.registry.complete_attachment(attachment_id)

            response = await self.client.post(
                "/v1/runs",
                json={
                    "input": "Read it.",
                    "session_id": "session-outside",
                    "attachment_ids": [attachment_id],
                },
                headers={
                    "Authorization": f"Bearer {self.device_credential}",
                },
            )

            self.assertEqual(409, response.status)
            self.assertEqual(
                "attachment_agent_path_unavailable",
                (await response.json())["error"]["code"],
            )
            self.assertEqual([], self.gateway_requests)

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

    async def test_approval_preserves_exact_run_choice_and_gateway_auth(
        self,
    ) -> None:
        headers = {
            "Authorization": f"Bearer {self.device_credential}",
            "X-Private-Client-Header": "must-not-cross-boundary",
        }

        response = await self.client.post(
            "/v1/runs/run-approval-1/approval",
            json={"choice": "deny"},
            headers=headers,
        )

        self.assertEqual(200, response.status)
        self.assertEqual(
            {
                "object": "hermes.run.approval_response",
                "run_id": "run-approval-1",
                "choice": "deny",
                "resolved": 1,
            },
            await response.json(),
        )
        self.assertEqual(
            [
                {
                    "method": "POST",
                    "path": "/v1/runs/run-approval-1/approval",
                    "query": [],
                    "body": {"choice": "deny"},
                    "authorization": "Bearer gateway-run-key",
                    "private_header": None,
                }
            ],
            self.gateway_requests,
        )

    async def test_approval_rejects_unsupported_input_before_gateway(
        self,
    ) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}

        without_device = await self.client.post(
            "/v1/runs/run-1/approval",
            json={"choice": "deny"},
        )
        with_query = await self.client.post(
            "/v1/runs/run-1/approval?all=true",
            json={"choice": "deny"},
            headers=headers,
        )
        wrong_content = await self.client.post(
            "/v1/runs/run-1/approval",
            data="choice=deny",
            headers={**headers, "Content-Type": "text/plain"},
        )
        alias_choice = await self.client.post(
            "/v1/runs/run-1/approval",
            json={"choice": "approve"},
            headers=headers,
        )
        resolve_all = await self.client.post(
            "/v1/runs/run-1/approval",
            json={"choice": "deny", "resolve_all": True},
            headers=headers,
        )

        self.assertEqual(401, without_device.status)
        self.assertEqual(400, with_query.status)
        self.assertEqual(
            "invalid_query",
            (await with_query.json())["error"]["code"],
        )
        self.assertEqual(415, wrong_content.status)
        self.assertEqual(400, alias_choice.status)
        self.assertEqual(
            "invalid_approval_choice",
            (await alias_choice.json())["error"]["code"],
        )
        self.assertEqual(400, resolve_all.status)
        self.assertEqual(
            "invalid_approval_request",
            (await resolve_all.json())["error"]["code"],
        )
        self.assertEqual([], self.gateway_requests)

    async def test_approval_expiry_error_is_bounded_and_sanitized(self) -> None:
        headers = {"Authorization": f"Bearer {self.device_credential}"}
        self.gateway_mode = "approval_not_pending"

        response = await self.client.post(
            "/v1/runs/run-1/approval",
            json={"choice": "once"},
            headers=headers,
        )

        self.assertEqual(409, response.status)
        self.assertEqual(
            {
                "error": {
                    "code": "approval_not_pending",
                    "message": "No approval is pending for this run.",
                }
            },
            await response.json(),
        )

        self.gateway_mode = "approval_identity_mismatch"
        mismatch = await self.client.post(
            "/v1/runs/run-1/approval",
            json={"choice": "once"},
            headers=headers,
        )
        self.assertEqual(502, mismatch.status)
        self.assertEqual(
            "gateway_incompatible",
            (await mismatch.json())["error"]["code"],
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
        if self.gateway_mode == "block_start":
            self.gateway_start_entered.set()
            await self.release_gateway_start.wait()
        if self.gateway_mode == "incompatible_success":
            return web.json_response({"status": "started"}, status=202)
        return web.json_response(
            {"run_id": "run-1", "status": "started"},
            status=202,
        )

    async def _gateway_messages(self, request: web.Request) -> web.Response:
        await self._record(request)
        return web.json_response(
            {
                "object": "list",
                "session_id": request.match_info["session_id"],
                "data": [
                    {
                        "id": 11,
                        "session_id": request.match_info["session_id"],
                        "role": "user",
                        "content": "Earlier",
                    },
                    {
                        "id": 12,
                        "session_id": request.match_info["session_id"],
                        "role": "assistant",
                        "content": "Earlier reply",
                    },
                ],
            }
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
                "usage": {
                    "input_tokens": 144,
                    "output_tokens": 34,
                    "total_tokens": 178,
                },
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

    async def _gateway_approval(self, request: web.Request) -> web.Response:
        body = await self._record(request)
        if self.gateway_mode == "approval_not_pending":
            return web.json_response(
                {
                    "error": {
                        "code": "approval_not_pending",
                        "message": "No approval is pending for this run.",
                        "private_path": "/volume/private/approval-state.json",
                    },
                    "private_gateway_detail": "loopback-only",
                },
                status=409,
            )
        response_run_id = (
            "another-run"
            if self.gateway_mode == "approval_identity_mismatch"
            else request.match_info["run_id"]
        )
        return web.json_response(
            {
                "object": "hermes.run.approval_response",
                "run_id": response_run_id,
                "choice": body["choice"],
                "resolved": 1,
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
