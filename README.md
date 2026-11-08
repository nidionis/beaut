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

Works on a machine with **zero beaut files**. At publish time `deploy.sh` renders
`shared/node/DEFAULT.sh` with `SERVER_HOST`/`HTTP_PORT` baked in and no sourced
files, and `scripts/node.sh` is POSIX `sh` (the artifact is piped into `sh`, which
is not bash everywhere). The node claims a token, fetches the command, runs it
locally and POSTs the result to `/done/<token>`.

`/join` is **not published**. WireGuard joining stays a repo command:

```bash
scripts/wireguard_join.sh <server_public_key>
```

## Virtual secrets and paths

`scripts/attribution.sh` is a generic, reusable utility: it attributes a random
virtual path to a resource (secret, key, service, request, dataset, ...). The
path is never created on disk; only the registry under `STATE_DIR` holds the
mapping. Paths are built from a dictionary passphrase plus random hex.

```bash
scripts/attribution.sh create secret wg-server "$(cat "$STATE_DIR/wg_public.key")"
# -> /v/amber-river-frost-quartz-1a2b3c	<secret>
scripts/attribution.sh resolve /v/amber-river-frost-quartz-1a2b3c
scripts/attribution.sh ensure secret wg-server "<new value>"   # reuse identity
scripts/attribution.sh rotate /v/amber-river-frost-quartz-1a2b3c
scripts/attribution.sh list
```

Configuration: `ATTRIBUTION_DIRECTORY`, `ATTRIBUTION_REGISTRY`,
`ATTRIBUTION_WORD_COUNT`, `ATTRIBUTION_SECRET_BYTES`,
`ATTRIBUTION_PATH_NAMESPACE`, `ATTRIBUTION_DICTIONARY` (optional word list).
The utility is independent of WireGuard and of the HTTP router.

## WireGuard

Setup is idempotent: `scripts/lib/wireguard.sh` reuses existing keys and an
already configured `wg0`, so the server public key stays stable across deploys
and joined peers keep working. Firewall chains (`nft` or `iptables`) converge to a
single rule set on every run.

## Tests

```bash
tests/run.sh
```

No root, no WireGuard, no external network: each test starts the C relay on
loopback with temporary state. See `tests/README.md`.

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
- `scripts/node.sh` — self-contained POSIX node script (`| sh`)
- `scripts/build_published_node.sh` — renders `/node` with the address baked in
- `scripts/network.sh` — WireGuard + firewall command wrapper
- `scripts/lib/wireguard.sh` — idempotent WireGuard and firewall helpers
- `scripts/attribution.sh` — virtual secret/path attribution CLI
- `scripts/lib/virtual_path.sh` — passphrase/path/registry algorithm
- `scripts/lib/core.sh` — paths/config/log/state helpers
- `tests/` — isolated test subproject (`tests/run.sh`)
- `state/db.tsv` — tokens, tasks, results
- `shared/` — published HTTP tree
