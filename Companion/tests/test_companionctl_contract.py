from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from pathlib import Path


COMPANION_ROOT = Path(__file__).resolve().parents[1]
COMPANIONCTL = COMPANION_ROOT / "deploy" / "companionctl.py"


class _HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        if self.path != "/companion/v1/health":
            self.send_error(404)
            return
        body = json.dumps(
            {
                "status": "ok",
                "service": "hermex-companion",
                "companion_version": "0.1.0",
                "contract_version": "1",
            }
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *arguments: object) -> None:
        pass


class CompanionControlContractTests(unittest.TestCase):
    def test_backup_captures_committed_wal_state_from_a_live_database(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            config_home = root / "config"
            state_home = root / "state"
            data_home = root / "data"
            config_directory = config_home / "hermex-companion"
            state_directory = state_home / "hermex-companion"
            agent_directory = root / "agent"
            config_directory.mkdir(parents=True)
            state_directory.mkdir(parents=True)
            agent_directory.mkdir()
            (config_directory / "workspaces.json").write_text(
                json.dumps(
                    {
                        "agent_working_directory": str(agent_directory),
                        "roots": [],
                    }
                ),
                encoding="utf-8",
            )

            database = state_directory / "companion.sqlite3"
            live_connection = sqlite3.connect(database)
            live_connection.execute("PRAGMA journal_mode = WAL")
            live_connection.execute("PRAGMA wal_autocheckpoint = 0")
            live_connection.execute(
                "CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL)"
            )
            live_connection.execute(
                "INSERT INTO devices (id, name) VALUES (?, ?)",
                ("device-1", "Owner iPhone"),
            )
            live_connection.commit()
            live_connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            live_connection.execute(
                "INSERT INTO devices (id, name) VALUES (?, ?)",
                ("device-2", "Owner iPad"),
            )
            live_connection.commit()
            backup = root / "live-backup.tar.gz"
            try:
                result = self._run(
                    config_home,
                    state_home,
                    data_home,
                    "backup",
                    "--output",
                    str(backup),
                )
            finally:
                live_connection.close()

            self.assertEqual(0, result.returncode, result.stderr)
            with tarfile.open(backup, "r:gz") as archive:
                database_member = archive.extractfile(
                    "state/companion.sqlite3"
                )
                self.assertIsNotNone(database_member)
                restored_database = root / "restored.sqlite3"
                restored_database.write_bytes(database_member.read())
            with sqlite3.connect(restored_database) as restored:
                rows = restored.execute(
                    "SELECT id, name FROM devices ORDER BY id"
                ).fetchall()
            self.assertEqual(
                [
                    ("device-1", "Owner iPhone"),
                    ("device-2", "Owner iPad"),
                ],
                rows,
            )

    def test_backup_preserves_non_secret_state_and_excludes_gateway_key(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            config_home = root / "config"
            state_home = root / "state"
            data_home = root / "data"
            config_directory = config_home / "hermex-companion"
            state_directory = state_home / "hermex-companion"
            config_directory.mkdir(parents=True)
            state_directory.mkdir(parents=True)

            workspace_config = {
                "agent_working_directory": str(root / "agent"),
                "roots": [],
            }
            (config_directory / "workspaces.json").write_text(
                json.dumps(workspace_config),
                encoding="utf-8",
            )
            (config_directory / "hermex-companion.env").write_text(
                "HERMEX_COMPANION_GATEWAY_KEY=must-not-be-backed-up\n",
                encoding="utf-8",
            )
            database = state_directory / "companion.sqlite3"
            with sqlite3.connect(database) as connection:
                connection.execute(
                    "CREATE TABLE devices (id TEXT PRIMARY KEY)"
                )
                connection.execute(
                    "INSERT INTO devices (id) VALUES (?)",
                    ("device-1",),
                )
            output = root / "companion-backup.tar.gz"

            result = self._run(
                config_home,
                state_home,
                data_home,
                "backup",
                "--output",
                str(output),
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(0o600, output.stat().st_mode & 0o777)
            with tarfile.open(output, "r:gz") as archive:
                names = set(archive.getnames())
                self.assertEqual(
                    {
                        "manifest.json",
                        "config/workspaces.json",
                        "state/companion.sqlite3",
                    },
                    names,
                )
                self.assertNotIn("config/hermex-companion.env", names)
                manifest_member = archive.extractfile("manifest.json")
                database_member = archive.extractfile(
                    "state/companion.sqlite3"
                )
                self.assertIsNotNone(manifest_member)
                self.assertIsNotNone(database_member)
                manifest = json.load(manifest_member)
                self.assertEqual(1, manifest["backup_version"])
                extracted_database = root / "extracted.sqlite3"
                extracted_database.write_bytes(database_member.read())
                with sqlite3.connect(extracted_database) as connection:
                    row = connection.execute(
                        "SELECT id FROM devices"
                    ).fetchone()
                self.assertEqual(("device-1",), row)

    def test_backup_rejects_symbolic_linked_state_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            config_home = root / "config"
            state_home = root / "state"
            data_home = root / "data"
            config_directory = config_home / "hermex-companion"
            state_directory = state_home / "hermex-companion"
            config_directory.mkdir(parents=True)
            state_directory.mkdir(parents=True)
            agent_directory = root / "agent"
            agent_directory.mkdir()
            external_config = root / "external-workspaces.json"
            external_config.write_text(
                json.dumps(
                    {
                        "agent_working_directory": str(agent_directory),
                        "roots": [],
                    }
                ),
                encoding="utf-8",
            )
            (config_directory / "workspaces.json").symlink_to(external_config)
            (state_directory / "companion.sqlite3").write_bytes(b"state")
            output = root / "must-not-exist.tar.gz"

            result = self._run(
                config_home,
                state_home,
                data_home,
                "backup",
                "--output",
                str(output),
            )

            self.assertNotEqual(0, result.returncode)
            self.assertIn(
                "backup source must be a regular non-symbolic file",
                result.stderr,
            )
            self.assertFalse(output.exists())

    def test_restore_round_trip_preserves_gateway_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_config_home = root / "source-config"
            source_state_home = root / "source-state"
            source_data_home = root / "source-data"
            source_config = source_config_home / "hermex-companion"
            source_state = source_state_home / "hermex-companion"
            source_config.mkdir(parents=True)
            source_state.mkdir(parents=True)
            agent_directory = root / "agent"
            agent_directory.mkdir()
            workspace_payload = {
                "agent_working_directory": str(agent_directory),
                "roots": [],
            }
            (source_config / "workspaces.json").write_text(
                json.dumps(workspace_payload),
                encoding="utf-8",
            )
            source_database = source_state / "companion.sqlite3"
            with sqlite3.connect(source_database) as connection:
                connection.execute(
                    "CREATE TABLE devices (id TEXT PRIMARY KEY)"
                )
                connection.execute(
                    "INSERT INTO devices (id) VALUES (?)",
                    ("preserved-device",),
                )
            backup = root / "migration.tar.gz"
            backup_result = self._run(
                source_config_home,
                source_state_home,
                source_data_home,
                "backup",
                "--output",
                str(backup),
            )
            self.assertEqual(0, backup_result.returncode, backup_result.stderr)

            target_config_home = root / "target-config"
            target_state_home = root / "target-state"
            target_data_home = root / "target-data"
            target_config = target_config_home / "hermex-companion"
            target_config.mkdir(parents=True)
            gateway_environment = (
                "HERMEX_COMPANION_GATEWAY_KEY=target-host-secret\n"
            )
            environment_path = target_config / "hermex-companion.env"
            environment_path.write_text(
                gateway_environment,
                encoding="utf-8",
            )

            restore_result = self._run(
                target_config_home,
                target_state_home,
                target_data_home,
                "restore",
                "--input",
                str(backup),
            )

            self.assertEqual(0, restore_result.returncode, restore_result.stderr)
            restored_workspace = target_config / "workspaces.json"
            restored_database = (
                target_state_home
                / "hermex-companion"
                / "companion.sqlite3"
            )
            self.assertEqual(
                workspace_payload,
                json.loads(restored_workspace.read_text(encoding="utf-8")),
            )
            with sqlite3.connect(restored_database) as connection:
                restored_row = connection.execute(
                    "SELECT id FROM devices"
                ).fetchone()
            self.assertEqual(("preserved-device",), restored_row)
            self.assertEqual(
                gateway_environment,
                environment_path.read_text(encoding="utf-8"),
            )
            self.assertEqual(0o600, restored_workspace.stat().st_mode & 0o777)
            self.assertEqual(0o600, restored_database.stat().st_mode & 0o777)

    def test_install_stages_immutable_release_and_enables_system_service(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            config_home = root / "config"
            state_home = root / "state"
            data_home = root / "data"
            agent_directory = root / "agent"
            writable_root = agent_directory / "workspace"
            writable_root.mkdir(parents=True)
            config_directory = config_home / "hermex-companion"
            state_directory = state_home / "hermex-companion"
            config_directory.mkdir(parents=True)
            state_directory.mkdir(parents=True)
            (config_directory / "workspaces.json").write_text(
                json.dumps(
                    {
                        "agent_working_directory": str(agent_directory),
                        "roots": [
                            {
                                "id": "hermes-workspace",
                                "name": "Hermes Workspace",
                                "path": str(writable_root),
                                "writable": True,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            environment_bytes = b"HERMEX_COMPANION_GATEWAY_KEY=host-only\n"
            (config_directory / "hermex-companion.env").write_bytes(
                environment_bytes
            )
            state_bytes = b"existing-device-registry"
            (state_directory / "companion.sqlite3").write_bytes(state_bytes)

            command_log = root / "commands.log"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            for command in ("uv", "sudo"):
                executable = fake_bin / command
                executable.write_text(
                    "#!/bin/sh\n"
                    'printf "%s %s\\n" "$0" "$*" >> '
                    '"$COMPANIONCTL_COMMAND_LOG"\n',
                    encoding="utf-8",
                )
                executable.chmod(0o755)
            systemctl = fake_bin / "systemctl"
            systemctl.write_text(
                "#!/bin/sh\n"
                'case "$1" in\n'
                '  is-active) printf "active\\n" ;;\n'
                '  is-enabled) printf "enabled\\n" ;;\n'
                "  *) exit 2 ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            systemctl.chmod(0o755)

            result = self._run(
                config_home,
                state_home,
                data_home,
                "install",
                "--source-root",
                str(COMPANION_ROOT.parent),
                "--release-id",
                "release-a",
                "--service-user",
                "test-user",
                "--service-group",
                "test-group",
                environment={
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "COMPANIONCTL_COMMAND_LOG": str(command_log),
                },
            )

            self.assertEqual(0, result.returncode, result.stderr)
            release = (
                data_home
                / "hermex-companion"
                / "releases"
                / "release-a"
            )
            current = data_home / "hermex-companion" / "current"
            self.assertTrue((release / "Companion" / "pyproject.toml").is_file())
            self.assertTrue(current.is_symlink())
            self.assertEqual(release, current.resolve())
            self.assertEqual(
                environment_bytes,
                (config_directory / "hermex-companion.env").read_bytes(),
            )
            self.assertEqual(
                state_bytes,
                (state_directory / "companion.sqlite3").read_bytes(),
            )
            deployment_config = config_directory / "deployment.json"
            self.assertEqual(
                {
                    "service_user": "test-user",
                    "service_group": "test-group",
                },
                json.loads(deployment_config.read_text(encoding="utf-8")),
            )
            self.assertEqual(
                0o600,
                deployment_config.stat().st_mode & 0o777,
            )
            rendered_unit = (
                data_home / "hermex-companion" / "hermex-companion.service"
            )
            self.assertTrue(rendered_unit.is_file())
            unit = rendered_unit.read_text(encoding="utf-8")
            self.assertIn("User=test-user", unit)
            self.assertIn("Group=test-group", unit)
            commands = command_log.read_text(encoding="utf-8")
            self.assertIn("uv sync --frozen --project", commands)
            self.assertIn(
                "sudo install -m 0644 "
                f"{rendered_unit} "
                "/etc/systemd/system/hermex-companion.service",
                commands,
            )
            self.assertIn("sudo systemctl daemon-reload", commands)
            self.assertIn(
                "sudo systemctl enable --now hermex-companion.service",
                commands,
            )

            command_log.write_text("", encoding="utf-8")
            upgrade = self._run(
                config_home,
                state_home,
                data_home,
                "upgrade",
                "--source-root",
                str(COMPANION_ROOT.parent),
                "--release-id",
                "release-b",
                environment={
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "COMPANIONCTL_COMMAND_LOG": str(command_log),
                },
            )
            self.assertEqual(0, upgrade.returncode, upgrade.stderr)
            release_b = (
                data_home
                / "hermex-companion"
                / "releases"
                / "release-b"
            )
            previous = data_home / "hermex-companion" / "previous"
            self.assertEqual(release_b, current.resolve())
            self.assertEqual(release, previous.resolve())
            self.assertEqual(
                state_bytes,
                (state_directory / "companion.sqlite3").read_bytes(),
            )
            upgrade_commands = command_log.read_text(encoding="utf-8")
            self.assertIn(
                "sudo systemctl restart hermex-companion.service",
                upgrade_commands,
            )
            self.assertNotIn("enable --now", upgrade_commands)
            upgraded_unit = rendered_unit.read_text(encoding="utf-8")
            self.assertIn("User=test-user", upgraded_unit)
            self.assertIn("Group=test-group", upgraded_unit)

            command_log.write_text("", encoding="utf-8")
            rollback = self._run(
                config_home,
                state_home,
                data_home,
                "rollback",
                environment={
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "COMPANIONCTL_COMMAND_LOG": str(command_log),
                },
            )
            self.assertEqual(0, rollback.returncode, rollback.stderr)
            self.assertEqual(release, current.resolve())
            self.assertEqual(release_b, previous.resolve())
            self.assertIn(
                "sudo systemctl restart hermex-companion.service",
                command_log.read_text(encoding="utf-8"),
            )

            installed_python = (
                current / "Companion" / ".venv" / "bin" / "python"
            )
            installed_python.parent.mkdir(parents=True)
            installed_python.write_text(
                "#!/bin/sh\n"
                'printf "%s\\n" "$*" >> "$COMPANIONCTL_COMMAND_LOG"\n'
                'printf "PYTHONPATH=%s\\n" "$PYTHONPATH" '
                '>> "$COMPANIONCTL_COMMAND_LOG"\n'
                'printf "disposable-pairing-secret\\n"\n',
                encoding="utf-8",
            )
            installed_python.chmod(0o755)
            command_log.write_text("", encoding="utf-8")
            pairing = self._run(
                config_home,
                state_home,
                data_home,
                "pair",
                "--expires-in",
                "180",
                environment={
                    "COMPANIONCTL_COMMAND_LOG": str(command_log),
                    "PYTHONPATH": "/existing/python/path",
                },
            )
            self.assertEqual(0, pairing.returncode, pairing.stderr)
            self.assertEqual(
                "disposable-pairing-secret\n",
                pairing.stdout,
            )
            self.assertIn(
                "-m hermex_companion pairing create --expires-in 180",
                command_log.read_text(encoding="utf-8"),
            )
            self.assertIn(
                (
                    "PYTHONPATH="
                    f"{current.resolve() / 'Companion' / 'src'}"
                    f"{os.pathsep}/existing/python/path"
                ),
                command_log.read_text(encoding="utf-8"),
            )

            health_server = ThreadingHTTPServer(
                ("127.0.0.1", 0),
                _HealthHandler,
            )
            health_thread = threading.Thread(
                target=health_server.serve_forever,
                daemon=True,
            )
            health_thread.start()
            try:
                health_port = health_server.server_address[1]
                status_result = self._run(
                    config_home,
                    state_home,
                    data_home,
                    "status",
                    "--health-url",
                    (
                        f"http://127.0.0.1:{health_port}"
                        "/companion/v1/health"
                    ),
                    environment={
                        "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    },
                )
            finally:
                health_server.shutdown()
                health_server.server_close()
                health_thread.join(timeout=3)

            self.assertEqual(
                0,
                status_result.returncode,
                status_result.stderr,
            )
            status_payload = json.loads(status_result.stdout)
            self.assertEqual("release-a", status_payload["release"])
            self.assertEqual("active", status_payload["service"]["active"])
            self.assertEqual("enabled", status_payload["service"]["enabled"])
            self.assertEqual("ok", status_payload["health"]["status"])
            self.assertEqual(
                "1",
                status_payload["health"]["contract_version"],
            )

            rejected_install = self._run(
                config_home,
                state_home,
                data_home,
                "install",
                "--source-root",
                str(COMPANION_ROOT.parent),
                "--release-id",
                "release-c",
                "--service-user",
                "test-user",
                "--service-group",
                "test-group",
                environment={
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "COMPANIONCTL_COMMAND_LOG": str(command_log),
                },
            )
            self.assertNotEqual(0, rejected_install.returncode)
            self.assertIn("use the upgrade command", rejected_install.stderr)
            self.assertFalse(
                (
                    data_home
                    / "hermex-companion"
                    / "releases"
                    / "release-c"
                ).exists()
            )

    def _run(
        self,
        config_home: Path,
        state_home: Path,
        data_home: Path,
        *arguments: str,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(COMPANIONCTL),
                "--config-home",
                str(config_home),
                "--state-home",
                str(state_home),
                "--data-home",
                str(data_home),
                *arguments,
            ],
            check=False,
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "PYTHONUTF8": "1",
                **(environment or {}),
            },
        )


if __name__ == "__main__":
    unittest.main()
