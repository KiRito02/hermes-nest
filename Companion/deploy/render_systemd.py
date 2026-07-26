from __future__ import annotations

import argparse
import re
from pathlib import Path


PLACEHOLDERS = {
    "SERVICE_USER",
    "SERVICE_GROUP",
    "CONFIG_HOME",
    "STATE_HOME",
    "DATA_HOME",
    "COMPANION_DIR",
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
    return result


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
