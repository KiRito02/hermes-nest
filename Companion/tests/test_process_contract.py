import asyncio
import os
from pathlib import Path
import socket
import sys
import unittest

from aiohttp import ClientSession


class ProcessContractTests(unittest.IsolatedAsyncioTestCase):
    async def test_module_entrypoint_serves_liveness(self) -> None:
        port = self._unused_loopback_port()
        companion_root = Path(__file__).resolve().parents[1]
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(companion_root / "src")

        process = await asyncio.create_subprocess_exec(
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
        try:
            body = await self._wait_for_liveness(port, process)
            self.assertEqual("ok", body["status"])
            self.assertNotIn("gateway", body)
        finally:
            if process.returncode is None:
                process.terminate()
            await process.wait()

    async def _wait_for_liveness(
        self, port: int, process: asyncio.subprocess.Process
    ) -> dict[str, object]:
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
                        self.assertEqual(200, response.status)
                        return await response.json()
                except OSError:
                    await asyncio.sleep(0.02)
        self.fail("Companion did not serve liveness within one second")

    @staticmethod
    def _unused_loopback_port() -> int:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            return int(listener.getsockname()[1])
