from __future__ import annotations

import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PACKAGER = REPOSITORY_ROOT / "scripts" / "package-sideload-app"


class SideloadPackageCLITests(unittest.TestCase):
    def test_packages_exactly_one_main_app_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            app = self._write_app(root)
            output = root / "HermesNest-unsigned.ipa"

            result = self._run(app, output)

            self.assertEqual(0, result.returncode, result.stderr)
            with zipfile.ZipFile(output) as archive:
                members = archive.namelist()
                self.assertIn("Payload/HermesNest.app/Info.plist", members)
                self.assertIn("Payload/HermesNest.app/HermesNest", members)
                self.assertFalse(
                    any(
                        name.endswith(".appex/")
                        or "/PlugIns/" in name
                        for name in members
                    )
                )
            self.assertEqual(0o600, output.stat().st_mode & 0o777)

    def test_rejects_an_embedded_extension(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            app = self._write_app(root)
            extension = app / "PlugIns" / "Legacy.appex"
            extension.mkdir(parents=True)

            result = self._run(
                app,
                root / "HermesNest-unsigned.ipa",
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("removed nested product", result.stderr)

    def test_rejects_the_wrong_bundle_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            app = self._write_app(
                root,
                bundle_id="com.example.not-hermes-nest",
            )

            result = self._run(
                app,
                root / "HermesNest-unsigned.ipa",
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("app bundle ID must be", result.stderr)

    @staticmethod
    def _write_app(
        root: Path,
        bundle_id: str = "com.kirito02.hermesnest",
    ) -> Path:
        app = root / "Build" / "HermesMobile.app"
        app.mkdir(parents=True)
        with (app / "Info.plist").open("wb") as info_file:
            plistlib.dump(
                {
                    "CFBundleIdentifier": bundle_id,
                    "CFBundleExecutable": "HermesNest",
                },
                info_file,
            )
        executable = app / "HermesNest"
        executable.write_bytes(b"unsigned-device-binary")
        executable.chmod(0o755)
        return app

    @staticmethod
    def _run(app: Path, output: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(PACKAGER),
                "--app",
                str(app),
                "--output",
                str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
