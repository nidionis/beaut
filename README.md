# beaut

A small operator-owned Docker fabric: one hub, workers that pull work, readable
JSON state, snapshots and basic failover.

This is the minimal working core described in `FULLSCRIP.md`, not the complete
package/session layer. It is deliberately small and uses only Bash, `socat`,
`curl`, `jq`, `ssh`, `awk`, `tar` and `ssh-keygen` (plus Docker on workers).

## What works now

- The hub keeps worker inventory, job state and a small JSON/HTML status API.
- Workers register with a key-derived identity and report CPU, memory, disk and
  uptime.
- A worker pulls its work as a shell script with `curl ... | sh`.
- A project folder with a `Dockerfile` or a Compose file becomes a job.
- One-shot jobs reach `done`; service jobs stay `running`.
- An assigned backup worker receives and keeps snapshots.
- When the primary worker stops heartbeating, its jobs are rescheduled and the
  replacement restores the latest available snapshot.
- Deployment and first-connection scripts exist for SSH installation.

WireGuard, Git repositories, packages, named sessions, `NEXT_CHIEF` and full
Docker volume/image snapshots are later layers. Remote deployment is implemented
but has not been exercised against a second machine yet.

## Shape

```text
                    browser / operator
                           │
                           ▼
                    ┌────── hub ───────┐
                    │ main port        │  site/, /status, /report,
                    │                  │  /heartbeat, /container/*
                    │ work port        │  /work?hash=<worker hash>
                    └────────┬─────────┘
                             │  explicit address, no localhost
              ┌──────────────┴──────────────┐
              ▼                             ▼
       ┌─────────────┐               ┌─────────────┐
       │   worker A  │◄── snapshot ──│   worker B  │
       │ Docker jobs │               │ backup copy │
       └─────────────┘               └─────────────┘

worker A ── heartbeat/report ──► hub
worker A ── GET /work ─────────► hub work port
worker A ── PUT /snapshot ─────► assigned backup worker
```

Every internal address is explicit in configuration. The runtime never falls
back to `localhost` or `127.0.0.1`; the smoke test and `first-conn.sh` reject
loopback targets on purpose.

## Layout

```text
beaut                        CLI: the only general argument parser
bin/
  beaut-hub                  run the hub main listener
  beaut-work                 run the hub work listener
  beaut-worker               run the worker loop and snapshot receiver
  beaut-hub-http             answer one hub request
  beaut-work-http            answer one work request
  beaut-worker-http          answer one worker request
  deploy-hub.sh              install/update the hub (no arguments)
  deploy-worker.sh           install/update one worker (no arguments)
  first-conn.sh              bootstrap a new node over SSH
lib/
  bootstrap.sh               locate the tree, select config, load modules
  common.sh                  logging, validation, quoting, templates
  config.sh                  conf.env + node.env + defaults
  resources.sh               local resource probe
  http.sh                    HTTP request/response layer and listener
  router.sh                  site/ and work/ route resolution
  state.sh                   worker and job JSON state
  hub.sh                     scheduling, reports, work scripts, containers
  worker.sh                  heartbeat/report loop, work, snapshots, receiver
  status.sh                  hub status client and HTML table
  doctor.sh                  configuration and dependency check
  deploy.sh                  SSH tree/config/unit deployment
share/
  awk/kv.awk                 query/body key=value reader
  awk/resources.awk          resource formatter
  awk/status.awk             status table formatter
  page.html                  shared HTML page
  templates/work-job.sh      POSIX script emitted by the hub
  templates/first-conn.sh    root-side bootstrap script
  usage.txt                  command help
site/
  index                      HTML status table
  health                     health route (also handled directly)
  status                     JSON inventory route
  report                     worker report route
  heartbeat                  lightweight liveness route
work/script.sh               hub work route
containers/hello/            one-shot Dockerfile job
containers/http/             long-running HTTP job
conf/conf.env.example        configuration template
services/                    user systemd unit templates
tests/smoke.sh               end-to-end real-address acceptance test
tests/fixtures/smoke.env     rendered test configuration
```

Only `beaut` interprets general command-line arguments. The long-running
programs under `bin/` take no arguments, and the deploy scripts are
argument-free; `bin/first-conn.sh` takes only the bootstrap arguments documented
by `beaut first-conn`. Modules derive paths from `BEAUT_ROOT`, `BEAUT_CONFIG`
and `BEAUT_ENV`; configuration lives in files, not heredocs.

## Requirements

- Bash 4.2 or newer
- `socat`, `curl`, `jq`, `ssh`, `awk`, `tar`, `ssh-keygen`, `sha256sum`
- Docker on every worker; `docker compose` for Compose projects
- `sshpass` only when using the optional password path in `first-conn.sh`
- user systemd on deployed nodes (`systemctl --user`) and `loginctl` for linger

The runtime itself does not require root. Docker access may use `sudo` as
configured. `first-conn.sh` needs an initial sudo-capable account because it
creates accounts, keys and `/etc/sudoers.d/beaut-worker`.

## Configure

```bash
cp conf/conf.env.example conf/conf.env
$EDITOR conf/conf.env
```

The important values are:

```bash
HUB="192.168.1.195"      # address workers use to reach the hub
PORT="8081"              # hub main port
WORK_PORT="8090"         # hub work-script port
WORKER_PORT="8091"       # this worker's report/snapshot port
ROOT="$HOME/.beaut"      # install and state root
DOCKER_CMD="sudo docker"
```

`HUB` must already be reachable; WireGuard is not implemented yet. `ROOT`
defaults to `$HOME/.beaut`. Deploy resolves that default against the remote
account's home, so nodes may have different home directories. Set an explicit
absolute `ROOT` when every node must share the same path.

`conf/node.env` is generated on each machine by deployment and is loaded after
`conf.env`. It contains `NODE_ROLE`, `NODE_ADDRESS`, `HUB` and `WORKER_PORT`.
Do not edit it by hand.

Each node needs its own configuration directory if several workers run on one
machine: keys live next to the configuration file, and sharing a configuration
directory makes workers reuse one identity.

`DOCKER_CMD` must work non-interactively for the account that owns the worker
unit. `first-conn.sh` grants passwordless Docker to the admin and worker
accounts, which is why the example uses `sudo docker`.

## Run the test

The smoke test needs an address that reaches the test machine and a working
Docker daemon:

```bash
TEST_ADDRESS=192.168.1.195 ./tests/smoke.sh
```

It starts one hub, one work listener and two workers on randomly chosen ports,
then checks:

1. both workers register with distinct key hashes and resource reports;
2. the hello-world Dockerfile job reaches `done`;
3. an HTTP container serves `beaut test page`;
4. the assigned backup worker receives a snapshot;
5. killing the primary worker reschedules the job and the HTTP page returns.

The test uses real addresses and ports; loopback is rejected. It removes the
test containers and images on success, and keeps `tests/.build/smoke` with logs
on failure.

## Run by hand

On the hub machine, from the checkout:

```bash
BEAUT_CONFIG="$PWD/conf/conf.env" ./bin/beaut-hub
BEAUT_CONFIG="$PWD/conf/conf.env" ./bin/beaut-work
```

On each worker, the config must set `NODE_ROLE="worker"` and an explicit
`NODE_ADDRESS` (deployment writes both into `conf/node.env`):

```bash
BEAUT_CONFIG="$PWD/conf/conf.env" ./bin/beaut-worker
```

Or use the CLI aliases:

```bash
./beaut hub serve
./beaut worker serve
```

Create a job:

```bash
./beaut run containers/hello    # prints the job id
./beaut jobs                    # JSON job state from local hub state
./beaut status                  # worker inventory fetched from HUB:PORT
```

`beaut run` must run where the hub state lives. The job id is derived from the
canonical project path, so the same path keeps one job record. The archive hash
changes when project content changes. Re-running unchanged content is idempotent.
A changed archive keeps the existing primary and backup placement and makes that
primary deploy the new bytes; a previously done job returns to `assigned` until
the worker reports the new archive as done.

## Job projects

A job is an ordinary directory. The hub packs it as `containers/<archive>.tar.gz`
with the job id as the archive root, then workers extract it under their own
`containers/<job>/` directory.

The work script prefers Compose:

```text
compose.yaml or docker-compose.yml
  -> docker compose -p beaut-<job> up -d --build
```

Otherwise it uses a `Dockerfile`:

```text
Dockerfile
  -> docker build -t beaut-<job> .
  -> docker run  (service) or docker run --rm (once)
```

For a Dockerfile project, an optional `beaut.env` controls the run. It is read as
literal `KEY=value` lines, not sourced as shell code:

```bash
RUN_MODE=once          # default: service
PORTS="18080:8000"     # whitespace-separated host:container pairs
ENVS="KEY=value"       # whitespace-separated KEY=value pairs
COMMAND="python -m http.server 8000"
```

`PORTS`, `ENVS` and `COMMAND` are split on whitespace. Values containing spaces
need a Compose file instead. A project may also provide `snapshot.sh`; if it
exists, the worker runs it from the job directory and expects a tar.gz stream on
stdout.

Job ids are 16 lowercase hex characters. Dockerfile jobs use the container name
`beaut-<job>`; Compose jobs use `beaut-<job>` as the Compose project name. Work
scripts are idempotent through marker files:

```text
$ROOT/state/marks/<job>.running
$ROOT/state/marks/<job>.done
```

A running service is only considered alive when the container is still running;
otherwise the job is redeployed. A failed deployment is retried on the assigned
worker at the next work pull. There is no attempt limit or terminal `failed`
state yet.

## Scheduling and failover

Every `HEARTBEAT_DELAY` seconds a worker sends a lightweight heartbeat. Every
`REPORT_DELAY` seconds it sends resources, job markers and snapshot locations,
then pulls work. A worker is online while its last heartbeat or report is within
`DEATH_TIME`.

Candidates must be online and above `MIN_CPU`, `MIN_RAM_KB` and
`MIN_DISK_KB`. They are sorted by `SCHEDULING_PRIO`; higher free resources win,
and `load1` is the lazy tie-break:

```bash
SCHEDULING_PRIO=(cpu ram disk)
```

The first pending job is assigned only when the best ranked worker asks for
work. The next ranked worker becomes the backup and stays sticky while online.
If the primary disappears, the job returns to `pending`, is assigned again, and
the new worker tries to restore the latest snapshot the hub knows about. The hub
prefers a snapshot reported by the assigned backup worker and falls back to the
backup if the recorded snapshot holder is offline. If no usable snapshot can be
fetched, the job starts from the project archive instead of failing.

`NEXT_CHIEF` and multi-level recovery are not implemented yet; only primary and
backup are tracked.

## Snapshots

Every `BACKUP_DELAY` seconds each worker snapshots the jobs assigned to it:

```text
$ROOT/snapshots/<job>/<UTC timestamp>-<pid>.tar.gz
```

The default snapshot is a tar of the job folder (`containers/<job>`). It does
**not** include Docker named volumes, images or container filesystems. Use a
`snapshot.sh` inside the project to capture what the project needs. The archive
is sent to the assigned backup worker:

```text
PUT http://<backup address>:<worker port>/snapshot?hash=<sender>&job=<job id>
```

The backup worker verifies the 16-hex sender and job ids and writes the archive
to `$ROOT/snapshots/incoming/<job>/`. `RETAIN_SNAPSHOTS` limits how many archives
are kept per directory. Snapshot archives can contain project secrets; protect
the root directory.

## Hub endpoints

Main port:

| Route | Method | Response |
| --- | --- | --- |
| `/` | GET | HTML worker/status table |
| `/health` | GET/HEAD | `ok` |
| `/status` | GET | workers and jobs as JSON |
| `/report` | POST | JSON worker report |
| `/heartbeat` | POST | `hash`, `address`, `port` |
| `/container/<archive>.tar.gz` | GET | cached project archive |
| `/<path>` | GET | `site/<path>` route, else 404 |

The container route also accepts a job id and resolves its current archive.

Work port:

| Route | Method | Response |
| --- | --- | --- |
| `/health` | GET/HEAD | `ok` |
| `/work?hash=<worker hash>` | GET | POSIX work script or `:` |
| `/work/<hash>/script.sh` | GET | optional per-worker override |

Worker port:

| Route | Method | Response |
| --- | --- | --- |
| `/health` | GET/HEAD | `ok` |
| `/status` | GET | local worker JSON |
| `/snapshot?hash=<sender>&job=<id>` | PUT/POST | receive a snapshot |
| `/snapshot/latest?job=<id>` | GET | latest local or incoming snapshot |

There is no authentication. The work port serves executable shell scripts, and
the snapshot routes accept any caller that knows a valid 16-hex hash. Run this
on a trusted private link or put an authenticating proxy in front of it.

## Routes

The hub serves extensionless files from `site/` for paths not handled directly:

```text
/            -> site/index
/hello/world -> site/hello/world
```

A route is a Bash script sourced by the HTTP handler with the HTTP helpers
loaded. It may send any response:

```bash
http_respond "200 OK" "text/plain" $'hello\n'
http_json "200 OK" '{"ok":true}'
http_not_found
http_forbidden
http_send_file /path/to/file application/octet-stream
render_template "$BEAUT_ROOT/share/page.html" TITLE "Title" BODY "<p>Hi</p>"
```

`ROUTE_PATH` and `ROUTE_FILE` are set before the route runs. Paths containing
`..`, hidden components, duplicate slashes or unsafe characters are rejected.
A route that sends nothing becomes a 500. Routes are read on every request, so
adding or editing one does not require a restart.

The work tree is resolved separately. `work/script.sh` normally calls
`hub_work`; `work/<hash>/script.sh` is an optional debugging override. A
missing work route returns `:` so `curl ... | sh` is a no-op.

## State

```text
$ROOT/
  app/                       deployed source tree
  conf/conf.env              copied configuration
  conf/node.env              generated per-node values
  conf/keys/node             local node key (generated)
  state/workers/<hash>.json  hub inventory
  state/jobs/<job>.json      hub job records
  state/heartbeat/<hash>     lightweight liveness marks
  state/assign/<job>         worker's backup target
  state/marks/<job>.running  worker execution markers
  state/marks/<job>.done
  containers/<archive>.tar.gz
  containers/<job>/          extracted project
  snapshots/<job>/           local snapshots
  snapshots/incoming/<job>/  snapshots received as a backup
```

State is ordinary JSON and text. Atomic writes replace files through a
temporary file, so a reader never sees a partial record.

## Deploy

Deployment scripts are argument-free and read `conf/conf.env`:

```bash
./beaut deploy hub
./beaut deploy worker
```

Hub deployment uses `HUB` and `SSH_USER` (default `ADMIN_USER`). Worker
deployment also needs `WORKER_TARGET` and `WORKER_ADDRESS`:

```bash
WORKER_TARGET="192.168.1.196"
WORKER_ADDRESS="192.168.1.196"
```

`WORKER_TARGET` may be `user@address`. The scripts pack the tree, stream it over
SSH, write `conf/conf.env` and `conf/node.env`, install user units, enable linger
and restart/verify them. State, logs, snapshots and keys are not overwritten.

First connection is the bootstrap exception. It needs an initial sudo-capable
account:

```bash
./beaut first-conn hub    192.168.1.195 admin
./beaut first-conn worker 192.168.1.196 admin
./beaut first-conn worker 192.168.1.196 admin 'password'   # sshpass path
```

`first-conn.sh` verifies SSH and sudo, creates `ADMIN_USER` and `WORKER_USER`,
installs the installer public key for both, prepares `$ROOT`, grants
passwordless Docker to both accounts and installs the tree. The password is
passed through `sshpass` and is not written to disk; prefer keys.

Current deployment limitation: the units run as the deploying admin account.
The separate `worker` account is created and ready, but the worker unit does not
switch to it yet. The remote deployment path is implemented but untested; keep
an existing SSH session open when trying it for the first time.

## Commands

```text
beaut hub serve
beaut worker serve
beaut run PROJECT_FOLDER
beaut jobs
beaut status [--json]
beaut resources [--raw|--json]
beaut doctor
beaut deploy hub|worker
beaut first-conn ROLE TARGET SUDO_USER [PASSWORD]
```

`beaut doctor` prints the effective configuration and dependencies. It does not
start listeners.

## Limits and next layers

- No WireGuard yet; `HUB`, `WORKER_ADDRESS` and binds must be reachable now.
- No authentication or TLS; use a trusted link or an external proxy.
- No Git repositories for site, state and logs yet.
- No content-addressed package store or named sessions.
- Snapshots capture the job folder, not Docker volumes, images or container
  filesystems, unless `snapshot.sh` does so.
- No `NEXT_CHIEF` list or repeated failover; only primary and backup.
- No attempt limit or terminal `failed` state for broken jobs.
- No remote deployment test yet.

The next implementation slice is WireGuard addressing, then Git-backed site and
state repositories, then the full snapshot/recovery layer.
