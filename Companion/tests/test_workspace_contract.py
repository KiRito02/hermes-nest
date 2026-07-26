import unittest
import asyncio
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from aiohttp.test_utils import TestClient, TestServer
from aiohttp import FormData

from hermex_companion.app import (
    create_app,
    _upload_file,
    REGISTRY_KEY,
    WORKSPACE_KEY,
)
from hermex_companion.paths import workspace_config_path
from hermex_companion.registry import DeviceRegistry, RegistryError
from hermex_companion.workspace import (
    MAX_DIRECTORY_SCAN_ENTRIES,
    WorkspaceAccess,
    WorkspaceRoot,
)
from hermex_companion.workspace import WorkspaceError


class FakeMultipartPart:
    def __init__(
        self,
        *,
        name: str,
        chunks: list[bytes],
        filename: str | None = None,
        block_after_chunks: asyncio.Event | None = None,
    ) -> None:
        self.name = name
        self.filename = filename
        self._chunks = list(chunks)
        self._block_after_chunks = block_after_chunks

    async def read_chunk(self, _size: int) -> bytes:
        if self._chunks:
            return self._chunks.pop(0)
        if self._block_after_chunks is not None:
            self._block_after_chunks.set()
            await asyncio.Event().wait()
        return b""


class FakeMultipartReader:
    def __init__(self, parts: list[FakeMultipartPart]) -> None:
        self._parts = list(parts)

    async def next(self) -> FakeMultipartPart | None:
        return self._parts.pop(0) if self._parts else None


class FakeUploadRequest:
    def __init__(
        self,
        *,
        registry: DeviceRegistry,
        workspace: WorkspaceAccess,
        credential: str,
        reader: FakeMultipartReader,
    ) -> None:
        self.query: dict[str, str] = {}
        self.content_type = "multipart/form-data"
        self.headers = {"Authorization": f"Bearer {credential}"}
        self.app = {
            REGISTRY_KEY: registry,
            WORKSPACE_KEY: workspace,
        }
        self._reader = reader

    async def multipart(self) -> FakeMultipartReader:
        return self._reader


class WorkspaceContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.registry = DeviceRegistry(":memory:")
        self.client = TestClient(TestServer(create_app(self.registry)))
        await self.client.start_server()
        secret = self.registry.create_pairing_secret(300)
        self.credential = self.registry.claim_pairing_secret(
            secret,
            "Workspace Test Device",
        ).credential

    async def asyncTearDown(self) -> None:
        await self.client.close()

    async def test_root_listing_is_authenticated_and_empty_by_default(self) -> None:
        unauthenticated = await self.client.get("/companion/v1/files/roots")
        self.assertEqual(401, unauthenticated.status)

        response = await self.client.get(
            "/companion/v1/files/roots",
            headers={"Authorization": f"Bearer {self.credential}"},
        )

        self.assertEqual(200, response.status)
        self.assertEqual({"roots": []}, await response.json())
        self.assertEqual("no-store", response.headers["Cache-Control"])

    async def test_root_listing_exposes_alias_but_never_host_path(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "owner-projects"
            host_path.mkdir()
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            response = await self.client.get(
                "/companion/v1/files/roots",
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(200, response.status)
            body = await response.json()
            self.assertEqual(
                {
                    "roots": [
                        {
                            "id": "projects",
                            "name": "Projects",
                            "writable": True,
                            "attachable": False,
                        }
                    ]
                },
                body,
            )
            self.assertNotIn(str(host_path), repr(body))

    async def test_root_listing_marks_only_agent_working_directory_roots_attachable(
        self,
    ) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            container = Path(directory)
            agent_directory = container / "agent"
            agent_directory.mkdir()
            project_root = agent_directory / "projects"
            project_root.mkdir()
            archive_root = container / "archive"
            archive_root.mkdir()
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=project_root,
                        writable=True,
                    ),
                    WorkspaceRoot(
                        id="archive",
                        name="Archive",
                        path=archive_root,
                    ),
                ],
                agent_working_directory=agent_directory,
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            response = await self.client.get(
                "/companion/v1/files/roots",
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(200, response.status)
            roots = (await response.json())["roots"]
            self.assertEqual(
                [True, False],
                [root["attachable"] for root in roots],
            )
            self.assertNotIn(str(container), repr(roots))

    async def test_authorized_root_directory_can_be_browsed(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "owner-projects"
            host_path.mkdir()
            (host_path / "src").mkdir()
            (host_path / "README.md").write_text("hello\n", encoding="utf-8")
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            response = await self.client.get(
                "/companion/v1/files/roots/projects/entries",
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(200, response.status)
            self.assertEqual(
                {
                    "root_id": "projects",
                    "path": "",
                    "entries": [
                        {
                            "name": "src",
                            "path": "src",
                            "kind": "directory",
                            "size": None,
                        },
                        {
                            "name": "README.md",
                            "path": "README.md",
                            "kind": "file",
                            "size": 6,
                        },
                    ],
                    "next_cursor": None,
                },
                await response.json(),
            )

    async def test_directory_browse_rejects_paths_outside_authorized_root(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            container = Path(directory)
            host_path = container / "owner-projects"
            host_path.mkdir()
            (container / "secret.txt").write_text("private", encoding="utf-8")
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            for requested_path in ("../", "../secret.txt", str(container)):
                with self.subTest(requested_path=requested_path):
                    response = await self.client.get(
                        "/companion/v1/files/roots/projects/entries",
                        params={"path": requested_path},
                        headers={"Authorization": f"Bearer {self.credential}"},
                    )

                    self.assertEqual(403, response.status)
                    self.assertEqual(
                        "workspace_path_forbidden",
                        (await response.json())["error"]["code"],
                    )

    async def test_sensitive_workspace_entries_are_not_listed(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "owner-projects"
            host_path.mkdir()
            (host_path / "notes.txt").write_text("safe", encoding="utf-8")
            (host_path / ".env").write_text("TOKEN=secret", encoding="utf-8")
            (host_path / ".ssh").mkdir()
            (host_path / ".ssh" / "id_ed25519").write_text(
                "private",
                encoding="utf-8",
            )
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            response = await self.client.get(
                "/companion/v1/files/roots/projects/entries",
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(200, response.status)
            body = await response.json()
            self.assertEqual(["notes.txt"], [entry["name"] for entry in body["entries"]])
            self.assertNotIn("secret", repr(body).lower())

    async def test_symbolic_links_are_not_exposed_as_workspace_entries(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            container = Path(directory)
            host_path = container / "owner-projects"
            host_path.mkdir()
            outside = container / "outside"
            outside.mkdir()
            (outside / "secret.txt").write_text("private", encoding="utf-8")
            (host_path / "outside-link").symlink_to(outside, target_is_directory=True)
            (host_path / "file-link").symlink_to(outside / "secret.txt")
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            workspace = WorkspaceAccess(
                [WorkspaceRoot(id="projects", name="Projects", path=host_path)]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            response = await self.client.get(
                "/companion/v1/files/roots/projects/entries",
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(200, response.status)
            self.assertEqual([], (await response.json())["entries"])

    async def test_in_root_symlink_cannot_alias_a_sensitive_file(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            host_path = Path(directory) / "owner-projects"
            sensitive_path = host_path / ".ssh"
            sensitive_path.mkdir(parents=True)
            secret_path = sensitive_path / "id_ed25519"
            secret_path.write_text("private", encoding="utf-8")
            (host_path / "notes.txt").symlink_to(secret_path)
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            workspace = WorkspaceAccess(
                [WorkspaceRoot(id="projects", name="Projects", path=host_path)]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            response = await self.client.get(
                "/companion/v1/files/roots/projects/download",
                params={"path": "notes.txt"},
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(403, response.status)
            self.assertEqual(
                "workspace_path_forbidden",
                (await response.json())["error"]["code"],
            )

    async def test_configured_root_symlink_cannot_be_retargeted_after_startup(
        self,
    ) -> None:
        with TemporaryDirectory() as directory:
            container = Path(directory)
            first = container / "first"
            second = container / "second"
            first.mkdir()
            second.mkdir()
            (first / "allowed.txt").write_text("allowed", encoding="utf-8")
            (second / "secret.txt").write_text("secret", encoding="utf-8")
            configured = container / "configured"
            configured.symlink_to(first, target_is_directory=True)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=configured,
                    )
                ]
            )
            configured.unlink()
            configured.symlink_to(second, target_is_directory=True)

            listing = workspace.list_directory("projects")

            self.assertEqual(
                ["allowed.txt"],
                [entry["name"] for entry in listing["entries"]],
            )
            self.assertNotIn("secret", repr(listing))

    async def test_sensitive_directory_cannot_be_opened_by_known_path(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "owner-projects"
            sensitive_path = host_path / ".ssh"
            sensitive_path.mkdir(parents=True)
            (sensitive_path / "id_ed25519").write_text(
                "private",
                encoding="utf-8",
            )
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            response = await self.client.get(
                "/companion/v1/files/roots/projects/entries",
                params={"path": ".ssh"},
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(403, response.status)
            self.assertEqual(
                "workspace_path_forbidden",
                (await response.json())["error"]["code"],
            )

    async def test_directory_listing_is_paginated_with_bounded_cursor(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "owner-projects"
            host_path.mkdir()
            for name in ("a.txt", "b.txt", "c.txt"):
                (host_path / name).write_text(name, encoding="utf-8")
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()
            headers = {"Authorization": f"Bearer {self.credential}"}

            first_response = await self.client.get(
                "/companion/v1/files/roots/projects/entries",
                params={"limit": "2"},
                headers=headers,
            )
            first = await first_response.json()
            self.assertEqual(200, first_response.status)
            self.assertEqual(["a.txt", "b.txt"], [item["name"] for item in first["entries"]])
            self.assertEqual("2", first["next_cursor"])

            second_response = await self.client.get(
                "/companion/v1/files/roots/projects/entries",
                params={"limit": "2", "cursor": first["next_cursor"]},
                headers=headers,
            )
            second = await second_response.json()

            self.assertEqual(200, second_response.status)
            self.assertEqual(["c.txt"], [item["name"] for item in second["entries"]])
            self.assertIsNone(second["next_cursor"])

    async def test_directory_page_limit_cannot_exceed_server_bound(self) -> None:
        response = await self.client.get(
            "/companion/v1/files/roots/missing/entries",
            params={"limit": "201"},
            headers={"Authorization": f"Bearer {self.credential}"},
        )

        self.assertEqual(400, response.status)
        self.assertEqual("invalid_query", (await response.json())["error"]["code"])

    def test_directory_scan_rejects_work_beyond_server_bound(self) -> None:
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for index in range(MAX_DIRECTORY_SCAN_ENTRIES + 1):
                (root / f"{index:05}.txt").touch()
            workspace = WorkspaceAccess(
                [WorkspaceRoot(id="projects", name="Projects", path=root)]
            )

            with self.assertRaisesRegex(
                WorkspaceError,
                "safe scan limit",
            ):
                workspace.list_directory("projects", limit=1)

    async def test_unknown_root_alias_is_not_resolved_as_a_host_path(self) -> None:
        response = await self.client.get(
            "/companion/v1/files/roots/etc/entries",
            headers={"Authorization": f"Bearer {self.credential}"},
        )

        self.assertEqual(404, response.status)
        self.assertEqual(
            {
                "error": {
                    "code": "workspace_root_not_found",
                    "message": "The requested workspace root is not authorized.",
                }
            },
            await response.json(),
        )

    async def test_text_file_preview_is_bounded_and_selectable_as_text(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "owner-projects"
            host_path.mkdir()
            (host_path / "notes.txt").write_text("hello\n", encoding="utf-8")
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            response = await self.client.get(
                "/companion/v1/files/roots/projects/preview",
                params={"path": "notes.txt"},
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(200, response.status)
            self.assertEqual(
                {
                    "root_id": "projects",
                    "path": "notes.txt",
                    "name": "notes.txt",
                    "kind": "text",
                    "content_type": "text/plain",
                    "size": 6,
                    "truncated": False,
                    "content": "hello\n",
                },
                await response.json(),
            )

    async def test_authorized_file_can_be_downloaded_without_host_path_header(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "owner-projects"
            host_path.mkdir()
            (host_path / "report.pdf").write_bytes(b"%PDF-test")
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            response = await self.client.get(
                "/companion/v1/files/roots/projects/download",
                params={"path": "report.pdf"},
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(200, response.status)
            self.assertEqual(b"%PDF-test", await response.read())
            self.assertEqual("application/pdf", response.content_type)
            self.assertIn(
                'filename="report.pdf"',
                response.headers["Content-Disposition"],
            )
            self.assertNotIn(str(host_path), repr(response.headers))

    async def test_host_configuration_loads_absolute_root_aliases(self) -> None:
        with TemporaryDirectory() as directory:
            container = Path(directory)
            host_path = container / "owner-projects"
            host_path.mkdir()
            config_path = container / "workspaces.json"
            config_path.write_text(
                json.dumps(
                    {
                        "roots": [
                            {
                                "id": "projects",
                                "name": "Projects",
                                "path": str(host_path),
                                "writable": True,
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            workspace = WorkspaceAccess.from_config_file(config_path)

            self.assertEqual(
                [
                    {
                        "id": "projects",
                        "name": "Projects",
                        "writable": True,
                        "attachable": False,
                    }
                ],
                workspace.public_roots(),
            )

    async def test_host_configuration_rejects_relative_root_paths(self) -> None:
        with TemporaryDirectory() as directory:
            config_path = Path(directory) / "workspaces.json"
            config_path.write_text(
                json.dumps(
                    {
                        "roots": [
                            {
                                "id": "projects",
                                "name": "Projects",
                                "path": "../projects",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                ValueError,
                "workspace root paths must be absolute",
            ):
                WorkspaceAccess.from_config_file(config_path)

    async def test_host_configuration_rejects_duplicate_or_invalid_root_aliases(
        self,
    ) -> None:
        with TemporaryDirectory() as directory:
            container = Path(directory)
            root = container / "projects"
            root.mkdir()
            config_path = container / "workspaces.json"
            invalid_payloads = (
                {
                    "roots": [
                        {"id": "projects", "name": "Projects", "path": str(root)},
                        {"id": "projects", "name": "Other", "path": str(root)},
                    ]
                },
                {
                    "roots": [
                        {"id": "../projects", "name": "Projects", "path": str(root)}
                    ]
                },
                {
                    "roots": [
                        {"id": "projects", "name": "", "path": str(root)}
                    ]
                },
            )

            for payload in invalid_payloads:
                with self.subTest(payload=payload):
                    config_path.write_text(json.dumps(payload), encoding="utf-8")
                    with self.assertRaises(ValueError):
                        WorkspaceAccess.from_config_file(config_path)

    async def test_host_configuration_rejects_missing_or_mistyped_root_fields(
        self,
    ) -> None:
        with TemporaryDirectory() as directory:
            container = Path(directory)
            root = container / "projects"
            root.mkdir()
            config_path = container / "workspaces.json"
            invalid_roots = (
                {"name": "Projects", "path": str(root)},
                {"id": 7, "name": "Projects", "path": str(root)},
                {"id": "projects", "name": 7, "path": str(root)},
                {"id": "projects", "name": "Projects", "path": 7},
                {
                    "id": "projects",
                    "name": "Projects",
                    "path": str(root),
                    "writable": "yes",
                },
            )

            for invalid_root in invalid_roots:
                with self.subTest(invalid_root=invalid_root):
                    config_path.write_text(
                        json.dumps({"roots": [invalid_root]}),
                        encoding="utf-8",
                    )
                    with self.assertRaises(ValueError):
                        WorkspaceAccess.from_config_file(config_path)

    async def test_host_configuration_allows_memory_only_with_zero_roots(
        self,
    ) -> None:
        with TemporaryDirectory() as directory:
            config_path = Path(directory) / "workspaces.json"
            config_path.write_text(
                json.dumps({"memory": {"directory": directory}}),
                encoding="utf-8",
            )

            workspace = WorkspaceAccess.from_config_file(config_path)

            self.assertEqual([], workspace.public_roots())

    async def test_workspace_configuration_uses_owner_xdg_config_home(self) -> None:
        with TemporaryDirectory() as directory:
            config_home = Path(directory)

            self.assertEqual(
                config_home / "hermex-companion" / "workspaces.json",
                workspace_config_path({"XDG_CONFIG_HOME": str(config_home)}),
            )

    async def test_file_upload_streams_then_atomically_publishes(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "owner-projects"
            destination = host_path / "incoming"
            destination.mkdir(parents=True)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()
            form = FormData()
            form.add_field(
                "metadata",
                json.dumps(
                    {
                        "root_id": "projects",
                        "directory": "incoming",
                        "session_id": "session-upload",
                    }
                ),
                content_type="application/json",
            )
            form.add_field(
                "file",
                b"hello upload\n",
                filename="notes.txt",
                content_type="text/plain",
            )

            response = await self.client.post(
                "/companion/v1/uploads",
                data=form,
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(201, response.status)
            body = await response.json()
            self.assertEqual(
                {
                    "root_id": "projects",
                    "name": "notes.txt",
                    "size": 13,
                    "content_type": "text/plain",
                    "state": "ready",
                },
                {
                    key: body["upload"][key]
                    for key in (
                        "root_id",
                        "name",
                        "size",
                        "content_type",
                        "state",
                    )
                },
            )
            self.assertTrue(body["upload"]["id"])
            self.assertNotIn("path", body["upload"])
            device_id = self.registry.authenticate(
                self.credential
            ).id
            record = self.registry.list_ready_attachments(
                device_id=device_id,
                session_id="session-upload",
            )[0]
            stored = host_path / record.relative_path
            self.assertEqual(b"hello upload\n", stored.read_bytes())
            self.assertNotEqual("notes.txt", stored.name)
            self.assertEqual(
                [".hermes-nest-attachments"],
                [path.name for path in destination.iterdir()],
            )

            listed_response = await self.client.get(
                "/companion/v1/uploads",
                params={"session_id": "session-upload"},
                headers={"Authorization": f"Bearer {self.credential}"},
            )
            self.assertEqual(200, listed_response.status)
            listed = await listed_response.json()
            self.assertEqual([body["upload"]], listed["uploads"])
            self.assertNotIn(str(host_path), repr(listed))

            removed = await self.client.delete(
                f"/companion/v1/uploads/{body['upload']['id']}",
                headers={"Authorization": f"Bearer {self.credential}"},
            )
            self.assertEqual(204, removed.status)
            self.assertFalse(stored.exists())
            empty = await self.client.get(
                "/companion/v1/uploads",
                params={"session_id": "session-upload"},
                headers={"Authorization": f"Bearer {self.credential}"},
            )
            self.assertEqual([], (await empty.json())["uploads"])

    async def test_authorized_server_file_can_be_staged_for_a_turn(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "agent"
            source_directory = host_path / "reports"
            destination = host_path / "incoming"
            source_directory.mkdir(parents=True)
            destination.mkdir()
            (source_directory / "summary.txt").write_text(
                "server-side report",
                encoding="utf-8",
            )
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="agent",
                        name="Agent files",
                        path=host_path,
                        writable=True,
                    )
                ],
                agent_working_directory=host_path,
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            response = await self.client.post(
                "/companion/v1/uploads/from-file",
                json={
                    "source_root_id": "agent",
                    "source_path": "reports/summary.txt",
                    "destination_root_id": "agent",
                    "destination_directory": "incoming",
                    "session_id": "session-server-file",
                },
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(201, response.status)
            body = await response.json()
            self.assertEqual("summary.txt", body["upload"]["name"])
            self.assertEqual(18, body["upload"]["size"])
            self.assertEqual("ready", body["upload"]["state"])
            self.assertNotIn("path", body["upload"])
            device_id = self.registry.authenticate(self.credential).id
            record = self.registry.list_ready_attachments(
                device_id=device_id,
                session_id="session-server-file",
            )[0]
            staged = host_path / record.relative_path
            self.assertEqual(b"server-side report", staged.read_bytes())
            self.assertNotEqual("summary.txt", staged.name)

    async def test_server_file_staging_requires_an_authorized_regular_file(
        self,
    ) -> None:
        response = await self.client.post(
            "/companion/v1/uploads/from-file",
            json={
                "source_root_id": "missing",
                "source_path": "../secret.txt",
                "destination_root_id": "missing",
                "destination_directory": "",
                "session_id": "session-server-file",
            },
            headers={"Authorization": f"Bearer {self.credential}"},
        )

        self.assertEqual(404, response.status)
        self.assertEqual(
            "workspace_root_not_found",
            (await response.json())["error"]["code"],
        )

    async def test_server_file_staging_accepts_50_mib_and_rejects_one_more_byte(
        self,
    ) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory)
            exact = host_path / "exact.bin"
            with exact.open("wb") as handle:
                handle.truncate(50 * 1024 * 1024)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="agent",
                        name="Agent files",
                        path=host_path,
                        writable=True,
                    )
                ],
                agent_working_directory=host_path,
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()

            exact_response = await self.client.post(
                "/companion/v1/uploads/from-file",
                json={
                    "source_root_id": "agent",
                    "source_path": "exact.bin",
                    "destination_root_id": "agent",
                    "destination_directory": "",
                    "session_id": "session-server-file",
                },
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(201, exact_response.status)
            self.assertEqual(
                50 * 1024 * 1024,
                (await exact_response.json())["upload"]["size"],
            )
            oversized = host_path / "oversized.bin"
            with oversized.open("wb") as handle:
                handle.truncate(50 * 1024 * 1024 + 1)
            response = await self.client.post(
                "/companion/v1/uploads/from-file",
                json={
                    "source_root_id": "agent",
                    "source_path": "oversized.bin",
                    "destination_root_id": "agent",
                    "destination_directory": "",
                    "session_id": "session-server-file-overflow",
                },
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(413, response.status)
            self.assertEqual(
                "upload_too_large",
                (await response.json())["error"]["code"],
            )
            self.assertEqual(
                [],
                self.registry.list_ready_attachments(
                    device_id=self.registry.authenticate(self.credential).id,
                    session_id="session-server-file-overflow",
                ),
            )

    async def test_upload_content_type_is_derived_from_filename_not_client_header(
        self,
    ) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()
            form = FormData()
            form.add_field(
                "metadata",
                json.dumps(
                    {
                        "root_id": "projects",
                        "directory": "",
                        "session_id": "session-mime",
                    }
                ),
                content_type="application/json",
            )
            form.add_field(
                "file",
                b"plain text",
                filename="notes.txt",
                content_type="image/png",
            )

            response = await self.client.post(
                "/companion/v1/uploads",
                data=form,
                headers={"Authorization": f"Bearer {self.credential}"},
            )

            self.assertEqual(201, response.status)
            self.assertEqual(
                "text/plain",
                (await response.json())["upload"]["content_type"],
            )

    async def test_pending_attachment_removal_recovers_when_file_is_already_missing(
        self,
    ) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()
            headers = {"Authorization": f"Bearer {self.credential}"}
            form = FormData()
            form.add_field(
                "metadata",
                json.dumps(
                    {
                        "root_id": "projects",
                        "directory": "",
                        "session_id": "session-missing",
                    }
                ),
                content_type="application/json",
            )
            form.add_field(
                "file",
                b"temporary",
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
                self.credential
            ).id
            record = self.registry.ready_attachment_for_device(
                device_id=device_id,
                attachment_id=upload_id,
            )
            (host_path / record.relative_path).unlink()

            removed = await self.client.delete(
                f"/companion/v1/uploads/{upload_id}",
                headers=headers,
            )

            self.assertEqual(204, removed.status)
            pending = await self.client.get(
                "/companion/v1/uploads",
                params={"session_id": "session-missing"},
                headers=headers,
            )
            self.assertEqual([], (await pending.json())["uploads"])

    async def test_upload_never_overwrites_a_file_created_during_publication(
        self,
    ) -> None:
        with TemporaryDirectory() as directory:
            root_path = Path(directory)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=root_path,
                        writable=True,
                    )
                ]
            )
            upload = workspace.begin_upload(
                "projects",
                "",
                "notes.txt",
            )
            try:
                upload.write(b"uploaded")
                stored = root_path / upload.relative_path
                stored.write_bytes(b"existing")

                with self.assertRaisesRegex(
                    WorkspaceError,
                    "already exists",
                ):
                    upload.commit()
            finally:
                upload.abort()

            self.assertEqual(
                b"existing",
                stored.read_bytes(),
            )
            self.assertEqual(
                [stored.name],
                [path.name for path in stored.parent.iterdir()],
            )

    async def test_interrupted_upload_removes_partial_file_and_temp_entry(
        self,
    ) -> None:
        with TemporaryDirectory() as directory:
            root_path = Path(directory)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=root_path,
                        writable=True,
                    )
                ]
            )
            upload = workspace.begin_upload(
                "projects",
                "",
                "notes.txt",
            )

            upload.write(b"partial bytes")
            upload.abort()

            staging = root_path / ".hermes-nest-attachments"
            self.assertTrue(staging.is_dir())
            self.assertEqual([], list(staging.iterdir()))

    async def test_cancelled_upload_handler_cleans_partial_file_and_reservation(
        self,
    ) -> None:
        with TemporaryDirectory() as directory:
            host_path = Path(directory)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            blocked = asyncio.Event()
            reader = FakeMultipartReader(
                [
                    FakeMultipartPart(
                        name="metadata",
                        chunks=[
                            json.dumps(
                                {
                                    "root_id": "projects",
                                    "directory": "",
                                    "session_id": "session-cancelled",
                                }
                            ).encode("utf-8")
                        ],
                    ),
                    FakeMultipartPart(
                        name="file",
                        filename="cancelled.bin",
                        chunks=[b"partial bytes"],
                        block_after_chunks=blocked,
                    ),
                ]
            )
            request = FakeUploadRequest(
                registry=self.registry,
                workspace=workspace,
                credential=self.credential,
                reader=reader,
            )
            task = asyncio.create_task(_upload_file(request))
            await asyncio.wait_for(blocked.wait(), timeout=5)

            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task

            staging = host_path / ".hermes-nest-attachments"
            self.assertTrue(staging.is_dir())
            self.assertEqual([], list(staging.iterdir()))
            replacement_ids = [
                self.registry.reserve_attachment(
                    device_id=self.registry.authenticate(
                        self.credential
                    ).id,
                    session_id="session-cancelled",
                    root_id="projects",
                    relative_path=f"replacement-{index}.bin",
                    name=f"replacement-{index}.bin",
                    content_type="application/octet-stream",
                )
                for index in range(10)
            ]
            self.assertEqual(10, len(replacement_ids))

    async def test_pending_attachment_queue_is_limited_to_ten_files_per_session(
        self,
    ) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "owner-projects"
            host_path.mkdir()
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()
            headers = {"Authorization": f"Bearer {self.credential}"}

            statuses = []
            for index in range(11):
                form = FormData()
                form.add_field(
                    "metadata",
                    json.dumps(
                        {
                            "root_id": "projects",
                            "directory": "",
                            "session_id": "session-bounded",
                        }
                    ),
                    content_type="application/json",
                )
                form.add_field(
                    "file",
                    b"x",
                    filename=f"attachment-{index}.txt",
                    content_type="text/plain",
                )
                response = await self.client.post(
                    "/companion/v1/uploads",
                    data=form,
                    headers=headers,
                )
                statuses.append(response.status)
                if index == 10:
                    self.assertEqual(409, response.status)
                    self.assertEqual(
                        "attachment_count_exceeded",
                        (await response.json())["error"]["code"],
                    )

            self.assertEqual([201] * 10 + [409], statuses)

    def test_interrupted_run_claim_fails_closed_when_registry_reopens(self) -> None:
        with TemporaryDirectory() as directory:
            database = Path(directory) / "registry.sqlite3"
            registry = DeviceRegistry(database)
            secret = registry.create_pairing_secret(300)
            device = registry.claim_pairing_secret(
                secret,
                "Restart Test Device",
            )
            attachment_id = registry.reserve_attachment(
                device_id=device.id,
                session_id="session-restart",
                root_id="projects",
                relative_path="staged.bin",
                name="staged.bin",
                content_type="application/octet-stream",
            )
            registry.complete_attachment(attachment_id)
            claim, _ = registry.claim_ready_attachments(
                device_id=device.id,
                session_id="session-restart",
                attachment_ids=[attachment_id],
            )
            self.assertTrue(claim)
            self.assertEqual(
                [],
                registry.list_ready_attachments(
                    device_id=device.id,
                    session_id="session-restart",
                ),
            )
            registry.close()

            reopened = DeviceRegistry(database)
            try:
                self.assertEqual(
                    [],
                    reopened.list_ready_attachments(
                        device_id=device.id,
                        session_id="session-restart",
                    ),
                )
            finally:
                reopened.close()

    async def test_pending_attachment_bytes_are_limited_to_two_hundred_mib(
        self,
    ) -> None:
        registry = DeviceRegistry(":memory:")
        try:
            secret = registry.create_pairing_secret(300)
            device = registry.claim_pairing_secret(secret, "Quota Device")
            for index in range(4):
                attachment_id = registry.reserve_attachment(
                    device_id=device.id,
                    session_id="session-quota",
                    root_id="projects",
                    relative_path=f"file-{index}.bin",
                    name=f"file-{index}.bin",
                    content_type="application/octet-stream",
                )
                registry.add_attachment_bytes(
                    attachment_id,
                    50 * 1024 * 1024,
                )
                registry.complete_attachment(attachment_id)

            overflow_id = registry.reserve_attachment(
                device_id=device.id,
                session_id="session-quota",
                root_id="projects",
                relative_path="overflow.bin",
                name="overflow.bin",
                content_type="application/octet-stream",
            )
            with self.assertRaisesRegex(
                RegistryError,
                "200 MiB",
            ):
                registry.add_attachment_bytes(overflow_id, 1)
        finally:
            registry.close()

    async def test_pending_attachment_removal_refuses_replaced_file(self) -> None:
        await self.client.close()
        with TemporaryDirectory() as directory:
            self.registry = DeviceRegistry(":memory:")
            secret = self.registry.create_pairing_secret(300)
            self.credential = self.registry.claim_pairing_secret(
                secret,
                "Workspace Test Device",
            ).credential
            host_path = Path(directory) / "owner-projects"
            host_path.mkdir()
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=host_path,
                        writable=True,
                    )
                ]
            )
            self.client = TestClient(
                TestServer(create_app(self.registry, workspace=workspace))
            )
            await self.client.start_server()
            headers = {"Authorization": f"Bearer {self.credential}"}
            form = FormData()
            form.add_field(
                "metadata",
                json.dumps(
                    {
                        "root_id": "projects",
                        "directory": "",
                        "session_id": "session-replaced",
                    }
                ),
                content_type="application/json",
            )
            form.add_field(
                "file",
                b"original",
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
                self.credential
            ).id
            record = self.registry.ready_attachment_for_device(
                device_id=device_id,
                attachment_id=upload_id,
            )
            stored = host_path / record.relative_path
            replacement = host_path / "replacement.tmp"
            replacement.write_bytes(b"replacement")
            replacement.replace(stored)

            removed = await self.client.delete(
                f"/companion/v1/uploads/{upload_id}",
                headers=headers,
            )

            self.assertEqual(409, removed.status)
            self.assertEqual(
                "attachment_file_changed",
                (await removed.json())["error"]["code"],
            )
            self.assertEqual(b"replacement", stored.read_bytes())
            pending = await self.client.get(
                "/companion/v1/uploads",
                params={"session_id": "session-replaced"},
                headers=headers,
            )
            self.assertEqual(1, len((await pending.json())["uploads"]))

    def test_pending_attachment_removal_never_unlinks_a_racing_replacement(
        self,
    ) -> None:
        with TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = WorkspaceAccess(
                [
                    WorkspaceRoot(
                        id="projects",
                        name="Projects",
                        path=root,
                        writable=True,
                    )
                ]
            )
            upload = workspace.begin_upload("projects", "", "notes.txt")
            upload.write(b"original")
            upload.commit()
            stored = root / upload.relative_path
            moved_original = root / "original-safe"
            real_rename = os.rename

            def race_before_quarantine(
                source: str,
                destination: str,
                *,
                src_dir_fd: int,
                dst_dir_fd: int,
            ) -> None:
                os.replace(stored, moved_original)
                stored.write_bytes(b"replacement")
                real_rename(
                    source,
                    destination,
                    src_dir_fd=src_dir_fd,
                    dst_dir_fd=dst_dir_fd,
                )

            with patch(
                "hermex_companion.workspace.os.rename",
                side_effect=race_before_quarantine,
            ):
                with self.assertRaisesRegex(
                    WorkspaceError,
                    "changed during removal",
                ):
                    workspace.remove_uploaded_file(
                        "projects",
                        upload.relative_path,
                        expected_device=upload.published_device,
                        expected_inode=upload.published_inode,
                    )

            self.assertEqual(b"original", moved_original.read_bytes())
            quarantined = list(
                stored.parent.glob(".hermes-nest-delete-*")
            )
            self.assertEqual(1, len(quarantined))
            self.assertEqual(b"replacement", quarantined[0].read_bytes())
