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
   `site/deploy/files/bootstrap.sh` on a fresh host: creates `SERVICE_USER=beaut`,
   authorizes your public key, installs the root-owned copy of the scripts, writes
   the root config from the schema with the service-user paths, and grants
   passwordless sudo to `SERVICE_USER`. Later deploys refresh that root copy in
   place (`site/deploy/files/install_privileged.sh`).
2. **User (`--no-root`)**: connect as **`SERVICE_USER`** with the key only and
   install under `$HOME/.beaut`; no sudo, no WireGuard, service started through
   user systemd / `setsid`.

`/node` is rendered **on the server** from the uploaded `site/scripts/node.sh` and
the deployed address: the client never uploads a prebuilt node artifact, and
`curl … /node | sh` still works with zero client files.

Everything after bootstrap runs as **`SERVICE_USER`**, key-only (no password),
inside `$HOME/.beaut`: `site/` (the published tree, including its builtins),
`state/`, plus the hidden personal tree. The start phase is
`site/deploy/files/remote_install.sh`, run over SSH.

Privileged steps (WireGuard, network) run through the passwordless sudo grant of
`SERVICE_USER` (`/etc/sudoers.d/<SERVICE_USER>`, validated with `visudo`). The
`--no-root` mode skips the sudo grant entirely.

## Configuration

All defaults live in `config.env.example`, which doubles as the fallback schema;
`config.env` overrides it. Files are sourced with `set -a`, so every variable is
exported automatically — no export list to maintain.

- `SERVICE_USER`, `BOOTSTRAP_USER`, `SSH_PRIVATE_KEY`: identity and first connection
- `SERVICE_ROOT`, `STATE_DIR`, `PUBLISHED_ROOT` (`SITE`/`DB_DIR` aliases): layout and served tree
- `SERVER_HOST` / `HTTP_PORT`: control server address
- `WG_PORT` / `WG_NETWORK` / `WG_SERVER_IP`: WireGuard
- `DEVICE_DIRECTORY` / `DEVICE_REGISTRY`, `DEVICE_IDENTITY_DIRECTORY`: device identity
- `INVITE_DIRECTORY` / `INVITE_REGISTRY`, `INVITE_DEFAULT_USES`, `INVITE_TTL_SECONDS`: invites
- `SVR_MODE`, `SVR`, `SVR_SECRET`, `SVR_DIR`, `SVR_ROOT`, `SVR_PATH_FILE`, `SVR_DIR_FILE`: hidden personal tree
- `JOURNAL_DIR`, `JOURNAL_ROOT`, `PERSO_DIR`, `PERSO_ROOT`, `JOURNAL_REMOTE`, `PERSO_REMOTE`, `JOURNAL_GIT`, `JOURNAL_EDITOR`, `SVR_BIN_DIR`, `SVR_INSTALL_PATH`: journal and install
- `TOKEN_TTL_SECONDS`: token lifetime
- `NOT_FOUND_BODY`, `ARCHIVE_MEMORY_DIVISOR`, `LOG_LEVEL`

`config.env` is git-ignored (never commit local configuration).

## HTTP server

Listener chain: `socat` (preferred) → small C relay compiled from
`site/scripts/http_server.c` (gcc) → fail. `site/scripts/http_server.sh` picks
the first available listener and launches
`site/scripts/http_server.c <HTTP_PORT> <handler>`.

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
| `GET /<hidden>/...` | hidden personal tree (`SVR_MODE` path), including `journal/` |
| `GET /<path>` | `PUBLISHED_ROOT` tree: file, `index.html`, or `DEFAU*.sh` |

The static route mirrors the tree: `/a/b/c` serves `$PUBLISHED_ROOT/a/b/c`; a
directory serves `index.html`/`index.htm` when present, otherwise its first
`DEFAU*.sh` (`/hello` → `$PUBLISHED_ROOT/hello/DEFAU*.sh`), and finally a
generated folder listing. Content type follows
the extension (HTML, CSS, JavaScript, JSON, Markdown, images); scripts and
unknown files stay `text/plain`. Dot-prefixed path segments are never served, so
`.git` stays private. Nothing is executed server-side. The hidden tree is
ordinary static files served under the secret prefix from `$SVR_ROOT`.

Text files in the published tree support `{{NAME}}` placeholders, replaced at
serve time from configuration: `SERVER_HOST`, `HTTP_PORT`, `SERVICE_USER`,
`WG_PORT`, `WG_NETWORK`, `WG_SERVER_IP`. The hidden personal tree is served
verbatim.

## Public site tree

The repository's `site/` directory is the source of truth **and** the published
tree. `./deploy.sh` uploads it and swaps it into `$PUBLISHED_ROOT`
(`~/.beaut/site` on the live server). There is no second copy of the builtins:
`site/scripts/` and `site/deploy/` are served at `/scripts/` and `/deploy/`, and
`/node` is generated inside `site/node/` after each sync. The repository root
keeps `scripts` and `deploy` symlinks so local commands keep working.

```
site/
  index.html          -> /                 (text/html)
  style.css           -> /style.css        (text/css)
  hello/DEFAULT.sh    -> /hello            (text/plain, curl /hello | sh)
  scripts/            -> /scripts/         (builtins)
  deploy/             -> /deploy/          (deployment files)
  notes/2026-01-02.md -> /notes/2026-01-02.md (text/markdown)
```

Resolution rules:

- `/a/b/c` serves the file at `$PUBLISHED_ROOT/a/b/c`.
- `/a/b` serves `a/b/index.html` (or `index.htm`) when present, otherwise the
  first `a/b/DEFAU*.sh`, otherwise a generated folder listing. This keeps both
  real pages and script endpoints, and makes `/scripts/` and `/deploy/`
  browsable.
- The journal is not public: it lives inside the hidden tree and is reachable
  only at `/<hidden>/journal/`.
- Text pages can use `{{SERVER_HOST}}`, `{{HTTP_PORT}}` and the other public
  configuration values; they are replaced when the file is served.
- Content type comes from the extension; scripts and unknown files remain
  `text/plain`.
- Dot-prefixed path segments are never served, so `.git`, `.env` and other
  hidden files stay private, even inside a repository checkout.

The sync builds the complete new tree beside the live one and swaps it, so a
failed deploy leaves the previous tree intact and anything removed from `site/`
disappears from the published tree.

A top-level `site/<name>` folder that contains `.git` is treated as a separate
git repository: its origin URL is recorded, the folder is **not** uploaded, and
the server clones it (or fast-forwards an existing checkout) on deploy. It is
served at `/<name>/` like any other tree. The origin must be reachable from the
server (SSH or HTTPS).

The hidden personal tree (`$SVR_ROOT`, URL `/<SVR_MODE path>`) uses the same
file/default rules but is not part of `site/`; it stays personal and is never
deployed from the repository.

## Node

```bash
curl -fsS http://$SERVER_HOST:$HTTP_PORT/node | sh
```

Works on a machine with **zero beaut files**. At deploy time the server renders
`site/node/DEFAULT.sh` from the shipped `site/scripts/node.sh` with
`SERVER_HOST`/`HTTP_PORT` baked in and no sourced files; `site/scripts/node.sh`
stays POSIX `sh` (the artifact is piped into `sh`, which is not bash everywhere).
The node claims a token, fetches the command, runs it locally and POSTs the
result to `/done/<token>`.

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

## Hidden personal tree and journal

`scripts/svr.sh` owns a private tree whose URL prefix is secret and whose
on-disk directory is hidden too:

```bash
scripts/svr.sh init                 # tree + journal/perso git repositories
scripts/svr.sh status               # mode, URL path, roots and remotes
scripts/svr.sh path                 # -> /8randomchars
scripts/svr.sh install              # journal/journal-perso in ~/.local/bin (+PATH)
scripts/svr.sh sync                 # pull and push both journals
scripts/svr.sh remote <url>         # set the journal origin (crash recovery)

journal [subfolder] <name>          # installed reference-compatible command
journal-perso [name]
```

`SVR_DIR` chooses the on-disk directory name. When it is empty, a hidden
`.svr-<8 random>` name is generated once and persisted in `state/svr_dir`
(mode 600). The URL prefix is independent: `SVR_MODE=random` uses eight
lowercase alphanumeric characters persisted in `state/svr_path`; `sha` derives
them from `sha256("beaut-svr:" + SVR_SECRET)`; `plain` uses an explicit `SVR`
value. `svr.sh init` also migrates the historical `$SERVICE_ROOT/svr` tree and
its `diary/` directory to the new layout.

The journal is a port of `~/.svr/usr/bin/journal`:

```
$SVR_ROOT/journal/YYYY/MM/DD/<subfolder>/<name>.md
$SVR_ROOT/journal/<host>/<subfolder>/<name>.md   (hard-link view)
$SVR_ROOT/journal/index.html                     (generated index)
```

Each new file starts with the reference header (YYMMDD, time, user, host,
separator, relative path). `journal` pulls before editing, opens
`JOURNAL_EDITOR` (default `$EDITOR`), then commits and pushes when the folder is
a git repository. `JOURNAL_GIT=0` disables git. `JOURNAL_REMOTE` (or
`svr.sh remote <url>`) sets `origin`; re-run it after a restore to point a
recovered server at the new address. `journal-perso` behaves the same in
`$SVR_ROOT/perso` with the `fouretout` default subfolder.

Nothing in the tree is public: requests outside the secret prefix never reach
it, and dot-prefixed segments such as `.git` are never served. The generated
`index.html` makes `/<hidden>/journal/` browsable.

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
loopback with temporary state. Suites cover tokens, static/hidden trees, public
site sync, device registry, invites, `/signin` + `/door`, journal, WireGuard
peer idempotence and the server-rendered node artifact. See `tests/README.md`.

## Files

- `deploy.sh` — client orchestrator (auto-detected SERVICE_USER → BOOTSTRAP_USER fallback)
- `site/deploy/files/bootstrap.sh` — first application as root
- `site/deploy/files/install_privileged.sh` — refresh the root-owned scripts/config
- `site/deploy/files/sync_site.sh` — swap `site/`, clone/fast-forward git-backed entries
- `site/deploy/files/remote_install.sh` — user phase: systemd unit + server start
- `site/deploy/files/beaut.service` — systemd user service
- `site/deploy/files/start.sh` — server launcher (standalone file, never inline)
- `site/scripts/http_server.sh` — listener chain (socat / C relay)
- `site/scripts/http_server.c` — minimal C TCP relay (socat-enough)
- `site/scripts/http_handler.sh` — routes + trees (dispatch), no execution
- `site/scripts/lib/http.sh` — HTTP responses, redirects, parsing, form, client- `site/scripts/lib/state.sh` — TSV + token helpers
- `site/scripts/node.sh` — self-contained POSIX node script (`| sh`)
- `site/scripts/build_published_node.sh` — renders `/node` with the address baked in
- `site/scripts/network.sh` — WireGuard/firewall/peer-sync command wrapper
- `site/scripts/lib/wireguard.sh` — per-device keys, peer sync, client/server helpers
- `site/scripts/device.sh` — device identity, invites, enrollment, approval CLI
- `site/scripts/lib/devices.sh` — device registry, keys, addresses, trust, door
- `site/scripts/lib/invites.sh` — hashed passMessage invites (uses/TTL/revocation)
- `site/scripts/svr.sh` — hidden tree, git journal and command installer
- `site/scripts/journal_cli.sh` — installed `journal` / `journal-perso` command
- `site/scripts/lib/personal_tree.sh` — hidden directory and secret URL path modes
- `site/scripts/lib/journal.sh` — reference-compatible date tree, host view, git
- `site/scripts/lib/passphrase.sh` — words, random material, passphrases, secrets
- `site/scripts/attribution.sh` — virtual secret/path attribution CLI
- `site/scripts/lib/virtual_path.sh` — passphrase/path/registry algorithm
- `site/scripts/lib/core.sh` — paths/config/log/state helpers
- `scripts`, `deploy` — root symlinks into `site/` for local commands
- `tests/` — isolated test subproject (`tests/run.sh`)
- `state/db.tsv` — tokens, tasks, results
- `site/` — published HTTP tree (`$PUBLISHED_ROOT`)
