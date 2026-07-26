import unittest

from aiohttp.test_utils import TestClient, TestServer

from hermex_companion.app import create_app


class HealthContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.client = TestClient(TestServer(create_app()))
        await self.client.start_server()

    async def asyncTearDown(self) -> None:
        await self.client.close()

    async def test_liveness_is_bounded_versioned_and_unauthenticated(self) -> None:
        response = await self.client.get("/companion/v1/health")

        self.assertEqual(200, response.status)
        self.assertEqual("application/json", response.content_type)
        self.assertEqual("no-store", response.headers["Cache-Control"])

        body = await response.json()
        self.assertEqual(
            {
                "status": "ok",
                "service": "hermex-companion",
                "companion_version": "0.1.0",
                "contract_version": "1",
            },
            body,
        )
        self.assertLessEqual(len(await response.read()), 512)

    async def test_framework_errors_are_never_cacheable(self) -> None:
        for response in (
            await self.client.get("/companion/v1/unknown"),
            await self.client.post("/companion/v1/health"),
            await self.client.post(
                "/companion/v1/pairings/claim",
                data=b"x" * (17 * 1024),
                headers={"Content-Type": "application/json"},
            ),
        ):
            with self.subTest(status=response.status):
                self.assertIn(response.status, {404, 405, 413})
                self.assertEqual("no-store", response.headers["Cache-Control"])
                await response.read()
