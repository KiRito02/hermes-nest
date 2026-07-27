"""Run the Hermes Nest Companion HTTP process."""

import argparse
from collections.abc import Sequence
import os
import sys

from aiohttp import web

from hermex_companion.app import create_app
from hermex_companion.gateway import GatewayDiscovery
from hermex_companion.memory import MemoryAccess
from hermex_companion.paths import database_path, workspace_config_path
from hermex_companion.registry import DeviceRegistry
from hermex_companion.workspace import WorkspaceAccess

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8643
DEFAULT_GATEWAY_URL = "http://127.0.0.1:8642"


def _serve_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run Hermes Nest Companion")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", default=DEFAULT_PORT, type=int)
    return parser


def _pairing_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage Companion pairing")
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create", help="Create a single-use secret")
    create.add_argument("--expires-in", default=300, type=int)
    return parser


def _create_pairing_secret(arguments: Sequence[str]) -> None:
    options = _pairing_parser().parse_args(arguments)
    if options.command != "create":
        raise AssertionError("unreachable pairing command")
    registry = DeviceRegistry(database_path())
    try:
        secret = registry.create_pairing_secret(options.expires_in)
    finally:
        registry.close()
    print(secret)


def _serve(arguments: Sequence[str]) -> None:
    options = _serve_parser().parse_args(arguments)
    registry = DeviceRegistry(database_path())
    gateway = GatewayDiscovery(
        os.environ.get("HERMEX_COMPANION_GATEWAY_URL", DEFAULT_GATEWAY_URL),
        os.environ.get("HERMEX_COMPANION_GATEWAY_KEY", ""),
    )
    workspace = WorkspaceAccess.from_config_file(workspace_config_path())
    memory = MemoryAccess.from_config_file(workspace_config_path())
    web.run_app(
        create_app(registry, gateway, workspace=workspace, memory=memory),
        host=options.host,
        port=options.port,
        print=None,
    )


def main(arguments: Sequence[str] | None = None) -> None:
    values = list(sys.argv[1:] if arguments is None else arguments)
    if values and values[0] == "pairing":
        _create_pairing_secret(values[1:])
        return
    _serve(values)


if __name__ == "__main__":
    main()
