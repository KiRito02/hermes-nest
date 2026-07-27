from __future__ import annotations

import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CHECKER = REPOSITORY_ROOT / "scripts" / "check-release-readiness"


class ReleaseReadinessCLITests(unittest.TestCase):
    def test_app_only_fixture_passes_the_public_release_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)

            result = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--project-root",
                    str(root),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("Release readiness: OK\n", result.stdout)

    def test_extension_target_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)
            project_path = root / "HermesMobile.xcodeproj" / "project.pbxproj"
            project_path.write_text(
                project_path.read_text(encoding="utf-8")
                + "\n"
                + 'productType = "com.apple.product-type.app-extension";\n',
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--project-root",
                    str(root),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn(
            "Xcode project contains removed marker: "
            "com.apple.product-type.app-extension",
            result.stderr,
        )

    def test_webui_runtime_source_is_rejected_from_the_app_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)
            project_path = root / "HermesMobile.xcodeproj" / "project.pbxproj"
            project_path.write_text(
                project_path.read_text(encoding="utf-8").replace(
                    "CCC000000000000000000001 "
                    "/* HermesMobileApp.swift in Sources */,",
                    "CCC000000000000000000001 "
                    "/* HermesMobileApp.swift in Sources */,\n"
                    "\t\t\t\tBBB000000000000000000001 "
                    "/* APIClient.swift in Sources */,",
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--project-root",
                    str(root),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn(
            "Xcode project contains WebUI runtime source: APIClient.swift",
            result.stderr,
        )

    def test_orphaned_build_file_is_not_mistaken_for_runtime_membership(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)
            project_path = root / "HermesMobile.xcodeproj" / "project.pbxproj"
            project_path.write_text(
                project_path.read_text(encoding="utf-8")
                + "\n"
                + "BBB000000000000000000001 "
                "/* APIClient.swift in Sources */ = {};\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--project-root",
                    str(root),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertEqual(0, result.returncode, result.stderr)

    def test_upstream_identity_in_any_tracked_config_is_rejected(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)
            (root / "Config" / "Legacy.xcconfig").write_text(
                "APP_BUNDLE_IDENTIFIER = "
                "com.uzairansar.hermesmobile.branch\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--project-root",
                    str(root),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn(
            "tracked config retains upstream bundle identity",
            result.stderr,
        )

    def test_removed_permission_surface_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)
            info_path = root / "HermesMobile" / "Resources" / "Info.plist"
            with info_path.open("rb") as info_file:
                info = plistlib.load(info_file)
            info["NSMicrophoneUsageDescription"] = "Legacy voice input"
            with info_path.open("wb") as info_file:
                plistlib.dump(info, info_file)

            result = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--project-root",
                    str(root),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn(
            "main App retains removed capability key: "
            "NSMicrophoneUsageDescription",
            result.stderr,
        )

    def test_tracked_export_team_identity_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)
            with (root / "Config" / "ExportOptions.plist").open(
                "wb"
            ) as export_options:
                plistlib.dump(
                    {
                        "method": "app-store-connect",
                        "teamID": "OLDTEAM123",
                    },
                    export_options,
                )

            result = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--project-root",
                    str(root),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn(
            "tracked export options retain an Apple Team ID",
            result.stderr,
        )

    def test_alternate_app_icon_catalog_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)
            alternate = (
                root
                / "HermesMobile"
                / "Resources"
                / "Assets.xcassets"
                / "AppIconLegacy.appiconset"
            )
            alternate.mkdir()
            (alternate / "Contents.json").write_text(
                json.dumps({"images": [], "info": {"version": 1}}),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--project-root",
                    str(root),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn(
            "asset catalog must contain only the primary AppIcon.appiconset",
            result.stderr,
        )

    @staticmethod
    def _write_app_only_fixture(root: Path) -> None:
        config = root / "Config"
        config.mkdir(parents=True)
        (config / "Shared.xcconfig").write_text(
            "\n".join(
                [
                    "DEVELOPMENT_TEAM =",
                    "APP_BUNDLE_IDENTIFIER = com.kirito02.hermesnest",
                    '#include? "Local.xcconfig"',
                    "",
                ]
            ),
            encoding="utf-8",
        )

        resources = root / "HermesMobile" / "Resources"
        resources.mkdir(parents=True)
        with (resources / "Info.plist").open("wb") as info_file:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                    "CFBundleDisplayName": "Hermes Nest",
                },
                info_file,
            )
        with (resources / "HermesMobile.entitlements").open("wb") as entitlements:
            plistlib.dump({}, entitlements)

        assets = resources / "Assets.xcassets"
        app_icon = assets / "AppIcon.appiconset"
        app_icon.mkdir(parents=True)
        icon_entries = []
        for appearance in ("light", "dark", "tinted"):
            filename = f"hermes_nest_{appearance}_icon.png"
            entry = {
                "filename": filename,
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }
            if appearance != "light":
                entry["appearances"] = [
                    {
                        "appearance": "luminosity",
                        "value": appearance,
                    }
                ]
            icon_entries.append(entry)
            (app_icon / filename).write_bytes(b"fixture")
        (app_icon / "Contents.json").write_text(
            json.dumps(
                {
                    "images": icon_entries,
                    "info": {"author": "xcode", "version": 1},
                }
            ),
            encoding="utf-8",
        )

        in_app_icon = assets / "HermesAppIcon.imageset"
        in_app_icon.mkdir()
        (in_app_icon / "hermes_nest_icon.png").write_bytes(b"fixture")
        (in_app_icon / "Contents.json").write_text(
            json.dumps(
                {
                    "images": [
                        {
                            "filename": "hermes_nest_icon.png",
                            "idiom": "universal",
                            "scale": "1x",
                        }
                    ],
                    "info": {"author": "xcode", "version": 1},
                }
            ),
            encoding="utf-8",
        )

        project = root / "HermesMobile.xcodeproj"
        project.mkdir(parents=True)
        (project / "project.pbxproj").write_text(
            "\n".join(
                [
                    "AAA000000000000000000001 /* HermesMobile */ = {",
                    "\tisa = PBXNativeTarget;",
                    "\tbuildPhases = (",
                    "\t\tBBB000000000000000000001 /* Sources */,",
                    "\t);",
                    "\tname = HermesMobile;",
                    "\tproductType = "
                    '"com.apple.product-type.application";',
                    "};",
                    "BBB000000000000000000001 /* Sources */ = {",
                    "\tisa = PBXSourcesBuildPhase;",
                    "\tfiles = (",
                    "\t\tCCC000000000000000000001 "
                    "/* HermesMobileApp.swift in Sources */,",
                    "\t);",
                    "};",
                    "AAA000000000000000000002 "
                    "/* HermesMobileTests */ = {",
                    "\tisa = PBXNativeTarget;",
                    "\tname = HermesMobileTests;",
                    "\tproductType = "
                    '"com.apple.product-type.bundle.unit-test";',
                    "};",
                    "PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER);",
                    "",
                ]
            ),
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()
