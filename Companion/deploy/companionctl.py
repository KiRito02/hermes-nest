#!/usr/bin/env python3
"""Install and preserve Hermes Nest Companion without exposing host secrets."""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
import getpass
import grp
import ipaddress
import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
from urllib import error as url_error
from urllib import parse as url_parse
from urllib import request as url_request


COMPANION_DIRECTORY = "hermex-companion"
WORKSPACE_CONFIG = "workspaces.json"
DEPLOYMENT_CONFIG = "deployment.json"
STATE_DATABASE = "companion.sqlite3"
BACKUP_VERSION = 1
MAXIMUM_WORKSPACE_CONFIG_BYTES = 1 * 1_024 * 1_024
MAXIMUM_STATE_DATABASE_BYTES = 256 * 1_024 * 1_024
BACKUP_MEMBERS = {
    "manifest.json",
    f"config/{WORKSPACE_CONFIG}",
    f"state/{STATE_DATABASE}",
}


def absolute_path(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise argparse.ArgumentTypeError("path must be absolute")
    return path


def release_identifier(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", value):
        raise argparse.ArgumentTypeError("release ID contains unsafe characters")
    return value


def service_identity(value: object) -> str:
    if (
        not isinstance(value, str)
        or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", value)
    ):
        raise argparse.ArgumentTypeError(
            "service identity contains unsupported characters"
        )
    return value


def pairing_lifetime(value: str) -> int:
    try:
        seconds = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("expiry must be an integer") from error
    if not 30 <= seconds <= 3_600:
        raise argparse.ArgumentTypeError("expiry must be between 30 and 3600 seconds")
    return seconds


def loopback_health_url(value: str) -> str:
    parsed = url_parse.urlsplit(value)
    try:
        address = ipaddress.ip_address(parsed.hostname or "")
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "health URL host must be a loopback IP address"
        ) from error
    if (
        parsed.scheme != "http"
        or not address.is_loopback
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path != "/companion/v1/health"
    ):
        raise argparse.ArgumentTypeError(
            "health URL must be the bare loopback Companion health endpoint"
        )
    return value


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="companionctl",
        description="Manage a Hermes Nest Companion host installation.",
    )
    parser.add_argument(
        "--config-home",
        type=absolute_path,
        default=Path(
            os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")
        ),
    )
    parser.add_argument(
        "--state-home",
        type=absolute_path,
        default=Path(
            os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")
        ),
    )
    parser.add_argument(
        "--data-home",
        type=absolute_path,
        default=Path(
            os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")
        ),
    )

    commands = parser.add_subparsers(dest="command", required=True)
    backup = commands.add_parser(
        "backup",
        help="archive non-secret Companion config and device state",
    )
    backup.add_argument("--output", required=True, type=absolute_path)
    restore = commands.add_parser(
        "restore",
        help="restore a non-secret Companion backup onto a prepared host",
    )
    restore.add_argument("--input", required=True, type=absolute_path)
    install = commands.add_parser(
        "install",
        help="install an immutable release and enable the systemd service",
    )
    install.add_argument(
        "--source-root",
        type=absolute_path,
        default=Path(__file__).resolve().parents[2],
    )
    install.add_argument(
        "--release-id",
        type=release_identifier,
    )
    install.add_argument(
        "--service-user",
        type=service_identity,
        default=getpass.getuser(),
    )
    install.add_argument(
        "--service-group",
        type=service_identity,
        default=grp.getgrgid(os.getgid()).gr_name,
    )
    install.add_argument(
        "--agent-working-directory",
        type=absolute_path,
        default=Path.home() / ".hermes",
    )
    install.add_argument(
        "--workspace-root",
        type=absolute_path,
        default=Path.home() / ".hermes" / "workspace",
    )
    upgrade = commands.add_parser(
        "upgrade",
        help="install a new immutable release and restart the service",
    )
    upgrade.add_argument(
        "--source-root",
        type=absolute_path,
        default=Path(__file__).resolve().parents[2],
    )
    upgrade.add_argument(
        "--release-id",
        type=release_identifier,
    )
    commands.add_parser(
        "rollback",
        help="swap the current and previous immutable releases",
    )
    pair = commands.add_parser(
        "pair",
        help="create a short-lived one-time App pairing secret",
    )
    pair.add_argument(
        "--expires-in",
        type=pairing_lifetime,
        default=300,
    )
    status = commands.add_parser(
        "status",
        help="show the selected release, systemd state, and local health",
    )
    status.add_argument(
        "--health-url",
        type=loopback_health_url,
        default="http://127.0.0.1:8643/companion/v1/health",
    )
    return parser.parse_args()


def add_bytes(
    archive: tarfile.TarFile,
    archive_name: str,
    payload: bytes,
    *,
    mode: int,
) -> None:
    member = tarfile.TarInfo(archive_name)
    member.size = len(payload)
    member.mode = mode
    member.mtime = 0
    member.uid = 0
    member.gid = 0
    member.uname = ""
    member.gname = ""
    archive.addfile(member, io.BytesIO(payload))


def read_regular_nofollow(path: Path, maximum_bytes: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise SystemExit(
            f"backup source must be a regular non-symbolic file: {path}"
        ) from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > maximum_bytes:
            raise SystemExit(
                f"backup source must be a regular non-symbolic file: {path}"
            )
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            payload = source.read(maximum_bytes + 1)
        if len(payload) != metadata.st_size:
            raise SystemExit(f"backup source changed while reading: {path}")
        return payload
    finally:
        os.close(descriptor)


def read_consistent_sqlite_backup(path: Path, maximum_bytes: int) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise SystemExit(
            f"backup source must be a regular non-symbolic file: {path}"
        ) from error
    if (
        path.is_symlink()
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size > maximum_bytes
    ):
        raise SystemExit(
            f"backup source must be a regular non-symbolic file: {path}"
        )

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.snapshot.",
        suffix=".tmp",
        dir=path.parent,
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    source_uri = f"file:{url_parse.quote(str(path))}?mode=ro"
    try:
        with (
            sqlite3.connect(source_uri, uri=True, timeout=5) as source,
            sqlite3.connect(temporary) as snapshot,
        ):
            source.execute("PRAGMA query_only = ON")
            source.backup(snapshot)
        return read_regular_nofollow(temporary, maximum_bytes)
    except sqlite3.Error as error:
        raise SystemExit(
            f"Companion SQLite state could not be backed up: {error}"
        ) from error
    finally:
        temporary.unlink(missing_ok=True)


def create_backup(arguments: argparse.Namespace) -> None:
    output: Path = arguments.output
    if output.exists():
        raise SystemExit(f"backup output already exists: {output}")

    config_directory = arguments.config_home / COMPANION_DIRECTORY
    state_directory = arguments.state_home / COMPANION_DIRECTORY
    workspace_config = config_directory / WORKSPACE_CONFIG
    state_database = state_directory / STATE_DATABASE
    workspace_payload = read_regular_nofollow(
        workspace_config,
        MAXIMUM_WORKSPACE_CONFIG_BYTES,
    )
    database_payload = read_consistent_sqlite_backup(
        state_database,
        MAXIMUM_STATE_DATABASE_BYTES,
    )

    manifest = json.dumps(
        {
            "backup_version": BACKUP_VERSION,
            "created_at": datetime.now(UTC).isoformat(),
            "includes_gateway_key": False,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.",
        suffix=".tmp",
        dir=output.parent,
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            with tarfile.open(fileobj=stream, mode="w:gz") as archive:
                add_bytes(
                    archive,
                    "manifest.json",
                    manifest,
                    mode=0o600,
                )
                add_bytes(
                    archive,
                    f"config/{WORKSPACE_CONFIG}",
                    workspace_payload,
                    mode=0o600,
                )
                add_bytes(
                    archive,
                    f"state/{STATE_DATABASE}",
                    database_payload,
                    mode=0o600,
                )
        os.replace(temporary, output)
        output.chmod(0o600)
    finally:
        temporary.unlink(missing_ok=True)

    print(output)


def read_archive_member(
    archive: tarfile.TarFile,
    member_name: str,
    maximum_bytes: int,
) -> bytes:
    member = archive.getmember(member_name)
    if not member.isfile():
        raise SystemExit(f"backup member must be a regular file: {member_name}")
    if member.size > maximum_bytes:
        raise SystemExit(f"backup member is too large: {member_name}")
    extracted = archive.extractfile(member)
    if extracted is None:
        raise SystemExit(f"backup member could not be read: {member_name}")
    payload = extracted.read(maximum_bytes + 1)
    if len(payload) != member.size:
        raise SystemExit(f"backup member size changed while reading: {member_name}")
    return payload


def validate_workspace_config(payload: bytes) -> None:
    try:
        configuration = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit("restored workspace configuration is invalid JSON") from error
    if not isinstance(configuration, dict):
        raise SystemExit("restored workspace configuration must be an object")

    path_values: list[object] = [
        configuration.get("agent_working_directory")
    ]
    roots = configuration.get("roots")
    if not isinstance(roots, list):
        raise SystemExit("restored workspace roots must be an array")
    for root in roots:
        if not isinstance(root, dict):
            raise SystemExit("restored workspace root must be an object")
        path_values.append(root.get("path"))

    memory = configuration.get("memory")
    if memory is not None:
        if not isinstance(memory, dict):
            raise SystemExit("restored Memory configuration must be an object")
        path_values.append(memory.get("directory"))

    for value in path_values:
        if not isinstance(value, str) or not value:
            raise SystemExit("restored workspace path must be a non-empty string")
        path = Path(value)
        if not path.is_absolute():
            raise SystemExit(f"restored workspace path must be absolute: {value}")
        if not path.is_dir():
            raise SystemExit(f"restored workspace path does not exist: {value}")


def write_private_file(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        temporary.unlink(missing_ok=True)


def restore_backup(arguments: argparse.Namespace) -> None:
    backup: Path = arguments.input
    if not backup.is_file():
        raise SystemExit(f"backup does not exist: {backup}")

    workspace_target = (
        arguments.config_home / COMPANION_DIRECTORY / WORKSPACE_CONFIG
    )
    database_target = (
        arguments.state_home / COMPANION_DIRECTORY / STATE_DATABASE
    )
    for target in (workspace_target, database_target):
        if target.exists():
            raise SystemExit(f"restore target already exists: {target}")

    try:
        with tarfile.open(backup, "r:gz") as archive:
            members = archive.getmembers()
            names = [member.name for member in members]
            if len(names) != len(set(names)) or set(names) != BACKUP_MEMBERS:
                raise SystemExit("backup contains unexpected or duplicate members")
            manifest_payload = read_archive_member(
                archive,
                "manifest.json",
                maximum_bytes=64 * 1_024,
            )
            workspace_payload = read_archive_member(
                archive,
                f"config/{WORKSPACE_CONFIG}",
                maximum_bytes=MAXIMUM_WORKSPACE_CONFIG_BYTES,
            )
            database_payload = read_archive_member(
                archive,
                f"state/{STATE_DATABASE}",
                maximum_bytes=MAXIMUM_STATE_DATABASE_BYTES,
            )
    except (tarfile.TarError, OSError) as error:
        raise SystemExit(f"backup could not be read: {error}") from error

    try:
        manifest = json.loads(manifest_payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit("backup manifest is invalid JSON") from error
    if (
        not isinstance(manifest, dict)
        or manifest.get("backup_version") != BACKUP_VERSION
        or manifest.get("includes_gateway_key") is not False
    ):
        raise SystemExit("backup manifest is incompatible or unsafe")

    validate_workspace_config(workspace_payload)
    write_private_file(workspace_target, workspace_payload)
    try:
        write_private_file(database_target, database_payload)
    except BaseException:
        workspace_target.unlink(missing_ok=True)
        raise
    print("Companion backup restored; configure the target Gateway key separately.")


def run_command(arguments: list[str], **options: object) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(arguments, check=True, **options)
    except FileNotFoundError as error:
        raise SystemExit(f"required command is unavailable: {arguments[0]}") from error
    except subprocess.CalledProcessError as error:
        raise SystemExit(
            f"command failed with status {error.returncode}: {arguments[0]}"
        ) from error


def resolve_release_id(source_root: Path, configured: str | None) -> str:
    if configured is not None:
        return configured
    result = run_command(
        ["git", "-C", str(source_root), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
    )
    candidate = result.stdout.strip()
    try:
        return release_identifier(candidate)
    except argparse.ArgumentTypeError as error:
        raise SystemExit("source checkout did not provide a safe commit ID") from error


def prepare_initial_configuration(arguments: argparse.Namespace) -> None:
    config_directory = arguments.config_home / COMPANION_DIRECTORY
    workspace_config = config_directory / WORKSPACE_CONFIG
    environment_file = config_directory / "hermex-companion.env"
    deployment_config = config_directory / DEPLOYMENT_CONFIG
    config_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    config_directory.chmod(0o700)

    if not workspace_config.exists():
        for path in (
            arguments.agent_working_directory,
            arguments.workspace_root,
        ):
            if not path.is_dir():
                raise SystemExit(f"default Hermes directory does not exist: {path}")
        try:
            arguments.workspace_root.relative_to(
                arguments.agent_working_directory
            )
        except ValueError as error:
            raise SystemExit(
                "writable workspace root must be inside the Agent working directory"
            ) from error
        workspace_payload = json.dumps(
            {
                "agent_working_directory": str(
                    arguments.agent_working_directory
                ),
                "roots": [
                    {
                        "id": "hermes-workspace",
                        "name": "Hermes Workspace",
                        "path": str(arguments.workspace_root),
                        "writable": True,
                    }
                ],
            },
            indent=2,
        ).encode("utf-8") + b"\n"
        write_private_file(workspace_config, workspace_payload)

    if not environment_file.exists():
        gateway_key = os.environ.get("HERMEX_COMPANION_GATEWAY_KEY")
        if gateway_key is None:
            gateway_key = getpass.getpass("Hermes Gateway API key: ")
        if not gateway_key or "\n" in gateway_key or "\r" in gateway_key:
            raise SystemExit("Gateway API key must be one non-empty line")
        environment_payload = (
            "HERMEX_COMPANION_GATEWAY_URL=http://127.0.0.1:8642\n"
            f"HERMEX_COMPANION_GATEWAY_KEY={gateway_key}\n"
        ).encode("utf-8")
        write_private_file(environment_file, environment_payload)

    deployment_payload = json.dumps(
        {
            "service_user": arguments.service_user,
            "service_group": arguments.service_group,
        },
        sort_keys=True,
        indent=2,
    ).encode("utf-8") + b"\n"
    if deployment_config.exists():
        stored_user, stored_group = read_deployment_identity(
            deployment_config
        )
        if (
            stored_user != arguments.service_user
            or stored_group != arguments.service_group
        ):
            raise SystemExit(
                "configured service identity differs from this install request"
            )
    else:
        write_private_file(deployment_config, deployment_payload)


def read_deployment_identity(path: Path) -> tuple[str, str]:
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"deployment configuration is missing or unsafe: {path}")
    try:
        payload = json.loads(
            read_regular_nofollow(path, 64 * 1_024)
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit("deployment configuration is invalid JSON") from error
    if not isinstance(payload, dict):
        raise SystemExit("deployment configuration must be an object")
    try:
        user = service_identity(payload.get("service_user", ""))
        group = service_identity(payload.get("service_group", ""))
    except argparse.ArgumentTypeError as error:
        raise SystemExit("deployment configuration has an invalid identity") from error
    return user, group


def set_current_release(current: Path, release: Path) -> None:
    temporary = current.with_name(f".{current.name}.{os.getpid()}.tmp")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(release, target_is_directory=True)
    os.replace(temporary, current)


def install_release(
    arguments: argparse.Namespace,
    *,
    enable_service: bool,
) -> None:
    arguments.release_id = resolve_release_id(
        arguments.source_root,
        arguments.release_id,
    )
    if enable_service:
        prepare_initial_configuration(arguments)
    else:
        deployment_config = (
            arguments.config_home
            / COMPANION_DIRECTORY
            / DEPLOYMENT_CONFIG
        )
        (
            arguments.service_user,
            arguments.service_group,
        ) = read_deployment_identity(deployment_config)

    source_companion = arguments.source_root / "Companion"
    if not (source_companion / "pyproject.toml").is_file():
        raise SystemExit(
            f"source root does not contain Companion/pyproject.toml: "
            f"{arguments.source_root}"
        )

    config_directory = arguments.config_home / COMPANION_DIRECTORY
    state_directory = arguments.state_home / COMPANION_DIRECTORY
    data_directory = arguments.data_home / COMPANION_DIRECTORY
    current = data_directory / "current"
    previous_release = current.resolve() if current.is_symlink() else None
    if enable_service and previous_release is not None:
        raise SystemExit(
            "Companion is already installed; use the upgrade command"
        )
    if not enable_service and previous_release is None:
        raise SystemExit(
            "Companion is not installed; use the install command first"
        )
    workspace_config = config_directory / WORKSPACE_CONFIG
    environment_file = config_directory / "hermex-companion.env"
    for required in (workspace_config, environment_file):
        if not required.is_file() or required.is_symlink():
            raise SystemExit(f"required host configuration is missing: {required}")
    validate_workspace_config(workspace_config.read_bytes())
    config_directory.chmod(0o700)
    environment_file.chmod(0o600)
    workspace_config.chmod(0o600)
    state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_directory.chmod(0o700)

    releases = data_directory / "releases"
    releases.mkdir(parents=True, exist_ok=True)
    release = releases / arguments.release_id
    if release.exists() or release.is_symlink():
        raise SystemExit(f"release already exists: {release}")
    temporary_release = Path(
        tempfile.mkdtemp(
            prefix=f".{arguments.release_id}.",
            dir=releases,
        )
    )
    try:
        shutil.copytree(
            source_companion,
            temporary_release / "Companion",
            ignore=shutil.ignore_patterns(
                ".venv",
                "__pycache__",
                ".pytest_cache",
                "*.pyc",
            ),
        )
        os.replace(temporary_release, release)
    finally:
        if temporary_release.exists():
            shutil.rmtree(temporary_release)

    try:
        run_command(
            [
                "uv",
                "sync",
                "--frozen",
                "--project",
                str(release / "Companion"),
            ]
        )
    except BaseException:
        shutil.rmtree(release)
        raise

    rendered_unit = data_directory / "hermex-companion.service"
    renderer = release / "Companion" / "deploy" / "render_systemd.py"
    rendered = run_command(
        [
            sys.executable,
            str(renderer),
            "--service-user",
            arguments.service_user,
            "--service-group",
            arguments.service_group,
            "--config-home",
            str(arguments.config_home),
            "--state-home",
            str(arguments.state_home),
            "--data-home",
            str(arguments.data_home),
            "--companion-dir",
            str(data_directory / "current" / "Companion"),
            "--host-config",
            str(workspace_config),
        ],
        capture_output=True,
        text=True,
    ).stdout
    rendered_unit.write_text(rendered, encoding="utf-8")
    rendered_unit.chmod(0o644)

    previous = data_directory / "previous"
    if previous_release is not None:
        set_current_release(previous, previous_release)
    set_current_release(current, release)
    try:
        run_command(
            [
                "sudo",
                "install",
                "-m",
                "0644",
                str(rendered_unit),
                "/etc/systemd/system/hermex-companion.service",
            ]
        )
        run_command(["sudo", "systemctl", "daemon-reload"])
        if enable_service:
            run_command(
                [
                    "sudo",
                    "systemctl",
                    "enable",
                    "--now",
                    "hermex-companion.service",
                ]
            )
        else:
            run_command(
                [
                    "sudo",
                    "systemctl",
                    "restart",
                    "hermex-companion.service",
                ]
            )
    except BaseException:
        if previous_release is not None:
            set_current_release(current, previous_release)
        else:
            current.unlink(missing_ok=True)
        raise

    print(f"Companion release installed: {arguments.release_id}")


def rollback_release(arguments: argparse.Namespace) -> None:
    data_directory = arguments.data_home / COMPANION_DIRECTORY
    releases = (data_directory / "releases").resolve()
    current = data_directory / "current"
    previous = data_directory / "previous"
    if not current.is_symlink() or not previous.is_symlink():
        raise SystemExit("both current and previous releases are required")
    current_release = current.resolve()
    previous_release = previous.resolve()
    for release in (current_release, previous_release):
        if release.parent != releases or not release.is_dir():
            raise SystemExit(f"release link escapes the immutable store: {release}")

    set_current_release(current, previous_release)
    set_current_release(previous, current_release)
    try:
        run_command(
            [
                "sudo",
                "systemctl",
                "restart",
                "hermex-companion.service",
            ]
        )
    except BaseException:
        set_current_release(current, current_release)
        set_current_release(previous, previous_release)
        raise
    print(f"Companion rolled back to: {previous_release.name}")


def create_pairing_secret(arguments: argparse.Namespace) -> None:
    data_directory = arguments.data_home / COMPANION_DIRECTORY
    current = data_directory / "current"
    releases = (data_directory / "releases").resolve()
    if not current.is_symlink():
        raise SystemExit("Companion is not installed")
    release = current.resolve()
    if release.parent != releases or not release.is_dir():
        raise SystemExit(f"current release escapes the immutable store: {release}")
    python = release / "Companion" / ".venv" / "bin" / "python"
    if not python.is_file():
        raise SystemExit(f"installed Companion Python is missing: {python}")
    environment = {
        **os.environ,
        "XDG_STATE_HOME": str(arguments.state_home),
    }
    run_command(
        [
            str(python),
            "-m",
            "hermex_companion",
            "pairing",
            "create",
            "--expires-in",
            str(arguments.expires_in),
        ],
        env=environment,
    )


def systemd_property(action: str) -> str:
    try:
        result = subprocess.run(
            ["systemctl", action, "hermex-companion.service"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"systemctl {action} could not be read") from error
    value = result.stdout.strip()
    if not value or len(value) > 64 or any(character.isspace() for character in value):
        return "unknown"
    return value


def local_health(health_url: str) -> dict[str, object]:
    try:
        with url_request.urlopen(health_url, timeout=3) as response:
            payload_bytes = response.read(16 * 1_024 + 1)
    except (OSError, url_error.URLError) as error:
        return {"status": "unavailable", "reason": type(error).__name__}
    if len(payload_bytes) > 16 * 1_024:
        return {"status": "invalid", "reason": "response_too_large"}
    try:
        payload = json.loads(payload_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {"status": "invalid", "reason": "invalid_json"}
    if not isinstance(payload, dict):
        return {"status": "invalid", "reason": "invalid_shape"}
    return {
        key: payload.get(key)
        for key in (
            "status",
            "service",
            "companion_version",
            "contract_version",
        )
        if isinstance(payload.get(key), (str, int, float, bool))
    }


def show_status(arguments: argparse.Namespace) -> None:
    data_directory = arguments.data_home / COMPANION_DIRECTORY
    current = data_directory / "current"
    releases = (data_directory / "releases").resolve()
    release_name: str | None = None
    if current.is_symlink():
        release = current.resolve()
        if release.parent == releases and release.is_dir():
            release_name = release.name
    payload = {
        "release": release_name,
        "service": {
            "active": systemd_property("is-active"),
            "enabled": systemd_property("is-enabled"),
        },
        "health": local_health(arguments.health_url),
    }
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")))


def main() -> None:
    if sys.version_info[:2] != (3, 11):
        raise SystemExit(
            "companionctl requires Python 3.11 "
            f"(running {sys.version_info.major}.{sys.version_info.minor})"
        )
    arguments = parse_arguments()
    if arguments.command == "backup":
        create_backup(arguments)
    elif arguments.command == "restore":
        restore_backup(arguments)
    elif arguments.command == "install":
        install_release(arguments, enable_service=True)
    elif arguments.command == "upgrade":
        install_release(arguments, enable_service=False)
    elif arguments.command == "rollback":
        rollback_release(arguments)
    elif arguments.command == "pair":
        create_pairing_secret(arguments)
    elif arguments.command == "status":
        show_status(arguments)


if __name__ == "__main__":
    main()
