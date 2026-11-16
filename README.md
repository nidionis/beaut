# beaut

A small operator-owned fabric: one hub, a few workers, readable state, and
deployment over SSH that is already open.

This repository is the **minimal base**, not the full package/session layer.
It gives the project a working spine:

- a hub that inventories workers, serves a dashboard/JSON API and serves the
  `site/` folder tree;
- a worker that reports CPU, memory, disk and uptime;
- optional reverse-SSH tunnels for workers behind NAT;
- a local resource probe and a small `awk` formatter;
- a `deploy.sh` that installs the tree and user systemd units over existing SSH;
- no sudo, no database, no dependencies beyond Bash, `socat`, `curl`, `jq`, `ssh`, `awk`, `tar`.

The hub is reached through one public URL. There is no localhost or LAN-IP
fallback in the runtime: set `PUBLIC_URL` and use it.

## Shape

```text
                         PUBLIC_URL
                             │
                             ▼
                    ┌────── hub ───────┐
                    │ /  /status       │
                    │ /health  /workers│
                    │ site/ tree       │
                    └────────┬─────────┘
                             │ tunnel or direct probe
                    ┌────────▼─────────┐
                    │      worker      │
                    │ /health  /info   │
                    └──────────────────┘
```

The hub polls each worker on `/info` (through its reverse tunnel first, then
directly at `host:port`). Everything it sees is cached in `state/workers.tsv`;
the dashboard and `beaut status` show the live result.

## Layout

```text
beaut                  CLI: the only argument parser
bin/
  beaut-hub            run the hub listener
  beaut-worker         run the worker listener
  beaut-hub-http       answer one hub HTTP request
  beaut-worker-http    answer one worker HTTP request
  beaut-tunnel         keep the reverse SSH tunnel
  beaut-relay          expose the hub through a relay
lib/
  bootstrap.sh         locate the tree, select config, load modules
  common.sh            logging, validation, template rendering
  config.sh            conf.env + node.env + defaults
  resources.sh         local resource probe
  http.sh              HTTP request/response layer and listener
  site.sh              folder-tree route server
  hub.sh               worker inventory, state cache, dashboard, listener
  worker.sh            worker handler and listener
  transport.sh         reverse tunnels and public relay
  service.sh           per-user systemd units
  status.sh            public hub status client
  doctor.sh            configuration and dependency check
share/
  dashboard.html       dashboard template
  page.html            site page template
  usage.txt            help text
  awk/                 resource and status formatters
  jq/                  inventory, cache and dashboard filters
  systemd/             unit templates
site/
  hello/world          example route for /hello/world
  hello/world.html     example page fragment
deploy.sh              install/update nodes over SSH
conf.env.example       configuration template
tests/smoke.sh         loopback hub + worker contract test
tests/fixtures/        test configuration
```

Only `beaut` interprets arguments. The `bin/` programs take none and each call
one function; `socat` and systemd invoke them directly. Modules under `lib/`
derive paths from `BEAUT_ROOT`, `BEAUT_CONFIG` and `BEAUT_ENV` instead of
hard-coding an install directory. Templates and filters are ordinary files
under `share/`; the shell does not embed them with heredocs.

On an installed node:

```text
~/.beaut/app/          deployed tree
~/.beaut/app/bin/      argument-free entrypoints
~/.beaut/app/site/     site routes
~/.beaut/app/conf.env
~/.beaut/node.env      generated per-node overrides
~/.beaut/state/        workers.tsv
~/.beaut/logs/         reserved for file logs (systemd uses the journal)
~/.config/systemd/user/beaut-*.service
```

## Requirements

- Bash 4.2+, `socat`, `curl`, `jq`, `ssh`, `awk`, `tar`
- a user systemd session on hub and workers (`systemctl --user`)
- `loginctl enable-linger <user>` so units survive logout
- SSH access from the deployment machine to every worker
- no root or sudo is used

## Configure

```bash
cp conf.env.example conf.env
$EDITOR conf.env
```

`PUBLIC_URL` is the only URL clients use. There is deliberately no separate
hub URL and no loopback fallback:

```bash
PUBLIC_URL="https://beaut.example.net"
```

Worker rows are pipe-separated:

```text
name | host | port | ssh target (optional) | tunnel port (optional)
```

- `ssh` empty uses `SSH_USER@host`, or `host` when `SSH_USER` is empty.
- `ssh` set to `local` means the worker runs on the hub machine; `deploy.sh`
  installs it in place without SSH.
- `tunnel port` empty means the hub reaches the worker directly at `host:port`.
- with a tunnel port, the worker keeps
  `ssh -R 127.0.0.1:<tunnel>:127.0.0.1:<worker port> <HUB_SSH>` and the hub
  tries that endpoint before the direct one.
- `HUB_SSH` is the SSH destination workers use for reverse tunnels. It is not a
  web URL.

A worker on the same machine as the hub needs no tunnel; mark its ssh field
`local`.

## Site routes

The hub falls back to the `site/` folder tree for paths that are not core
endpoints. A URL path maps directly to a file:

```text
/hello/world  ->  site/hello/world
```

The file is a Bash script, sourced by the hub with the HTTP helpers loaded.
Only extensionless paths are routes: `site/hello/world.html` is data, not a
route. The sample route is:

```bash
#!/usr/bin/env bash
# Site route: /hello/world
html_page "Hello, world" "$(<"$SITE_DIR/hello/world.html")"
```

`site/hello/world.html` holds the page fragment. Content can stay in ordinary
files; the route script decides how to respond.

Available helpers:

- `html_page TITLE BODY` — render `share/page.html` as `text/html`;
- `http_respond STATUS TYPE BODY` — send any raw response;
- `http_not_found` — the standard 404.

`SITE_PATH` and `SITE_FILE` are set before the script is sourced. Paths are
validated: hidden components, `..`, `//` and non-URL-safe characters are
rejected. There is no directory index; create a script for each route.

Set `SITE_DIR` to serve another tree; empty uses `$BEAUT_ROOT/site`.

## Deploy

Run from the hub checkout:

```bash
./deploy.sh hub          # install/restart the hub here
./deploy.sh workers      # all configured workers
./deploy.sh w1           # one worker
./deploy.sh all          # hub then workers
```

The hub is always installed locally. Workers are installed over
`ssh <target>`, which must already work (key or agent). The script uses
`BatchMode=yes` and never starts a password prompt. It uploads a tar stream,
writes `~/.beaut/node.env`, installs user units, restarts them and reports
inactive units with their journal lines.

Useful overrides:

```bash
BEAUT_CONFIG=/path/to/conf.env ./deploy.sh all
```

The optional public relay is only touched when `HUB_RELAY` is non-empty:

```bash
HUB_RELAY="user@public-host"
HUB_RELAY_PORT="18080"
```

That installs `beaut-relay.service`, which forwards
`127.0.0.1:18080` on the public host to the local hub `:8081`. Leave
`HUB_RELAY` empty to let an existing relay keep running untouched.

### Migrating from an older build

This base installs under the SSH user's `~/.beaut` and uses that user's
systemd instance. If an older worker still runs under another account (for
example the `beaut` service account) and holds the same port, stop it first or
give the new worker a different port in its row. The local configuration in
this checkout uses `8091` for the hub's own worker and leaves the old `8090`
worker alone. An existing relay unit is also left running while `HUB_RELAY`
is empty.

## Commands

```text
beaut hub serve
beaut worker serve
beaut worker tunnel
beaut relay
beaut service install hub|worker
beaut status [--json]
beaut resources [--raw|--json]
beaut deploy [hub|workers|all|NAME]
beaut doctor
```

`beaut resources` is the resource probe; `beaut resources --raw` is the
key=value form consumed by `share/awk/resources.awk`.

The listener/tunnel/relay commands are thin aliases for `bin/beaut-*`. Systemd
runs those programs directly, so the service path never re-interprets a role
argument. `beaut` itself is the only command-line parser.

## Endpoints

Hub:

- `GET /` — HTML dashboard, refreshed every 15s
- `GET /health` — `ok`
- `GET /status` — `{hub, now, workers:[…]}`
- `GET /workers` — worker array only
- `GET /<path>` — `site/<path>` route script, else 404

Worker:

- `GET /health` — `ok`
- `GET /info` — local resource JSON

State is ordinary text:

```text
~/.beaut/state/workers.tsv
```

There is no authentication. Run this on a trusted link or put an
authenticating reverse proxy in front of the hub.

## Next layers

The base deliberately stops before packages, routes and sessions. The natural
next steps, in project order, are:

1. content-addressed store under `~/.beaut/store`;
2. route table mapping public names/paths to worker ports;
3. Docker sessions executed on workers through the existing tunnel;
4. snapshots and backup copies on a separate worker.
