import asyncio
import os
from pathlib import Path
import socket
import sys
from tempfile import TemporaryDirectory
import unittest
from uuid import UUID

from aiohttp import ClientSession
from aiohttp.test_utils import TestClient, TestServer

from hermex_companion.app import create_app
from hermex_companion.registry import DeviceRegistry


class PairingContractTests(unittest.IsolatedAsyncioTestCase):
    async def test_device_list_has_a_fixed_upper_bound(self) -> None:
        registry = DeviceRegistry(":memory:")
        credential = ""
        for index in range(257):
            secret = registry.create_pairing_secret(300)
            credential = registry.claim_pairing_secret(
                secret,
                f"Bounded Device {index}",
            ).credential

        client = TestClient(TestServer(create_app(registry)))
        await client.start_server()
        try:
            response = await client.get(
                "/companion/v1/devices",
                headers={"Authorization": f"Bearer {credential}"},
            )
            self.assertEqual(200, response.status)
            body = await response.json()
            self.assertEqual(256, len(body["devices"]))
        finally:
            await client.close()

    async def test_pairing_secret_is_claimed_once_for_device_credential(self) -> None:
        with TemporaryDirectory() as state_home:
            environment = self._environment(state_home)
            secret = await self._create_pairing_secret(environment)
            port = self._unused_loopback_port()
            process = await self._start_companion(port, environment)
            try:
                await self._wait_until_live(port, process)
                url = f"http://127.0.0.1:{port}/companion/v1/pairings/claim"
                async with ClientSession() as session:
                    async with session.post(
                        url,
                        json={"secret": secret, "device_name": "Owner iPad"},
                    ) as response:
                        self.assertEqual(201, response.status)
                        self.assertEqual("no-store", response.headers["Cache-Control"])
                        claimed = await response.json()

                    self.assertEqual("Owner iPad", claimed["device"]["name"])
                    UUID(claimed["device"]["id"])
                    self.assertEqual("Bearer", claimed["credential_type"])
                    self.assertGreaterEqual(len(claimed["credential"]), 32)
                    self.assertNotIn("API_SERVER_KEY", repr(claimed))

                    async with session.post(
                        url,
                        json={"secret": secret, "device_name": "Replay"},
                    ) as response:
                        self.assertEqual(409, response.status)
                        self.assertEqual(
                            {
                                "error": {
                                    "code": "pairing_secret_used",
                                    "message": "Pairing secret has already been used.",
                                }
                            },
                            await response.json(),
                        )
            finally:
                if process.returncode is None:
                    process.terminate()
                await process.wait()

    async def test_device_can_list_then_revoke_itself(self) -> None:
        with TemporaryDirectory() as state_home:
            environment = self._environment(state_home)
            secret = await self._create_pairing_secret(environment)
            port = self._unused_loopback_port()
            process = await self._start_companion(port, environment)
            try:
                await self._wait_until_live(port, process)
                base_url = f"http://127.0.0.1:{port}/companion/v1"
                async with ClientSession() as session:
                    async with session.post(
                        f"{base_url}/pairings/claim",
                        json={"secret": secret, "device_name": "Owner iPad"},
                    ) as response:
                        self.assertEqual(201, response.status)
                        claimed = await response.json()

                    credential = claimed["credential"]
                    device_id = claimed["device"]["id"]
                    headers = {"Authorization": f"Bearer {credential}"}

                    async with session.get(
                        f"{base_url}/devices", headers=headers
                    ) as response:
                        self.assertEqual(200, response.status)
                        listed = await response.json()

                    self.assertEqual(1, len(listed["devices"]))
                    device = listed["devices"][0]
                    self.assertEqual(device_id, device["id"])
                    self.assertEqual("Owner iPad", device["name"])
                    self.assertFalse(device["revoked"])
                    self.assertTrue(device["created_at"].endswith("Z"))
                    self.assertTrue(device["last_seen_at"].endswith("Z"))
                    self.assertNotIn("credential", repr(listed).lower())

                    async with session.delete(
                        f"{base_url}/devices/{device_id}", headers=headers
                    ) as response:
                        self.assertEqual(204, response.status)
                        self.assertEqual("no-store", response.headers["Cache-Control"])
                        self.assertEqual(b"", await response.read())

                    async with session.get(
                        f"{base_url}/devices", headers=headers
                    ) as response:
                        self.assertEqual(403, response.status)
                        self.assertEqual(
                            {
                                "error": {
                                    "code": "device_revoked",
                                    "message": "Device credential has been revoked.",
                                }
                            },
                            await response.json(),
                        )
            finally:
                if process.returncode is None:
                    process.terminate()
                await process.wait()

    async def test_expired_pairing_secret_is_rejected_without_echoing_it(self) -> None:
        with TemporaryDirectory() as state_home:
            environment = self._environment(state_home)
            secret = await self._create_pairing_secret(environment, expires_in=1)
            await asyncio.sleep(1.05)
            port = self._unused_loopback_port()
            process = await self._start_companion(port, environment)
            try:
                await self._wait_until_live(port, process)
                url = f"http://127.0.0.1:{port}/companion/v1/pairings/claim"
                async with ClientSession() as session:
                    async with session.post(
                        url,
                        json={"secret": secret, "device_name": "Expired"},
                    ) as response:
                        self.assertEqual(410, response.status)
                        body = await response.json()
                self.assertEqual(
                    {
                        "error": {
                            "code": "pairing_secret_expired",
                            "message": "Pairing secret has expired.",
                        }
                    },
                    body,
                )
                self.assertNotIn(secret, repr(body))
            finally:
                if process.returncode is None:
                    process.terminate()
                await process.wait()

    async def _create_pairing_secret(
        self, environment: dict[str, str], *, expires_in: int = 300
    ) -> str:
        process = await asyncio.create_subprocess_exec(
            sys.executable,
            "-m",
            "hermex_companion",
            "pairing",
            "create",
            "--expires-in",
            str(expires_in),
            env=environment,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await process.communicate()
        self.assertEqual(0, process.returncode, stderr.decode("utf-8", errors="replace"))
        secret = stdout.decode("utf-8").strip()
        self.assertNotIn("\n", secret)
        self.assertGreaterEqual(len(secret), 32)
        return secret

    async def _start_companion(
        self, port: int, environment: dict[str, str]
    ) -> asyncio.subprocess.Process:
        return await asyncio.create_subprocess_exec(
            sys.executable,
            "-m",
            "hermex_companion",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            env=environment,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )

    async def _wait_until_live(
        self, port: int, process: asyncio.subprocess.Process
    ) -> None:
        url = f"http://127.0.0.1:{port}/companion/v1/health"
        async with ClientSession() as session:
            for _ in range(50):
                if process.returncode is not None:
                    stderr = await process.stderr.read()
                    self.fail(
                        "Companion exited before liveness: "
                        + stderr.decode("utf-8", errors="replace")
                    )
                try:
                    async with session.get(url) as response:
                        if response.status == 200:
                            return
                except OSError:
                    await asyncio.sleep(0.02)
        self.fail("Companion did not serve liveness within one second")

    @staticmethod
    def _environment(state_home: str) -> dict[str, str]:
        companion_root = Path(__file__).resolve().parents[1]
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(companion_root / "src")
        environment["XDG_STATE_HOME"] = state_home
        return environment

    @staticmethod
    def _unused_loopback_port() -> int:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            return int(listener.getsockname()[1])
