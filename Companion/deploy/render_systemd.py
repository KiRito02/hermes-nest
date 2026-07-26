from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


PLACEHOLDERS = {
    "SERVICE_USER",
    "SERVICE_GROUP",
    "CONFIG_HOME",
    "STATE_HOME",
    "DATA_HOME",
    "COMPANION_DIR",
    "HOST_WRITE_PATHS",
}


def absolute_path(raw_value: str) -> str:
    path = Path(raw_value)
    if not path.is_absolute():
        raise argparse.ArgumentTypeError("deployment paths must be absolute")
    if re.fullmatch(r"/[A-Za-z0-9._/-]+", raw_value) is None:
        raise argparse.ArgumentTypeError(
            "deployment paths may contain only letters, digits, '/', '.', '_', and '-'"
        )
    return str(path)


def identity(raw_value: str) -> str:
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", raw_value) is None:
        raise argparse.ArgumentTypeError("service identity contains unsupported characters")
    return raw_value


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Render the Hermes Nest Companion systemd unit without owner-local values in git."
    )
    result.add_argument("--service-user", required=True, type=identity)
    result.add_argument("--service-group", required=True, type=identity)
    result.add_argument("--config-home", required=True, type=absolute_path)
    result.add_argument("--state-home", required=True, type=absolute_path)
    result.add_argument("--data-home", required=True, type=absolute_path)
    result.add_argument("--companion-dir", required=True, type=absolute_path)
    result.add_argument("--host-config", type=absolute_path)
    return result


def configured_write_paths(config_path: str | None) -> list[str]:
    if config_path is None:
        return []
    payload = json.loads(Path(config_path).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("host configuration must be a JSON object")
    paths: list[str] = []
    roots = payload.get("roots", [])
    if not isinstance(roots, list):
        raise ValueError("host configuration roots must be a list")
    for root in roots:
        if not isinstance(root, dict):
            raise ValueError("host configuration roots must be objects")
        if root.get("writable") is True:
            paths.append(absolute_path(root.get("path", "")))
    memory = payload.get("memory")
    if memory is not None:
        if not isinstance(memory, dict):
            raise ValueError("host Memory configuration must be an object")
        paths.append(absolute_path(memory.get("directory", "")))
    return list(dict.fromkeys(paths))


def render(arguments: argparse.Namespace) -> str:
    template_path = Path(__file__).with_name("hermex-companion.service.in")
    rendered = template_path.read_text(encoding="utf-8")
    values = {
        "SERVICE_USER": arguments.service_user,
        "SERVICE_GROUP": arguments.service_group,
        "CONFIG_HOME": arguments.config_home,
        "STATE_HOME": arguments.state_home,
        "DATA_HOME": arguments.data_home,
        "COMPANION_DIR": arguments.companion_dir,
        "HOST_WRITE_PATHS": "\n".join(
            f"ReadWritePaths={path}"
            for path in configured_write_paths(arguments.host_config)
        ),
    }
    for name, value in values.items():
        rendered = rendered.replace(f"@{name}@", value)

    unresolved = [name for name in PLACEHOLDERS if f"@{name}@" in rendered]
    if unresolved:
        raise RuntimeError(f"unresolved placeholders: {', '.join(sorted(unresolved))}")
    return rendered


def main() -> None:
    arguments = parser().parse_args()
    print(render(arguments), end="")


if __name__ == "__main__":
    main()
