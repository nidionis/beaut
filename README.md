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
anything locally. On an existing host it first proves that **`SERVICE_USER`**
authenticates with the configured key **and** has passwordless sudo; only a
fresh host falls back to **`BOOTSTRAP_USER`**.

Two install modes:

1. **Privileged (default)**: **`BOOTSTRAP_USER`** (root recommended) applies
   `deploy/files/bootstrap.sh` on a fresh host: creates `SERVICE_USER=beaut`,
   authorizes your public key, installs the root-owned copy of the scripts, writes
   the root config from the schema with the service-user paths, and grants
   passwordless sudo to `SERVICE_USER`. Later deploys refresh that root copy in
   place (`deploy/files/install_privileged.sh`).
2. **User (`--no-root`)**: connect as **`SERVICE_USER`** with the key only and
   install under `$HOME/.beaut`; no sudo, no WireGuard, service started through
   user systemd / `setsid`.

`/node` is rendered **on the server** from the uploaded `scripts/node.sh` and the
deployed address: the client never uploads a prebuilt node artifact, and
`curl … /node | sh` still works with zero client files.

Everything after bootstrap runs as **`SERVICE_USER`**, key-only (no password),
inside `$HOME/.beaut`: `scripts/`, `deploy/`, `state/`, `shared/`, plus the hidden
personal tree. The start phase is `deploy/files/remote_install.sh`, run over SSH.

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
- `DEVICE_DIRECTORY` / `DEVICE_REGISTRY`, `DEVICE_IDENTITY_DIRECTORY`: device identity
- `INVITE_DIRECTORY` / `INVITE_REGISTRY`, `INVITE_DEFAULT_USES`, `INVITE_TTL_SECONDS`: invites
- `SVR_MODE`, `SVR`, `SVR_SECRET`, `SVR_ROOT`, `SVR_PATH_FILE`: hidden personal tree
- `JOURNAL_DIRECTORY`: Markdown journal
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
| `GET /signin` | enrollment instructions |
| `POST /signin` | accepts a device public key; a valid invite auto-accepts |
| `GET /signin/<id>` | device status (`pending` / `approved` / `revoked`) |
| `GET /door` | default server public key, endpoint and WireGuard network |
| `GET /<hidden>/...` | hidden personal tree (`SVR_MODE` path) |
| `GET /<path>` | `PUBLISHED_ROOT` tree (read-only) |

The static route mirrors the tree: `/a/b/c` serves `$PUBLISHED_ROOT/a/b/c`, and a
directory serves its first `DEFAU*.sh` (`/backdoors` →
`$PUBLISHED_ROOT/backdoors/DEFAU*.sh`). Nothing is executed server-side and no
directory listing is generated. The hidden tree is ordinary static files served
under the secret prefix from `$SVR_ROOT`.

## Node

```bash
curl -fsS http://$SERVER_HOST:$HTTP_PORT/node | sh
```

Works on a machine with **zero beaut files**. At deploy time the server renders
`shared/node/DEFAULT.sh` from the uploaded `scripts/node.sh` with
`SERVER_HOST`/`HTTP_PORT` baked in and no sourced files; `scripts/node.sh` stays
POSIX `sh` (the artifact is piped into `sh`, which is not bash everywhere). The
node claims a token, fetches the command, runs it locally and POSTs the result to
`/done/<token>`.

`/join` is **not published**. WireGuard joining stays a repo command:

```bash
scripts/wireguard_join.sh <server_public_key>
# or the device-aware flow:
scripts/device.sh join [passMessage]
```

## Devices and enrollment

Every device has its own WireGuard key pair, generated once and persisted
(`state/wg/device_private.key`); keys are never shared or reused between devices.
The server also owns exactly one device row (`trust=owner`) whose key is stable
across deploys. Legacy `state/wg_private.key` / `wg_public.key` are still honoured.

```bash
# server: create the owner row (also done by deploy.sh)
scripts/device.sh init "$(hostname)"

# server: create an invite; the plaintext passMessage is shown once and only its
# SHA-256 digest is stored
scripts/device.sh invite --trust trusted --uses 1 --ttl 86400 --note family
scripts/device.sh invites

# device: submit its public key (valid invite => approved, otherwise pending)
scripts/device.sh signin '<passMessage>'
scripts/device.sh status
scripts/device.sh join '<passMessage>'   # sign in, fetch /door, configure wg0

# server: manual approval / revocation, then synchronize peers
scripts/device.sh approve <device_id> trusted
scripts/device.sh revoke <device_id>
scripts/device.sh sync-peers
scripts/device.sh list
```

Trust levels are `owner`, `trusted`, `guest`. The oldest approved owner/trusted
server is the default door (`GET /door`), overridable with `DOOR_DEVICE_ID`.
KNOCK stays a manual decision: the HTTP server only records a pending device; it
never approves one by itself.

## Hidden personal tree

`scripts/svr.sh` creates a private static tree with a secret URL prefix:

```bash
scripts/svr.sh init
scripts/svr.sh path                 # -> /8randomchars
scripts/svr.sh journal add "text"   # -> $SVR_ROOT/diary/YYYY-MM-DD.md
scripts/svr.sh journal list [n]
scripts/svr.sh journal show [date]
```

`SVR_MODE=random` (default) uses eight lowercase alphanumeric characters,
persisted in `state/svr_path` with mode 600. `SVR_MODE=sha` derives eight
characters from `sha256("beaut-svr:" + SVR_SECRET)`; `SVR_MODE=plain` uses an
explicit `SVR` value. The tree is ordinary static files under `$SVR_ROOT`; no
listing or manifest is generated, and requests outside the secret prefix never
reach it.

## Virtual secrets and paths

`scripts/attribution.sh` is a generic, reusable utility: it attributes a random
virtual path to a resource (secret, key, service, request, dataset, ...). The
path is never created on disk; only the registry under `STATE_DIR` holds the
mapping. Paths are built from a dictionary passphrase plus random hex.

```bash
scripts/attribution.sh create secret wg-server 'PUBLIC-KEY-VALUE'
# -> /v/amber-river-frost-quartz-1a2b3c	<secret>
scripts/attribution.sh resolve /v/amber-river-frost-quartz-1a2b3c
scripts/attribution.sh ensure secret wg-server '<new value>'   # reuse identity
scripts/attribution.sh ensure service node 'http://host:8080/node'
scripts/attribution.sh ensure request knock-42 'pending'
scripts/attribution.sh ensure wg_net server '10.66.0.1'
scripts/attribution.sh rotate /v/amber-river-frost-quartz-1a2b3c
scripts/attribution.sh list
```

`kind` is free-form (`secret`, `service`, `request`, `wg_net`, ...); `name` is the
stable identity within that kind.

Configuration: `ATTRIBUTION_DIRECTORY`, `ATTRIBUTION_REGISTRY`,
`ATTRIBUTION_WORD_COUNT`, `ATTRIBUTION_SECRET_BYTES`,
`ATTRIBUTION_PATH_NAMESPACE`, `ATTRIBUTION_DICTIONARY` (optional word list).
The utility is independent of WireGuard and of the HTTP router.

## WireGuard

Setup is idempotent: `scripts/lib/wireguard.sh` reuses existing keys and an
already configured `wg0`, so the server public key stays stable across deploys
and joined peers keep working. Keys are per device (`state/wg/device_*.key`, with
legacy `state/wg_*.key` fallback), never shared. Approved non-owner devices are
synchronized from the registry (`sync-peers`) with a `/32` allowed-IP; pending,
revoked and unknown peers are never added, and revoked peers are removed. Firewall
chains (`nft` or `iptables`) converge to a single rule set on every run.

## Tests

```bash
tests/run.sh
```

No root, no WireGuard, no external network: each test starts the C relay on
loopback with temporary state. Suites cover tokens, static/hidden trees, device
registry, invites, `/signin` + `/door`, journal, WireGuard peer idempotence and
the server-rendered node artifact. See `tests/README.md`.

## Files

- `deploy.sh` — client orchestrator (auto-detected SERVICE_USER → BOOTSTRAP_USER fallback)
- `deploy/files/bootstrap.sh` — first application as root
- `deploy/files/install_privileged.sh` — refresh the root-owned scripts/config
- `deploy/files/remote_install.sh` — user phase: systemd unit + server start
- `deploy/files/beaut.service` — systemd user service
- `deploy/files/start.sh` — server launcher (standalone file, never inline)
- `scripts/http_server.sh` — listener chain (socat / C relay)
- `scripts/http_server.c` — minimal C TCP relay (socat-enough)
- `scripts/http_handler.sh` — routes + trees (dispatch), no execution
- `scripts/lib/http.sh` — HTTP responses, parsing, URL-decoded form, client
- `scripts/lib/state.sh` — TSV + token helpers
- `scripts/node.sh` — self-contained POSIX node script (`| sh`)
- `scripts/build_published_node.sh` — renders `/node` with the address baked in
- `scripts/network.sh` — WireGuard/firewall/peer-sync command wrapper
- `scripts/lib/wireguard.sh` — per-device keys, peer sync, client/server helpers
- `scripts/device.sh` — device identity, invites, enrollment, approval CLI
- `scripts/lib/devices.sh` — device registry, keys, addresses, trust, door
- `scripts/lib/invites.sh` — hashed passMessage invites (uses/TTL/revocation)
- `scripts/svr.sh` — hidden personal tree + Markdown journal CLI
- `scripts/lib/personal_tree.sh` — secret path modes and static tree layout
- `scripts/lib/journal.sh` — append-only daily Markdown journal
- `scripts/lib/passphrase.sh` — words, random material, passphrases, secrets
- `scripts/attribution.sh` — virtual secret/path attribution CLI
- `scripts/lib/virtual_path.sh` — passphrase/path/registry algorithm
- `scripts/lib/core.sh` — paths/config/log/state helpers
- `tests/` — isolated test subproject (`tests/run.sh`)
- `state/db.tsv` — tokens, tasks, results
- `shared/` — published HTTP tree
