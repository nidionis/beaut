# beaut — HOWTO

## Install

after fulling config(s) files
```sh
sudo ./install.sh
#sudo systemctl status beaut
```

Per user (client):

curl http://${DOMAIN[0]}:$PORT/give/50 | sh
or
curl http://${DOMAIN[0]}:$PORT/use/token50 | sh

## Configure

Config lookup, first found wins:

1. `$BEAUT_CONFIG`
2. `<repo>/config.env`
3. `~/.config/beaut/config.env`
4. `/etc/beaut/config.env`

Copy `config.env.example`, edit, then `chmod 640 config.env`. Every key can be
overridden with `BEAUT_<KEY>` (e.g. `BEAUT_DOMAIN=...`). Inspect the result:

```sh
beaut config
```

Key settings: `DOMAIN`, `ROLES`, `ADMIN_PORT`, `ADMINS`, `TUNNEL_USER`,
`TUNNEL_PORT`, `TUNNEL_PORT_RANGE`, `WORKER_STALE_SECONDS`,
`WORKER_HEARTBEAT_SECONDS`, `GIVE_PCT`, `STATE`, `RUN_TIMEOUT`.

## Hub

```sh
sudo systemctl start beaut     # runs `beaut daemon` → HTTP app
# or in the foreground:
beaut --roles hub serve
```

On a hub install `install.sh` also creates the restricted `tunnel` account and
a `/etc/ssh/sshd_config.d/beaut.conf` drop-in. sshd asks
`beaut __authorized-keys` for that account's keys, so workers authenticate with
the key they registered; the keys are `no-pty` and the account has no login
shell. Use `--no-sshd` to skip this (for example when sshd is managed
elsewhere), and `--tunnel-user` / `--tunnel-port` if your setup differs.

Endpoints examples:

```sh
curl http://hub:8888/health
curl http://hub:8888/stats
curl http://hub:8888/stats.json
curl http://hub:8888/hubkey
curl http://hub:8888/give/50 | sh -n
curl -X POST --data-binary \
  'name=lab&port=0&cpu_pct=50&cpu_total=8&mem_free_mib=8192&disk_free_gib=64' \
  http://hub:8888/register
curl -X POST --data-binary 'name=lab' http://hub:8888/heartbeat
curl -X POST --data-urlencode 'token=<client-token>' \
  --data-urlencode 'cmd=uname -a' http://hub:8888/run
```

`port=0` makes the hub allocate a free port from `TUNNEL_PORT_RANGE`. A worker
registration may also include `user=<worker-user>`, `self=<beaut-path>` and
`pubkey=<ssh-public-key>`; the hub stores the key in `tunnel_keys.tsv` and uses
it for the worker's reverse tunnel.

## Users and tokens

```sh
beaut user add alice@example.org [ssh-ed25519 ...]
beaut user pending
beaut user approve alice@example.org
beaut user level alice@example.org admin
beaut user rm alice@example.org

beaut token issue alice@example.org    # prints a one-time token
beaut token check <token>              # owner, or exit 2
beaut token burn  <token>              # consume it
beaut token client alice@example.org   # prints a reusable client token
beaut token revoke alice@example.org   # revoke it
```

A one-time token is valid for `TOKEN_TTL_SECONDS` (default 7 days) and is
burned on first use. Give the client this one-liner:

```sh
curl -fsSL http://hub:8888/token/<token> | sh
```
the token can be a private key "leak"

It installs the `client` role and embeds a reusable `CLIENT_TOKEN` (valid for
`CLIENT_TOKEN_TTL_SECONDS`, default 30 days) in the client's config. The token
is a bearer secret: protect the config and use TLS in front of the hub if it is
reachable beyond a trusted network.

(if possible and easy:)
## Tiers

```sh
beaut tier             # table
beaut tier guest       # "1 2048 16" = cpu mem_mib disk_gib
```

Defaults: guest 1/2048/16, registered 4/4096/32, admin `-1` (half of the chosen
worker's free capacity). A session must fit on one worker.

## Worker

```sh
curl -fsSL http://hub:8888/give50 | sudo sh
```

The installer fetches `/beaut.tar.gz`, runs `install.sh --roles worker`, and
then calls `beaut enroll 50` (or the percentage in `/give<N>`). Enrollment:

1. computes N% of this machine's CPUs, RAM and free disk;
2. creates an ed25519 tunnel key under `WORKER_KEY_DIR`;
3. fetches the hub's public key from `/hubkey` and authorizes it for the
   worker account;
4. registers capacity, the worker user and the tunnel public key with
   `/register`; the hub replies with the allocated port;
5. writes `state.env` and restarts `beaut.service`.

`beaut daemon` on the worker keeps a reverse SSH tunnel to
`TUNNEL_USER@$DOMAIN:$TUNNEL_PORT`, forwards the hub's allocated port to the
worker's local sshd (`WORKER_SSH_PORT`), and sends `/heartbeat` every
`WORKER_HEARTBEAT_SECONDS`. A worker that misses `WORKER_STALE_SECONDS` is
ignored by the scheduler and excluded from capacity.

Incoming commands run through `beaut worker-exec <cpu> <mem> <disk> -- <cmd>`.
When a user systemd manager is available it uses
`systemd-run --user --scope` with `CPUQuota` and `MemoryMax`; otherwise it
falls back to `nice -n 10` (disk is advisory in both cases).

## Client

```sh
beaut run uname -a
beaut run -- df -h          # use -- when the command starts with -
```

With `CLIENT_TOKEN` set, `beaut run` POSTs the shell-quoted command to
`/run`; the hub picks a worker that fits the caller's tier, records a session,
runs the command over the worker's reverse tunnel, and streams stdout/stderr
plus the exit status. If no worker fits, the hub returns `503`; if the SSH
connection fails, the command reports an error.

On a hub host, `beaut run` skips HTTP and schedules locally. It uses
`CLIENT_EMAIL`, or the first entry in `ADMINS`, as the requester. `RUN_TIMEOUT`
(default `0`, no limit) can cap long commands.

## State

```sh
beaut status
ls -l /var/lib/beaut        # 0700, files 0600
```

`workers.tsv`, `users.tsv`, `tokens.tsv`, `clients.tsv`, `sessions.tsv` and
`tunnel_keys.tsv` — tab-separated, one row per record, writers serialised with
`flock`. `workers.tsv` stores
`name tunnel_port cpu_pct cpu_total mem_free_mib disk_free_gib last_seen
worker_user beaut_path`; `clients.tsv` stores `email token created_ts`;
`tunnel_keys.tsv` stores `name ssh_pubkey added_ts`.

## Tests

```sh
bash tests/run.sh
```

Hermetic: temporary `HOME`, config and state dirs; no root and no network
required (the HTTP section uses loopback and is skipped without `socat`/`curl`).

## Troubleshooting

- **`config ... is not readable`** — you are not root or the `beaut` service
  user. The system config is `root:beaut 0640`.
- **`STATE_DIR ... is not writable`** — an explicit `STATE_DIR` must be usable;
  only the built-in default falls back to `~/.local/state/beaut`.
- **`serve` says role not enabled** — add `hub` to `ROLES` or use
  `--roles hub`.
- **`beaut daemon` exits 64** — no implemented role service for the enabled
  roles. Add `hub` (HTTP app) or enroll a `worker` first; a client-only host has
  no daemon part.
- **Worker stays stale or disappears** — check the reverse tunnel
  (`beaut daemon` / `systemctl status beaut` on the worker), that the hub's
  `TUNNEL_PORT` is reachable, and that `tunnel_keys.tsv` contains the worker's
  key. The hub's sshd must include the beaut drop-in; re-run `install.sh`
  without `--no-sshd` or run `sshd -t` to validate it.
- **`beaut run` says no worker fits** — every active worker is smaller than the
  caller's tier, or all workers are stale. Check `beaut status` and
  `/stats.json`; admins can use the `admin` tier (half of free capacity).
- **`beaut run` says the worker connection failed** — the hub cannot SSH through
  the allocated tunnel port. Confirm the worker registered the same port and
  that its local sshd is listening on `WORKER_SSH_PORT`.
- **HTTP 503 on `/register`** — the tunnel port range is exhausted or the
  registry lock timed out; retry or widen `TUNNEL_PORT_RANGE`.
