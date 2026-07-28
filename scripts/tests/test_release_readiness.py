from __future__ import annotations

import json
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
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

    def test_unreviewed_runtime_source_is_rejected_by_allowlist(self) -> None:
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
                    "\t\tDDD000000000000000000001 "
                    "/* FutureSurface.swift in Sources */,",
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
            "personal App target contains sources outside its allowlist: "
            "FutureSurface.swift",
            result.stderr,
        )

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

    def test_personal_scheme_cannot_archive_the_release_configuration(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)
            scheme = (
                root
                / "HermesMobile.xcodeproj"
                / "xcshareddata"
                / "xcschemes"
                / "HermesNestPersonalSideload.xcscheme"
            )
            scheme.write_text(
                scheme.read_text(encoding="utf-8").replace(
                    '<ArchiveAction buildConfiguration="PersonalSideload" />',
                    '<ArchiveAction buildConfiguration="Release" />',
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
            "ArchiveAction must use PersonalSideload",
            result.stderr,
        )

    def test_duplicate_icon_appearance_artwork_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)
            icons = (
                root
                / "HermesMobile"
                / "Resources"
                / "Assets.xcassets"
                / "AppIcon.appiconset"
            )
            light = icons / "hermes_nest_light_icon.png"
            (icons / "hermes_nest_dark_icon.png").write_bytes(
                light.read_bytes()
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
            "App icon appearance variants must contain distinct artwork",
            result.stderr,
        )

    def test_misaligned_icon_appearance_artwork_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self._write_app_only_fixture(root)
            icons = (
                root
                / "HermesMobile"
                / "Resources"
                / "Assets.xcassets"
                / "AppIcon.appiconset"
            )
            self._write_test_png(
                icons / "hermes_nest_light_icon.png",
                background=(252, 245, 237),
                subject=(0, 180, 200),
                subject_box=(8, 7, 24, 25),
            )
            self._write_test_png(
                icons / "hermes_nest_dark_icon.png",
                background=(13, 19, 26),
                subject=(0, 180, 200),
                subject_box=(2, 2, 12, 12),
            )
            self._write_test_png(
                icons / "hermes_nest_tinted_icon.png",
                background=(251, 251, 251),
                subject=(80, 80, 80),
                subject_box=(8, 7, 24, 25),
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
            "App icon appearance variants must share centered subject geometry",
            result.stderr,
        )

    @staticmethod
    def _write_test_png(
        path: Path,
        *,
        background: tuple[int, int, int],
        subject: tuple[int, int, int],
        subject_box: tuple[int, int, int, int],
    ) -> None:
        width = 32
        height = 32
        left, top, right, bottom = subject_box
        rows = []
        for y in range(height):
            row = bytearray()
            for x in range(width):
                color = (
                    subject
                    if left <= x < right and top <= y < bottom
                    else background
                )
                row.extend(color)
            rows.append(b"\x00" + bytes(row))

        def chunk(kind: bytes, payload: bytes) -> bytes:
            checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
            return (
                struct.pack(">I", len(payload))
                + kind
                + payload
                + struct.pack(">I", checksum)
            )

        path.write_bytes(
            b"\x89PNG\r\n\x1a\n"
            + chunk(
                b"IHDR",
                struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0),
            )
            + chunk(b"IDAT", zlib.compress(b"".join(rows)))
            + chunk(b"IEND", b"")
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
        (config / "PersonalSideloadSources.txt").write_text(
            "HermesMobileApp.swift\n",
            encoding="utf-8",
        )
        (config / "PersonalSideload.xcconfig").write_text(
            '#include "Shared.xcconfig"\n',
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
            (app_icon / filename).write_bytes(
                f"fixture-{appearance}".encode("utf-8")
            )
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
                    "baseConfigurationReference = "
                    "PersonalSideload.xcconfig */;",
                    "name = PersonalSideload;",
                    "name = PersonalSideload;",
                    "name = PersonalSideload;",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        schemes = project / "xcshareddata" / "xcschemes"
        schemes.mkdir(parents=True)
        (
            schemes / "HermesNestPersonalSideload.xcscheme"
        ).write_text(
            """<?xml version="1.0" encoding="UTF-8"?>
<Scheme>
  <BuildAction>
    <BuildActionEntries>
      <BuildActionEntry>
        <BuildableReference
          BuildableName="HermesMobile.app"
          BlueprintName="HermesMobile" />
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="PersonalSideload" />
  <ProfileAction buildConfiguration="PersonalSideload" />
  <AnalyzeAction buildConfiguration="PersonalSideload" />
  <ArchiveAction buildConfiguration="PersonalSideload" />
</Scheme>
""",
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()
