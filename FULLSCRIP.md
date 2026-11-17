# FULLSCRIP.md

Implementation specification for the next `beaut` version: a small hub/worker
fabric that deploys containers, reports resources, keeps snapshots and survives
worker loss.

This document is the contract. It is intentionally explicit so the code can
stay small.

## 0. Locked decisions

| Topic | Decision |
| --- | --- |
| Hub | Remote `$HUB`, reached over WireGuard |
| Public ingress | External; beaut does not run a public relay |
| Admin account | `${NAME:-master}`, which is `beaut` here |
| Worker account | `worker`, separate from the admin sudoer |
| Worker identity | Address + short hash of its public key |
| Addresses | Explicit in config; never assume localhost |
| Config | `conf/` tree; no hard-coded install or network values |
| Services | `services/` templates, installed by deploy |
| Deploy | Separate hub and worker scripts; compressed `tar | ssh` |
| Worker control | Worker pulls work from hub with `curl | sh` |
| Container source | A folder such as `context/MarkdownWebsite` |
| Scheduling | `SCHEDULING_PRIO=(cpu ram disk)`, lazy tie-break |
| Death | No heartbeat for `DEATH_TIME=10` seconds |
| Backups | Every `BACKUP_DELAY=60` seconds to a sticky backup worker |
| Next hub | `NEXT_CHIEF=2` preferred successors |
| Git | Separate repositories for site, state and logs |
| Packages | Debian only for automatic installation |
| Shell style | Bash Bible where it genuinely simplifies the code |

## 1. Topology

```text
                     external TLS ingress
                              |
                              v
                    +--------- hub ---------+
                    | main HTTP :PORT        |
                    | work HTTP :WORK_PORT   |
                    | state + snapshots      |
                    | site/state/log repos   |
                    +-----------+------------+
                                |
                         WireGuard 10.66.0.0/24
                     /          |          \
                worker       worker      worker
             dockerd      dockerd      dockerd
             reports      snapshots    snapshots
```

The hub is authoritative for scheduling. Workers may keep running when the hub
is unavailable and must keep their latest local snapshot. A later layer adds a
second hub and repository replication.

The public web service points at the hub's main HTTP port through the existing
external ingress. Workers and administrative traffic use WireGuard addresses.

## 2. Filesystem layout

Repository:

```text
beaut/
  beaut                         CLI, the only general argument parser
  FULLSCRIP.md
  bin/
    first-conn.sh               first connection, users and keys
    deploy-hub.sh               install/update the hub
    deploy-worker.sh            install/update one worker
    beaut-hub                   hub main listener
    beaut-work                  hub work listener
    beaut-worker                worker loop
    beaut-hub-http              one main HTTP request
    beaut-work-http             one work HTTP request
    beaut-worker-http           one worker HTTP request
  conf/
    conf.env.example            shared, user-edited basics
    node.env                    generated per node, mode 0600
    workers/<hash>.env          generated worker inventory, hub only
    keys/                       generated node keys, mode 0600
  containers/                   container project folders
  lib/
    bootstrap.sh                locate tree, source config and modules
    common.sh                   logging, validation, small helpers
    config.sh                   conf.env, node.env, defaults
    http.sh                     request/response and listeners
    router.sh                   folder-tree route resolution
    hub.sh                      hub endpoints and state
    worker.sh                   worker endpoints and loop
    scheduler.sh                placement, backup target, succession
    resources.sh                local resource probe
    snapshots.sh                archive, send, receive, restore
    status.sh                   CLI status client
    doctor.sh                   diagnostics
  services/
    hub.service
    work.service
    worker.service
  share/
    awk/kv.awk                  key=value extractor
    awk/resources.awk
    awk/status.awk
    jq/
    systems/
  site/                         main hub routes
    health
    status
    report
    heartbeat
    snapshot
    index
  work/                         work-port routes
    script.sh
  tests/
    smoke.sh
    fixtures/
  deploy.sh                     optional thin wrapper
```

Installed tree:

```text
$ROOT/
  app/                          deployed source tree
  conf/
    conf.env
    node.env
    workers/
    keys/
  containers/                   cached container bundles
  site/                         live main routes
  work/                         live work routes
  state/                        JSON records
  logs/                         text logs
  snapshots/                    local snapshot archives
  repos/                        bare Git repositories
```

`$ROOT` defaults to `$HOME/.beaut`. Every script derives it from config, never
from a hard-coded path.

## 3. Users and trust

Two accounts are created on every node:

- `${ADMIN_USER:-${NAME:-master}}` — sudoer/admin. With `NAME=beaut`, this is
  `beaut`. It owns deployment and repairs.
- `worker` — runs the worker loop and Docker. It has only the privileges needed
  for `/work`, reports and snapshots.

The first connection is the only bootstrap exception:

```text
bin/first-conn.sh ROLE TARGET SUDO_USER [PASSWORD]
```

- `ROLE` is `hub` or `worker`.
- `TARGET` is the explicit address.
- `SUDO_USER` is the initial account that can sudo.
- `PASSWORD` is optional; when present, `sshpass` is used. It is never written
  to disk. Prefer keys.

`first-conn.sh` performs these steps on the target:

1. Verify SSH and sudo access.
2. Create `$ADMIN_USER` if missing; add it to `sudo` on Debian or `wheel` on
   Fedora; copy the installer public key into its `authorized_keys`.
3. Create `$WORKER_USER` if missing.
4. Install the project under `$ROOT/app`.
5. Create the runtime directories under `$ROOT`.
6. Install the appropriate public keys:
   - hub accepts the installer/admin key;
   - workers accept the hub key;
   - hub accepts worker keys for worker reports.
7. Print the next command: `bin/deploy-hub.sh` or `bin/deploy-worker.sh`.

Docker access:

```text
worker ALL=(root) NOPASSWD: /usr/bin/docker
worker ALL=(root) NOPASSWD: /usr/bin/apt-get
```

Docker is effectively root. The worker account is deliberately allowed to run
Docker, but nothing else. Package installation is allowlisted to `apt-get` on
Debian. Fedora is supported for development and deployment, but automatic
package installation is Debian-only.

## 4. Network and WireGuard

All internal addresses are explicit:

```bash
HUB="10.66.0.1"
WG_INTERFACE="wg0"
WG_PORT="51820"
WG_NETWORK="10.66.0.0/24"
```

- Hub WireGuard address: `10.66.0.1`.
- Workers: `10.66.0.2`, `10.66.0.3`, and so on, assigned in `node.env`.
-`HUB` is the WireGuard address used by workers.
- No service uses `127.0.0.1` or `localhost`.
- The external ingress reaches the hub's main HTTP port over the existing
  public path. WireGuard is for worker traffic and administration.

WireGuard is generated by `first-conn.sh` when `ENABLE_WIREGUARD=yes`:

```text
$ROOT/conf/wireguard/
  hub.conf
  hub.key
  hub.pub
  peers/<hash>.conf
  peers/<hash>.key
  peers/<hash>.pub
```

`wg-quick` is used. Private keys are mode `0600`. If WireGuard setup is not
available, the same explicit addresses may be routed by another private
network; the rest of the configuration does not change.

## 5. Configuration

`conf/conf.env` is the only user-edited file. It is sourced first.

```bash
# identity
NAME="beaut"
ADMIN_USER="${ADMIN_USER:-${NAME:-master}}"
WORKER_USER="${WORKER_USER:-worker}"

# hub and public access
HUB="10.66.0.1"
HUB_PUBLIC="hub.example.net"
PUBLIC_URL="https://beaut.example.net"

# ports
PORT="8081"
WORK_PORT="8090"
WORKER_PORT="8091"

# timing (seconds)
REPORT_DELAY="60"
HEARTBEAT_DELAY="5"
BACKUP_DELAY="60"
DEATH_TIME="10"
STATE_COMMIT_DELAY="300"

# placement
SCHEDULING_PRIO=(cpu ram disk)
MIN_CPU="1"
MIN_RAM_KB="262144"
MIN_DISK_KB="1048576"
NEXT_CHIEF="2"

# backup retention
RETAIN_SNAPSHOTS="7"

# paths
ROOT="${ROOT:-$HOME/.beaut}"
APP_DIR="$ROOT/app"
STATE_DIR="$ROOT/state"
LOG_DIR="$ROOT/logs"
SITE_DIR="$ROOT/site"
WORK_DIR="$ROOT/work"
CONTAINER_DIR="$ROOT/containers"
SNAPSHOT_DIR="$ROOT/snapshots"
REPO_DIR="$ROOT/repos"

# wireguard
ENABLE_WIREGUARD="yes"
WG_INTERFACE="wg0"
WG_PORT="51820"
WG_NETWORK="10.66.0.0/24"

# git repositories, separate by design
SITE_REPO="$REPO_DIR/site.git"
STATE_REPO="$REPO_DIR/state.git"
LOGS_REPO="$REPO_DIR/logs.git"

# packages
PKG_MANAGER="apt-get"
```

`conf/node.env` is generated and must not be edited by hand. It is sourced
after `conf.env` and wins for local values:

```bash
NODE_ROLE="worker"
NODE_ADDRESS="10.66.0.2"
NODE_HASH="a1b2c3d4e5f60718"
HUB="10.66.0.1"
WORKER_PORT="8091"
```

Hub-side worker inventory is one file per identity:

```text
conf/workers/<hash>.env
```

```bash
WORKER_ADDRESS="10.66.0.2"
WORKER_PORT="8091"
WORKER_PUBLIC_KEY="ssh-ed25519 AAAA..."
WORKER_HASH="a1b2c3d4e5f60718"
WORKER_LAST_SEEN="2026-11-17T12:00:00Z"
```

Rules:

- Never hard-code a host, port, path, delay, user or repository.
- Source configuration at the top of every script.
- `conf/conf.env` may be tracked as an example; the live file is local.
- `conf/node.env`, `conf/workers/` and `conf/keys/` are generated and local.

## 6. Identity

A worker is identified by:

```text
address + ":" + port + " " + hash(public key)
```

The hash is the first 16 lowercase hex characters of the SHA-256 fingerprint of
the worker's SSH public key:

```bash
worker_hash() {
  local key="$1"
  ssh-keygen -lf "$key" -E sha256 |
    awk '{ print substr($2, 8, 16) }'
}
```

No human name is required. Status rows use the address and hash. A worker may
have a comment in its key, but it is not an identity.

## 7. Deployment

Both scripts are argument-free and source `conf/conf.env` at the top.

### `bin/deploy-hub.sh`

1. Read `HUB`, `ROOT`, `APP_DIR` and service paths from config.
2. Pack the repository, excluding `.git`, `context`, `conf/conf.env`, state,
   logs and snapshots.
3. Stream the archive to `$HUB` as `$ADMIN_USER`.
4. Extract into `$APP_DIR`.
5. Copy `conf/conf.env` separately; never include it in the archive.
6. Render and install `services/hub.service` and `services/work.service`.
7. Stop, enable and restart both units.
8. Wait, verify active state, print journal output on failure.

### `bin/deploy-worker.sh`

1. Read `HUB`, `ROOT`, `NODE_ADDRESS`, `WORKER_PORT` and the service paths.
2. Pack the repository with the same excludes.
3. Stream it to the worker as `$ADMIN_USER`.
4. Extract into `$APP_DIR`.
5. Write `conf/node.env` with mode `0600` and the worker identity.
6. Render and install `services/worker.service`.
7. Restart and verify the unit.

Transport:

```bash
tar -C "$SRC" -czf - --exclude=... . |
  ssh "$ADMIN_USER@$TARGET" "tar -xzf - -C '$APP_DIR'"
```

`rsync` is not required. Compression is automatic in `tar -z`.

Deployment is idempotent: rerunning it replaces code and units but never deletes
`state/`, `logs/`, `snapshots/` or repository data.

## 8. Services

`services/hub.service`:

```ini
[Unit]
Description=beaut hub
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=@APP_DIR@
Environment=BEAUT_CONFIG=@CONFIG@
Environment=BEAUT_ENV=@NODE_ENV@
ExecStart=@APP_DIR@/bin/beaut-hub
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
```

`services/work.service` is the same with `beaut-work` and `Description=beaut work`.

`services/worker.service` is the same with `beaut-worker`.

Templates use `@KEY@` markers and are rendered by `render_template` in
`lib/common.sh`, not by shell heredocs. Deploy installs and refreshes them on
every run. It enables linger when `loginctl` is available.

## 9. HTTP routing

There are two route trees:

- `site/` for the main hub port: pages, status, reports, snapshots.
- `work/` for the work port: scripts that workers execute.

`lib/router.sh` resolves an extensionless path:

```text
/            -> site/index
/health      -> site/health
/status      -> site/status
/report      -> site/report
/work        -> work/script.sh
```

Rules:

- Only extensionless files are routes.
- Reject `..`, `//`, hidden components and unsafe characters.
- A route is a Bash script sourced by the handler with the HTTP helpers loaded.
- A route may return HTML, JSON, plain text or a shell script.
- `HTTP_SENT` prevents a route from sending twice.
- A route that sends nothing becomes a 500.

`lib/http.sh` supports `GET`, `HEAD` and `POST`. `POST` stores the body in a
temporary file and exposes `HTTP_BODY_FILE` and `HTTP_BODY_LEN`. Request and
response sizes are bounded by config.

## 10. Hub endpoints

Main port:

| Route | Method | Response |
| --- | --- | --- |
| `/health` | GET/HEAD | `ok` |
| `/` | GET | HTML status table |
| `/status` | GET | JSON inventory, jobs and snapshots |
| `/report` | POST | worker report accepted |
| `/heartbeat` | POST | lightweight liveness |
| `/snapshot` | PUT/POST | receive a snapshot archive |
| `/container/<hash>.tar.gz` | GET | cached container bundle |

Work port:

| Route | Method | Response |
| --- | --- | --- |
| `/` | GET | shell script selected by `?hash=<worker-hash>` |
| `/work` | GET | alias of `/` |

The work port is intentionally a shell-script endpoint. Only WireGuard peers
may reach it, and the returned script runs as `$WORKER_USER`.

### `site/status`

Returns JSON assembled from `state/workers/*.json` and `state/jobs/*.json`:

```json
{
  "hub": "10.66.0.1",
  "now": "2026-11-17T12:00:00Z",
  "workers": [
    {
      "hash": "a1b2c3d4e5f60718",
      "address": "10.66.0.2",
      "port": 8091,
      "online": true,
      "last_seen": "2026-11-17T11:59:58Z",
      "resources": {
        "cpus": 4,
        "load1": 0.31,
        "mem_available_kb": 3145728,
        "disk_free_kb": 104857600
      },
      "packages": ["docker.io=..."],
      "processes": ["beaut-<job>=running"],
      "snapshots": [
        {
          "job": "9f2c...",
          "path": "10.66.0.3:$ROOT/snapshots/9f2c/20261117T120000.tar.gz",
          "time": "2026-11-17T12:00:00Z"
        }
      ]
    }
  ],
  "jobs": [
    {
      "id": "9f2c...",
      "primary": "a1b2c3d4e5f60718",
      "backup": "b2c3d4e5f60718a1",
      "next": ["b2c3...", "c3d4..."],
      "state": "running",
      "snapshot": "2026-11-17T12:00:00Z"
    }
  ]
}
```

`beaut status` reads `http://$HUB:$PORT/status` and formats the table with
`share/awk/status.awk`.

## 11. Work protocol

Worker loop:

```bash
curl -fsS "http://$HUB:$WORK_PORT/?hash=$NODE_HASH" | sh
```

The hub's `work/script.sh`:

1. Reads and validates `QUERY_hash`.
2. Ensures the worker exists in `conf/workers/`.
3. Chooses a job for the worker or returns `:` when there is no work.
4. Emits an idempotent shell script.

Example emitted script:

```bash
# beaut work: job 9f2c...
set -eu
mkdir -p "$CONTAINER_DIR/9f2c"
curl -fsS "http://$HUB:$PORT/container/9f2c.tar.gz" |
  tar -xzf - -C "$CONTAINER_DIR/9f2c"
cd "$CONTAINER_DIR/9f2c"
sudo docker compose up -d --build
printf '%s\n' '9f2c' >"$STATE_DIR/jobs/9f2c.running"
```

The work endpoint does not require a worker name. The hash is both identity and
lookup key.

An optional per-worker route may exist:

```text
work/<hash>/script.sh
```

If present, it wins over the generic `work/script.sh`. This is useful for
one-off debugging; the generic route remains the normal path.

## 12. Worker runtime loop

`bin/beaut-worker` runs a single loop with independent counters:

```text
every HEARTBEAT_DELAY  -> POST /heartbeat
every REPORT_DELAY     -> POST /report (resources, packages, jobs, snapshots)
every REPORT_DELAY     -> GET /work?hash=... | sh
every BACKUP_DELAY     -> snapshot and send to assigned backup worker
```

Pseudo-code:

```bash
while :; do
  heartbeat
  if (( now >= next_report )); then
    report
    apply_work
    next_report=$(( now + REPORT_DELAY ))
  fi
  if (( now >= next_backup )); then
    snapshot_and_send
    next_backup=$(( now + BACKUP_DELAY ))
  fi
  pause "$HEARTBEAT_DELAY"
done
```

`HEARTBEAT_DELAY=5` and `DEATH_TIME=10` are compatible. The full 60-second
report is not used for liveness; the heartbeat is. This resolves the otherwise
impossible combination of a 60-second report and a 10-second death timeout.

A worker that has no hub keeps its containers running and keeps its latest local
snapshot. It retries the configured hub list. Multi-hub failover is a later
layer; the state and config are already shaped for it.

## 13. Scheduler

Candidate workers must be:

- online: `now - last_seen <= DEATH_TIME`;
- above `MIN_CPU`, `MIN_RAM_KB`, `MIN_DISK_KB`;
- not the dead or excluded worker.

Sort candidates by `SCHEDULING_PRIO` in order. `(cpu ram disk)` compares free
CPU first, then free RAM, then free disk; higher free is better. If all compared
resources are equal, the lowest `load1` wins. That is the "laziest" tie-break.

Backup target:

- Prefer the current backup worker while it is alive and has enough disk.
- Otherwise choose the laziest eligible worker that is not the primary.
- Store the choice in the job state so it remains sticky until unavailable.
- `NEXT_CHIEF=2` produces the next two candidates in sorted order. They are
  reported in `/status` and used when a primary or backup disappears.

No worker name is involved. The state key is the key hash.

## 14. Snapshots and recovery

Worker-side snapshot:

```text
$SNAPSHOT_DIR/<job>/<UTC timestamp>.tar.gz
```

If the container folder contains `snapshot.sh`, it is run and must write a
tar.gz to stdout. Otherwise the default is:

1. `docker compose ps -q` for running containers;
2. `docker export` each container;
3. `docker save` the images referenced by the compose project;
4. tar the compose project volumes and `$CONTAINER_DIR/<job>`.

The archive is sent to the assigned backup worker:

```bash
curl -fsS -X PUT \
  --data-binary "@$archive" \
  "http://$BACKUP_ADDRESS:$WORKER_PORT/snapshot?hash=$NODE_HASH&job=$job"
```

The backup worker verifies the sender hash and writes the archive under its own
`$SNAPSHOT_DIR/incoming/<job>/`. The hub records the location.

Recovery:

1. Hub marks a worker dead after `DEATH_TIME` without a heartbeat.
2. Its jobs are marked `dead` or `restoring`.
3. Scheduler picks the first eligible worker by `SCHEDULING_PRIO`, excluding the
   dead worker and the current backup if it is also unavailable.
4. The new worker fetches the latest snapshot from the recorded backup worker.
5. The work script extracts it, runs `docker compose up -d`, and reports the
   new state.
6. The hub updates primary, backup and `next` list.

`RETAIN_SNAPSHOTS` controls local retention; deletion is explicit and logged.

## 15. Container folders

A container project is an ordinary directory, for example:

```text
context/MarkdownWebsite/
  Dockerfile
  compose.yaml
  .env.example
  ...
```

The hub packs each project as:

```text
containers/<jobhash>.tar.gz
```

`jobhash` is the SHA-256 of the canonical path plus the archive content hash, so
a changed project gets a new identity.

Run order in the work script:

1. Prefer `compose.yaml` or `docker-compose.yml`: `docker compose up -d --build`.
2. Otherwise use `Dockerfile`: `docker build -t "beaut-$job" .`, then run with
   ports and environment from `beaut.env` in the project folder.
3. Write a running marker under `$STATE_DIR/jobs/`.

No container project is allowed to choose an arbitrary host path outside
`$CONTAINER_DIR`; paths are validated by the router and snapshot helpers.

## 16. Package inventory

`/report` includes the installed package list:

```bash
dpkg-query -W -f='${Package}=${Version}\n' 2>/dev/null
```

The hub stores it under `state/packages/<hash>.txt`. A missing package becomes a
task in the work script:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends PACKAGE
```

Only Debian is automated. Fedora nodes report with `rpm -qa` but do not receive
automatic installs.

## 17. Status table

`GET /` renders a table:

```text
address          hash        state   cpu  ram free  disk free  load  jobs  backup
10.66.0.2        a1b2c3...   online  4    2.9 GiB   99 GiB     0.3   1     10.66.0.3
10.66.0.3        b2c3d4...   online  2    1.1 GiB   50 GiB     0.1   0     -
```

Below the table:

- `NEXT_CHIEF` successor list;
- jobs and their snapshot/backup locations;
- last heartbeat and last full report.

`beaut status` uses `$HUB`, never localhost. `beaut status --json` returns the
raw JSON.

## 18. Git repositories

Separate repositories, as requested:

```text
$REPO_DIR/site.git      route scripts and page templates
$REPO_DIR/state.git     small JSON state and job/snapshot records
$REPO_DIR/logs.git      rotated logs
```

Rules:

- `site/` is a Git working tree; deploy pulls it to the hub.
- `state/` is committed by the hub on change or every `STATE_COMMIT_DELAY`;
  workers never commit directly.
- `logs/` is rotated and committed in batches; high-volume container logs stay
  in Docker/journald and are not pushed to Git.
- Snapshot tarballs are never stored in Git. They are artifacts in
  `$SNAPSHOT_DIR` and on the backup worker.
- Container projects may be separate repositories under `containers/`; the hub
  caches their archives.
- The next hub clones the three bare repositories. This is the basis of
  `NEXT_CHIEF` failover, not part of the first running slice.

## 19. Key/value extractor

`share/awk/kv.awk` is required and shared by reports, query parsing and status:

```awk
# Print key<TAB>value for each key=value line.
{
  i = index($0, "=")
  if (i > 1)
    print substr($0, 1, i - 1) "\t" substr($0, i + 1)
}
```

Usage:

```bash
beaut resources --raw | awk -f "$BEAUT_ROOT/share/awk/kv.awk"
```

The script handles values containing `=`; it only splits on the first one.

## 20. Bash style

Follow `context/pure-bash-bible` where it improves the code:

- `#!/usr/bin/env bash`
- `$()` not backticks
- no `function` keyword in Bash
- `[[ ]]` for tests
- `case` for dispatch
- `$(<file)` for reading files
- `${#var}` with `local LC_ALL=C` for byte lengths
- `printf '%(...)T'` for timestamps
- `read -rt` for pauses
- `read -r` and `IFS=` for input
- no heredocs; templates live in files
- source config at the top of every script
- no hard-coded paths, addresses, ports, users or delays
- grow functions around a real use case; avoid wrappers that only forward

Required external tools remain: `socat`, `curl`, `jq`, `ssh`, `awk`, `tar`,
`ssh-keygen`, Docker, WireGuard tools. `sshpass` is only for first connection.

## 21. Testing and acceptance

1. `bash -n` on every shell file.
2. `tests/smoke.sh` with an explicit `TEST_HOST` (no localhost): start hub and
   worker, check `/health`, `/status`, `/work`, `/report`.
3. Verify identities: two workers with different keys have different hashes.
4. Verify deploy idempotence: run `deploy-hub.sh` and `deploy-worker.sh` twice.
5. Verify Docker: deploy `context/MarkdownWebsite`, check the container runs and
   `/status` shows the job.
6. Verify snapshot: force `BACKUP_DELAY=2`, check the archive appears on the
   backup worker and in the snapshot map.
7. Verify death: stop worker heartbeats, confirm `DEATH_TIME` marks it dead and
   the scheduler proposes a replacement.
8. Verify public ingress: `PUBLIC_URL/health`, `/status`, `/hello/world`.
9. Use w0/w2 when reachable; otherwise use hub + w1 and a mock worker.

## 22. Implementation order

1. `lib/bootstrap.sh`, `lib/common.sh`, `lib/config.sh`, `lib/http.sh`,
   `lib/router.sh`.
2. `bin/first-conn.sh` and key/user bootstrap.
3. `bin/deploy-hub.sh`, `bin/deploy-worker.sh`, `services/`.
4. Main hub routes and status table.
5. Worker loop, heartbeat, report, package inventory.
6. Work endpoint, container bundle, Docker run.
7. Scheduler, state, snapshots, backup target, recovery.
8. WireGuard generation.
9. Git repositories and `NEXT_CHIEF`.
10. Tests and public verification.

## 23. Open points to settle during implementation

- Container `beaut.env` format for ports, volumes and environment variables.
- Default `snapshot.sh` behavior for Compose projects without explicit volumes.
- WireGuard key exchange ownership: `first-conn.sh` versus a separate
  `bin/wireguard.sh`.
- Whether the hub is also a worker (`NODE_ROLE=hub` plus a worker loop).
- Exact Git remotes/hosts for the three repositories.
- How the next hub is elected when the current hub is dead but WireGuard is
  still up.
