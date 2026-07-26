#!/usr/bin/env python3
"""Classify pull-request paths for the independent iOS and Companion gates."""

from __future__ import annotations

import os
import sys
from collections.abc import Iterable
from pathlib import PurePosixPath


DOC_EXACT = {
    ".github/CODEOWNERS",
    ".github/FUNDING.yml",
    ".github/dependabot.yml",
    ".gitignore",
    "LICENSE",
}
SHARED_CI_PATHS = {
    ".github/workflows/pr-ci.yml",
    "scripts/classify-ci-paths.py",
}


def is_documentation(path: str) -> bool:
    return (
        path in DOC_EXACT
        or path.startswith("docs/")
        or path.startswith(".github/ISSUE_TEMPLATE/")
        or PurePosixPath(path).suffix.lower() == ".md"
    )


def classify(paths: Iterable[str]) -> tuple[bool, bool]:
    changed = [
        path.rstrip("\r\n")
        for path in paths
        if path.rstrip("\r\n")
    ]
    non_docs = [path for path in changed if not is_documentation(path)]

    # Fail closed for unknown product/config paths: only an exclusively
    # Companion change may skip the macOS iOS gate.
    run_ios = any(not path.startswith("Companion/") for path in non_docs)
    run_companion = any(
        path.startswith("Companion/") or path in SHARED_CI_PATHS
        for path in non_docs
    )
    return run_ios, run_companion


def emit(run_ios: bool, run_companion: bool) -> None:
    values = (
        f"run_ios={'true' if run_ios else 'false'}",
        f"run_companion={'true' if run_companion else 'false'}",
    )
    print("\n".join(values))
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as output:
            output.write("\n".join(values) + "\n")


def self_test() -> None:
    cases = [
        (["README.md", "docs/agents/README.md"], (False, False)),
        (["Companion/src/hermes_companion/app.py"], (False, True)),
        (["HermesMobile/Config/AppTheme.swift"], (True, False)),
        (
            [
                "Companion/tests/test_contract.py",
                "HermesMobileTests/AppThemeTests.swift",
            ],
            (True, True),
        ),
        ([".github/workflows/pr-ci.yml"], (True, True)),
        (["scripts/classify-ci-paths.py"], (True, True)),
        (["Config/Debug.xcconfig"], (True, False)),
    ]
    for paths, expected in cases:
        actual = classify(paths)
        if actual != expected:
            raise SystemExit(
                f"routing mismatch for {paths}: expected {expected}, got {actual}"
            )
    print(f"CI path routing: {len(cases)} cases passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif sys.argv[1:]:
        raise SystemExit("usage: classify-ci-paths.py [--self-test]")
    else:
        emit(*classify(sys.stdin))
