"""Owner-local Companion state paths."""

import os
from pathlib import Path
from typing import Mapping

APPLICATION_DIRECTORY = "hermex-companion"
DATABASE_FILENAME = "companion.sqlite3"
WORKSPACE_CONFIG_FILENAME = "workspaces.json"


def config_directory(environment: Mapping[str, str] | None = None) -> Path:
    values = os.environ if environment is None else environment
    configured = values.get("XDG_CONFIG_HOME")
    root = Path(configured).expanduser() if configured else Path.home() / ".config"
    return root / APPLICATION_DIRECTORY


def state_directory(environment: Mapping[str, str] | None = None) -> Path:
    values = os.environ if environment is None else environment
    configured = values.get("XDG_STATE_HOME")
    root = Path(configured).expanduser() if configured else Path.home() / ".local/state"
    return root / APPLICATION_DIRECTORY


def database_path(environment: Mapping[str, str] | None = None) -> Path:
    return state_directory(environment) / DATABASE_FILENAME


def workspace_config_path(environment: Mapping[str, str] | None = None) -> Path:
    return config_directory(environment) / WORKSPACE_CONFIG_FILENAME
