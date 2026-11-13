# beaut

A small, self-hosted fabric for moving packages, routing domain/path traffic and
keeping persistent Docker sessions on worker machines. It is intentionally a
V1: Bash on the control and data plane, `socat` for sockets, `jq` for JSON and
the Docker CLI for sessions. No Python and no database.

## What it does

- **Hub** — one HTTP listener that accepts packages, exposes an API, proxies
  configured domains/paths to workers and serves a small dashboard.
- **Workers** — HTTP listeners that store replicated package chunks and run
  Docker sessions.
- **Content-addressed store** — every file is split into chunks. Package and
  chunk names are SHA-256 hashes, so duplicate content is stored once.
- **Two copies by default** — an upload is copied to the hub and then pushed to
  workers until `BEAUT_MIN_COPIES` copies exist. Strict mode rejects an upload
  that cannot reach the target.
- **HTTP routes** — `domain + path prefix -> worker:port`, resolved by the hub
  without a database.
- **Raw TCP routes** — the `beaut router` process keeps `socat` listeners that
  forward arbitrary streams to a worker port.
- **Persistent sessions** — Docker containers are named and tracked; a
  snapshot is committed/saved and stored as a replicated package. A session
  can be stopped, started again, restored on another worker, or removed.
- **Installation** — `sudo ./scripts/bootstrap-node.sh` prepares the service
  account, SSH keys and sudo on a new node. `beaut install` (alias `beaut
  deploy`) then writes the config and starts systemd units (or a detached
  process when systemd is not running). Remote targets are uploaded over SFTP
  and installed through SSH; a target that resolves to this machine is
  installed directly from the checkout, without SSH.

## Requirements

Control and worker nodes need:

- Bash 4.2+, `socat`, `jq`, `curl`, `tar`, `gzip`
- Docker on workers that run sessions
- Remote installation: OpenSSH `ssh`/`sftp` with port/key from
  `~/.ssh/config`, plus passwordless sudo for the installation account
- Local installation: root or sudo on this machine (the `beaut` account is
  still required)
- Optional: `systemd` for service management

The hub and worker listeners are plain HTTP and have no authentication. Run
them on a trusted network or put a TLS/authenticating reverse proxy in front of
the hub.

## Quick start from a checkout

```bash
cp beaut.conf.example beaut.conf
$EDITOR beaut.conf
./beaut.sh doctor
./beaut.sh hub serve
```

In another terminal, for a worker on the same machine:

```bash
BEAUT_CONFIG=./beaut.conf ./beaut.sh worker serve
```

The default config uses repo-local `state/` and `store/` directories so a test
checkout does not need root. `scripts/install.sh` appends the installed
`/var/lib/beaut` paths when the tree is deployed. Local `hub serve` /
`worker serve` are development commands. `beaut install` is privileged:
targets that resolve to this machine are installed directly from the checkout
and use `sudo`, while other targets go through SSH/SFTP.

The dashboard is at `http://127.0.0.1:8080/`; health is `/health` and the API
starts at `/info`.

## Configuration

`beaut.conf` in the repository root is the operator-edited file. It is sourced
as Bash and is git-ignored because it may contain SSH key paths. `beaut.sh init`
copies `beaut.conf.example` into place.

Protected defaults live in `etc/beaut.defaults.conf`: names, layout,
listener ports, chunk/copy limits, HTTP status codes and reasons, package
kinds, route modes and session prefixes. The runtime loads that file first and
then the operator config, so `beaut.conf` should contain only deployment
overrides. Do not edit the defaults file to customize a deployment.

Important fields:

```bash
BEAUT_NAME="beaut"          # service account and default installation login
BEAUT_HUB_NAME="hub1"
BEAUT_HUB_BIND="0.0.0.0"
BEAUT_HUB_PORT=8080
BEAUT_HUB_URL="http://hub.example.com:8080"
BEAUT_PUBLIC_URL="https://hub.example.com"   # what workers use to upload

# name | host | port | preferred hub | weight
BEAUT_WORKERS=(
  "w1|192.168.1.10|8090|hub1|100"
  "w2|192.168.1.11|8090|hub1|50"
)

# name | host | path | worker | worker_port | http|tcp | hub | tcp_listen
BEAUT_ROUTES=(
  "app1|app.example.com|/|w1|8080|http|hub1|"
  "ssh1|ssh.example.com|/|w1|2222|tcp|hub1|22022"
)
```

Remote installation logs in as `BEAUT_NAME` (`beaut`), using the port and key
from `~/.ssh/config`, and needs passwordless sudo for that account. Local
installation runs in place as root through `sudo`. Both require the `beaut`
account; run `sudo ./scripts/bootstrap-node.sh` once to create it, authorize
your SSH keys, grant sudo and add Docker access. There are no password
settings.

Worker capacity is declared in the operator config or per worker and exposed
through `/info`:

```bash
BEAUT_WORKER_CPUS=8
BEAUT_WORKER_MEMORY_MB=16384
BEAUT_WORKER_DISK_MB=500000
BEAUT_WORKER_TAGS="cpu,ssd"
BEAUT_WORKER_MAX_SESSIONS=4

# Optional per-worker deployment overrides.
BEAUT_WORKER_w1_CPUS=16
BEAUT_WORKER_w1_MAX_SESSIONS=8
```

`beaut worker resources --cpus 8 --memory 16384 --tags cpu,ssd --write` edits
those lines for you.

## CLI

The CLI is a thin front end over two transports:

- **SSH/SFTP or a local sudo** for installation (`beaut install ...`). A
  target that is this machine runs the installer directly; other targets move
  files over SFTP and run the installer through SSH. Remote access uses only
  key/agent authentication.
- **HTTP** for packages, routes, Docker sessions and diagnostics. It calls
  `BEAUT_HUB_URL` first, so commands work from any machine that can reach the
  hub. Local state is only a fallback when the hub is unreachable.

```text
beaut install hub|worker NAME|all      # alias: deploy
beaut hub serve
beaut worker serve
beaut router run|sync|stop

beaut package add FILE [--name N] [--kind K] [--copies N] [--allow-degraded]
beaut package ls [--json] | show ID
beaut package get ID OUT
beaut package replicate|verify|scrub|stats
beaut route add NAME HOST PATH WORKER PORT [http|tcp] [HUB] [LISTEN_PORT]
beaut route ls|find|rm|sync
beaut session create NAME IMAGE [--worker W] [--port N] [--protocol P] [--command CMD]...
beaut session ls|show|stop|start|snapshot|restore|move|exec|rm
beaut workers [--json]
beaut status
beaut doctor
beaut help api
beaut config path|show|edit
```

Examples:

```bash
# Install the hub and workers.  Local targets run in place; remote targets are
# uploaded over SFTP and installed through SSH.
./beaut.sh install hub
./beaut.sh install worker w1
./beaut.sh install all

# Store a file twice (hub + first eligible worker).
beaut package add ./image.tar --kind oci-image --copies 2

# Point app.example.com at worker w1 port 8080.
beaut route add app1 app.example.com / w1 8080 http hub1

# Forward public TCP port 22022 to worker w1 port 2222.
beaut route add ssh1 '*' / w1 2222 tcp hub1 22022
beaut router sync

# Persistent Alpine session and command execution through the hub API.
beaut session create demo alpine:3 --worker w1 --port 8080 --command sleep --command infinity
beaut session exec s_... -- uname -a
beaut session snapshot s_...
beaut session restore s_... --worker w2
beaut session rm s_...
```

A running session is reachable through the hub at
`http://<hub>/s/<session-id>/...`. `beaut help api` prints the endpoint map,
including the HTTP requests used for Docker lifecycle and package uploads, so
scripts do not need to invent ad-hoc command lines or addresses.

All hub addresses come from `beaut.conf` (`BEAUT_HUB_URL`). The CLI has no
hard-coded hub or worker address.

## HTTP API

| Method | Path | Meaning |
| --- | --- | --- |
| GET | `/health` | liveness |
| GET | `/info` | role, version, store/session/route summary |
| GET | `/workers` | configured workers with live capacity |
| GET/POST | `/routes` | list or add routes |
| GET | `/routes/find?host=H&path=P` | resolve the best route |
| DELETE | `/routes/NAME` | remove a route |
| GET | `/packages` | package manifests |
| PUT | `/packages?name=N&kind=K&copies=C` | upload a package body |
| GET | `/packages/ID` | manifest |
| GET | `/packages/ID/download` | reconstructed bytes |
| POST | `/packages/ID/replicate` | retry replication |
| POST | `/packages/ID/verify?full=1` | verify chunks or the whole package |
| GET | `/store/stats` | package/object/byte counts |
| POST | `/store/scrub` | verify every package |
| GET/POST | `/sessions` | list or create sessions |
| GET/DELETE | `/sessions/ID` | show or remove a session |
| POST | `/sessions/ID/stop|start|snapshot|restore|move` | lifecycle |
| POST | `/sessions/ID/exec` | run a command in the container |
| GET | `/sessions/ID/status` | live Docker status |
| GET | `/s/ID/...` | proxy to a running session |

Worker endpoints mirror the store (`/store/...`) and session lifecycle and
are normally reached only by the hub.

## Package model

```text
$BEAUT_STORE_DIR/objects/<first2>/<sha256>   chunk objects
$BEAUT_STORE_DIR/packages/<sha256>.json      manifests
$BEAUT_STORE_DIR/tmp/                        scratch
```

A manifest records the whole-file hash, chunk list, size, kind, required copy
count and the names of nodes that hold a copy. Replication bundles a manifest
plus its chunks as a gzip tar, posts it to a worker, and the worker verifies
every chunk and the complete file hash before accepting it. `package scrub`
re-hashes the local store.

Package kinds: `data`, `resource`, `oci-image`, `session-image`,
`session-state`, `web-cache`, `artifact`, `manifest`.

## Sessions

Each session maps to a container named `beaut-<session-id>` by default (the
prefix is `BEAUT_SESSION_CONTAINER_PREFIX` in the protected defaults) on one
worker. The worker records the container metadata in its state directory.
`session exec` runs a command inside the container through the hub (`POST
/sessions/ID/exec`) and returns its output plus exit status. `snapshot`
performs `docker commit` + `docker save`, uploads the image to the hub as a
`session-image` package, and the hub replicates it. `restore` downloads the
snapshot and loads it on the target worker, recreating the container if needed.
Stopping with `BEAUT_SESSION_SNAPSHOT_ON_STOP=1` snapshots first.

This is intentionally a coarse persistence model. Live memory/process state is
not migrated; the container filesystem is.

## Installation

`beaut install` (also available as `beaut deploy`) handles local and remote
nodes. The hub destination is the host in `BEAUT_HUB_URL`; each worker
destination is its host in `BEAUT_WORKERS`. When the destination resolves to
this machine, the installer runs in place from the checkout through `sudo`.
Otherwise the source tree is packed, uploaded with SFTP, installed through SSH
as `beaut@host` using the port and key from `~/.ssh/config`, and the temporary
files are removed afterwards. Remote passwords are not supported.

On a new node, run the bootstrap script once as root:

```bash
sudo ./scripts/bootstrap-node.sh
```

It creates the `beaut` account, authorizes the invoking user's `~/.ssh/*.pub`
keys, grants passwordless sudo and adds the account to `docker`. It is
idempotent. Run it on this machine too before a local install. Then install
from the control machine:

```bash
# Configure the hub and worker addresses in beaut.conf first.
$EDITOR beaut.conf

# Remote hub and all configured workers.
./beaut.sh install hub
./beaut.sh install all

# One worker by name from BEAUT_WORKERS.
./beaut.sh install worker w1
```

The installer writes:

- `/etc/beaut/beaut.conf`, `/var/lib/beaut/{state,store}`, `/var/log/beaut`
- the runtime tree, including `etc/beaut.defaults.conf`, under
  `/usr/local/lib/beaut`
- `beaut-hub.service`, `beaut-worker.service`, `beaut-router.service`
- `/usr/local/bin/beaut` pointing at the installed tree

Set `BEAUT_INSTALL_DEPS=1` (default) to install `socat jq curl tar gzip` with the
distribution package manager, and `BEAUT_INSTALL_DOCKER=1` to install Docker on
worker nodes.

The deployed config is mode 600 and owned by `beaut`. The hub config (worker
addresses and routes) is uploaded only to the hub; generated worker configs
contain no SSH or sudo settings. The installer never sets an account password.

## Tests

The integration suite needs `socat`, `jq`, `curl`, `tar`, `nc`-free TCP checks
(via Bash `/dev/tcp`) and runs entirely in a temporary directory. It uses
`tests/fake-docker.sh`, so no Docker daemon is required:

```bash
bash tests/run.sh
# keep logs and state on failure:
BEAUT_TEST_KEEP=1 bash tests/run.sh
```

The suite covers health/info, two-copy package upload and download, CLI
verify/get/scrub, strict copy enforcement, HTTP route proxying and route find,
raw TCP routing, session create/proxy/snapshot/restore/stop/start/exec/delete,
API-first status/workers/package/route reports, help output, and diagnostics.

## V1 limitations

- HTTP routing is request/response (no WebSocket upgrade); use a TCP route for
  protocols that need a raw stream.
- The store has no garbage collection or retention policy yet.
- The hub API has no authentication or TLS; place it behind a trusted network
  or reverse proxy.
- Session migration preserves the filesystem image, not live memory.
- Worker selection is configuration-driven (preferred hub + capacity), not a
  consensus scheduler.
- Metrics are exposed as JSON summaries, not Prometheus counters.
