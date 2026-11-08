# beaut

Minimalist shared-computing platform: a control server that **serves scripts**
and **validates tokens**, plus nodes that fetch them (`curl … | sh`). The server
never runs the work.

## Deployment

```bash
./deploy.sh              # remote: SSH/SFTP to $SERVER_HOST (privileged install)
./deploy.sh --no-root    # remote: user install as SERVICE_USER, no sudo
./deploy.sh --debug      # verbose remote diagnostics
```

`deploy.sh` deploys the minimal server on `$SERVER_HOST` and never installs
anything locally.

Two install modes:

1. **Privileged (default)**: **`BOOTSTRAP_USER`** (root recommended, prompted at
   launch) applies `deploy/files/bootstrap.sh`: creates `SERVICE_USER=beaut`,
   authorizes your public key, installs the root-owned copy of the scripts, writes
   the root config from `config.env.example` + the three root-specific overrides
   (`SERVICE_ROOT`, `STATE_DIR`, `PUBLISHED_ROOT`) and the passwordless sudo grant
   for `SERVICE_USER`.
2. **User (`--no-root`)**: connect as **`SERVICE_USER`** with the key only and
   install under `$HOME/.beaut`; no sudo, no WireGuard, service started through
   user systemd / `setsid`.

Two phases, one identity switch (privileged mode):

1. **`BOOTSTRAP_USER`** (root recommended, prompted at launch) applies
   `deploy/files/bootstrap.sh`: creates `SERVICE_USER=beaut`, authorizes your
   public key, installs the root-owned copy of the scripts, writes the root
   config from `config.env.example` + the three root-specific overrides
   (`SERVICE_ROOT`, `STATE_DIR`, `PUBLISHED_ROOT`) and the sudo grant.
2. Everything else runs as **`SERVICE_USER`**, key-only (no password), inside
   `$HOME/.beaut`: `scripts/`, `deploy/`, `state/`, `shared/`. The start phase is
   `deploy/files/remote_install.sh`, run over SSH.

Privileged steps (WireGuard, network) run through the passwordless sudo grant of
`SERVICE_USER` (`/etc/sudoers.d/<SERVICE_USER>`, validated with `visudo`). The
`--no-root` mode skips the sudo grant entirely.

## Configuration

All defaults live in `config.env.example`, which doubles as the fallback schema;
`config.env` overrides it. Files are sourced with `set -a`, so every variable is
exported automatically — no export list to maintain.

- `SERVICE_USER`, `BOOTSTRAP_USER`, `SSH_PRIVATE_KEY`: identity and first connection
- `SERVICE_ROOT`, `STATE_DIR`, `PUBLISHED_ROOT`: layout and served tree
- `SERVER_HOST` / `HTTP_PORT`: control server address
- `WG_PORT` / `WG_NETWORK` / `WG_SERVER_IP`: WireGuard
- `TOKEN_TTL_SECONDS`: token lifetime
- `NOT_FOUND_BODY`, `ARCHIVE_MEMORY_DIVISOR`, `LOG_LEVEL`

`config.env` is git-ignored (never commit local configuration).

## HTTP server

Listener chain: `socat` (preferred) → small C relay compiled from
`scripts/http_server.c` (gcc) → fail. `scripts/http_server.sh` picks the first
available listener and launches `scripts/http_server.c <HTTP_PORT> <handler>`.

## Routes HTTP

| Route | Role |
|-------|------|
| `GET /work` | creates a token, returns it |
| `GET /work/<token>` | returns the bound command |
| `POST /done/<token>` | records the result bound to the token |
| `POST /get` | dataset request (`key=value&key=value`) |
| `GET /<path>` | `PUBLISHED_ROOT` tree (read-only) |

The static route mirrors the tree: `/a/b/c` serves `$PUBLISHED_ROOT/a/b/c`, and a
directory serves its first `DEFAU*.sh` (`/backdoors` →
`$PUBLISHED_ROOT/backdoors/DEFAU*.sh`). Nothing is executed server-side.

## Node

```bash
curl -fsS http://$SERVER_HOST:$HTTP_PORT/node | sh
```

`scripts/node.sh` claims a token via the `lib/http.sh` client helpers, fetches the
command, runs it locally and POSTs the result to `/done/<token>`.

## Files

- `deploy.sh` — client orchestrator (BOOTSTRAP_USER → SERVICE_USER)
- `deploy/files/bootstrap.sh` — first application as root
- `deploy/files/remote_install.sh` — user phase: systemd unit + server start
- `deploy/files/beaut.service` — systemd user service
- `deploy/files/start.sh` — server launcher (standalone file, never inline)
- `scripts/http_server.sh` — listener chain (socat / C relay)
- `scripts/http_server.c` — minimal C TCP relay (socat-enough)
- `scripts/http_handler.sh` — routes + tree (dispatch), no execution
- `scripts/lib/http.sh` — HTTP responses, parsing, form, client
- `scripts/lib/state.sh` — TSV + token helpers
- `scripts/node.sh` — node script (`| sh`)
- `scripts/network.sh` — WireGuard + firewall (single source)
- `scripts/lib/core.sh` — paths/config/log/state helpers
- `state/db.tsv` — tokens, tasks, results
- `shared/` — published HTTP tree
