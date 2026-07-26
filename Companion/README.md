# Hermes Nest Companion

Hermes Nest Companion is the App's only network endpoint. It listens on
`127.0.0.1:8643` by default, authenticates each iPhone/iPad with a revocable
device credential, and connects to Hermes Agent API Server on
`127.0.0.1:8642`. The Gateway `API_SERVER_KEY` stays on the Hermes Agent host.

The versioned App-facing protocol is defined by [CONTRACT.md](CONTRACT.md).

## Development

Python 3.11 and `uv` are required:

```bash
uv sync --frozen --project Companion
PYTHONPATH=Companion/src Companion/.venv/bin/python -m unittest discover -s Companion/tests -v
PYTHONPATH=Companion/src Companion/.venv/bin/python -m hermex_companion
```

The process uses:

- `$XDG_CONFIG_HOME/hermex-companion/` for host-local configuration;
- `$XDG_STATE_HOME/hermex-companion/companion.sqlite3` for the device registry;
- `$XDG_DATA_HOME/hermex-companion/releases/` for installed releases.

If an XDG variable is unset, choose its normal absolute path for the service
account before following the deployment steps. Do not put owner-local paths,
user/group names, or secrets in git.

## Install a release on the Hermes Agent host with systemd

The following placeholders mean absolute paths owned by the dedicated service
account:

- `<config-home>` — its XDG config home;
- `<state-home>` — its XDG state home;
- `<data-home>` — its XDG data home;
- `<release-id>` — the full git commit being installed.

From a clean checkout at the selected commit:

```bash
install -d "<data-home>/hermex-companion/releases/<release-id>"
git archive --format=tar HEAD Companion \
  | tar -xf - -C "<data-home>/hermex-companion/releases/<release-id>"
uv sync --frozen \
  --project "<data-home>/hermex-companion/releases/<release-id>/Companion"
ln -sfn \
  "<data-home>/hermex-companion/releases/<release-id>" \
  "<data-home>/hermex-companion/current"
```

Create owner-only configuration:

```bash
install -d -m 0700 "<config-home>/hermex-companion"
install -d -m 0700 "<state-home>/hermex-companion"
install -m 0600 \
  Companion/deploy/hermex-companion.env.example \
  "<config-home>/hermex-companion/hermex-companion.env"
```

Edit that environment file locally and replace only
`HERMEX_COMPANION_GATEWAY_KEY` with the existing Hermes Agent API Server key.
Do not paste the key into a shell command, ticket, chat, log, or screenshot.

Create `<config-home>/hermex-companion/workspaces.json` with only the folders
the App may see. The paths are chosen on the Hermes Agent host, not in the App:

```json
{
  "agent_working_directory": "/srv/hermes/workspace",
  "roots": [
    {
      "id": "projects",
      "name": "Projects",
      "path": "/srv/hermes/workspace/projects",
      "writable": true
    },
    {
      "id": "archive",
      "name": "Archive",
      "path": "/srv/archive",
      "writable": false
    }
  ],
  "memory": {
    "directory": "/srv/hermes/profile/memories",
    "memory_char_limit": 2200,
    "user_char_limit": 1375
  }
}
```

All configured directories must already exist. The App can browse aliases and
choose subdirectories, but cannot add roots. Only writable roots inside
`agent_working_directory` can supply chat attachments. The `memory` block is
optional and enables only built-in `MEMORY.md` and `USER.md`.

Render the unit with the real service identity and XDG paths:

```bash
python3 Companion/deploy/render_systemd.py \
  --service-user "<service-user>" \
  --service-group "<service-group>" \
  --config-home "<config-home>" \
  --state-home "<state-home>" \
  --data-home "<data-home>" \
  --companion-dir "<data-home>/hermex-companion/current/Companion" \
  --host-config "<config-home>/hermex-companion/workspaces.json" \
  | sudo tee /etc/systemd/system/hermex-companion.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now hermex-companion.service
```

The unit starts after network-online and, when that unit name exists, after
`hermes-gateway.service`; it deliberately does not require Gateway. Companion
therefore remains available and reports a degraded Gateway state during a
Gateway restart. The renderer derives systemd `ReadWritePaths` only from
writable roots and the built-in Memory directory in the same host
configuration.

Verify bounded local liveness:

```bash
curl --fail --silent --show-error \
  http://127.0.0.1:8643/companion/v1/health
```

## HTTPS exposure

Keep both Hermes Gateway (`127.0.0.1:8642`) and Companion
(`127.0.0.1:8643`) on loopback.

- Primary: configure Lucky to terminate a system-trusted HTTPS certificate and
  proxy the public Companion hostname only to `http://127.0.0.1:8643`.
- Alternative: use Tailscale Serve or a valid tailnet certificate to expose
  Companion over HTTPS.

Never proxy the Gateway listener, disable iOS certificate validation, or put a
credential in a URL/query string.

## Pair an iPhone or iPad

Run the CLI as the same service account with the same `XDG_STATE_HOME` used by
systemd:

```bash
XDG_STATE_HOME="<state-home>" \
PYTHONPATH="<data-home>/hermex-companion/current/Companion/src" \
"<data-home>/hermex-companion/current/Companion/.venv/bin/python" \
  -m hermex_companion pairing create --expires-in 300
```

The command prints one short-lived secret. In the App, enter the public HTTPS
Companion URL, a device name is supplied by iOS, and enter that secret once.
The App stores the returned device credential in Keychain; it never receives
the Gateway key.

## Upgrade and rollback

Install each commit into a new immutable release directory, update the
`current` symlink, and restart:

```bash
sudo systemctl restart hermex-companion.service
```

Rollback points `current` to a previously tested release and restarts the
service. Do not delete the state directory: the SQLite device registry is
shared across releases and preserves pairing/revocation history.
