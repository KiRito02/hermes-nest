from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


COMPANION_ROOT = Path(__file__).resolve().parents[1]
RENDERER = COMPANION_ROOT / "deploy" / "render_systemd.py"


class DeploymentContractTests(unittest.TestCase):
    def test_renderer_keeps_identity_and_xdg_paths_out_of_template(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            config_home = root / "config"
            state_home = root / "state"
            data_home = root / "data"
            companion_dir = data_home / "hermex-companion" / "current" / "Companion"

            result = subprocess.run(
                [
                    sys.executable,
                    str(RENDERER),
                    "--service-user",
                    "test-user",
                    "--service-group",
                    "test-group",
                    "--config-home",
                    str(config_home),
                    "--state-home",
                    str(state_home),
                    "--data-home",
                    str(data_home),
                    "--companion-dir",
                    str(companion_dir),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

        unit = result.stdout
        self.assertIn("User=test-user", unit)
        self.assertIn("Group=test-group", unit)
        self.assertIn(f"Environment=XDG_CONFIG_HOME={config_home}", unit)
        self.assertIn(f"Environment=XDG_STATE_HOME={state_home}", unit)
        self.assertIn(f"Environment=XDG_DATA_HOME={data_home}", unit)
        self.assertIn(
            f"Environment=PYTHONPATH={companion_dir / 'src'}",
            unit,
        )
        self.assertIn(
            f"ExecStart={companion_dir / '.venv/bin/python'} -m hermex_companion",
            unit,
        )
        self.assertIn("EnvironmentFile=", unit)
        self.assertIn("Restart=on-failure", unit)
        self.assertIn("After=network-online.target hermes-gateway.service", unit)
        self.assertNotIn("Requires=hermes-gateway.service", unit)
        self.assertNotIn("@", unit)

    def test_renderer_rejects_relative_deployment_paths(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(RENDERER),
                "--service-user",
                "test-user",
                "--service-group",
                "test-group",
                "--config-home",
                "relative/config",
                "--state-home",
                "/tmp/state",
                "--data-home",
                "/tmp/data",
                "--companion-dir",
                "/tmp/data/current/Companion",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("User=test-user", result.stdout)


if __name__ == "__main__":
    unittest.main()
