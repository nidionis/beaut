# beaut — HOW IT WORKS

## Big picture

```
owner  ── curl /slave
   └── autossh -R <port> ──▶  sshd

client ── beaut run/vm ── ssh -p <port> localhost ──▶ worker through orchestrator (choosing the right worker)
```

## Config

`config.env` is sourced as bash, so it is code:

- It must be owned by the caller
- An unreadable config is an error, never silently replaced by defaults.
- Any worker must accept ssh connection (authorized_keys) from orchestrator

Lookup order: `$BEAUT_CONFIG`, `<repo>/config.env`,
`~/.config/beaut/config.env`, `/etc/beaut/config.env`.

## State

Flat TSV under `$STATE_DIR` (default `/var/lib/beaut`, mode 0700, files 0600):

| file | columns |
|---|---|
| `workers.tsv` | `name tunnel_port cpu_pct cpu_total mem_free_mib disk_free_gib last_seen worker_users beaut_path` |
| `users.tsv` | `email ssh_pubkey level approved_ts` (0 = pending) |
| `tokens.tsv` | `token email created_ts used` |
| `clients.tsv` | `email token created_ts` (reusable client token) |
| `sessions.tsv` | `id user worker kind cpu gpu mem disk started_ts` |
| `tunnel_keys.tsv` | `name ssh_pubkey added_ts` (worker tunnel keys) |

`lib/common.sh` provides `tsv_append`, `tsv_lookup`, `tsv_delete` (atomic
`mktemp` + `mv`) and `with_lock` (`flock` on `<file>.lock`). `cpu_pct` is the
donation percentage (or the resulting donated core count.)
`last_seen` is a Unix timestamp; rows older than `WORKER_STALE_SECONDS` are
stale.

## HTTP app 

should use $SHARE folder

`beaut serve` runs one `socat` listener:

```
socat TCP-LISTEN:$ADMIN_PORT,fork SYSTEM:"/path/bin/beaut __http"
```

Each connection is a fresh `beaut __http` process: it loads config, parses one
request, writes one `Content-Length`-framed response, exits. Limits: 4 KiB
request line and total headers, 100 headers, 64 KiB body; `Transfer-Encoding`
is refused. Routing uses fixed patterns; values are validated before use, and
nothing user-supplied is echoed into headers or shell.

| request | result |
|---|---|
| `GET /`, `/stats` | `stats_text` |
| `GET /stats.json` | `stats_json` |
| `GET /health` | `ok` |
| `GET /give<N>` | worker installer (N clamped 1..100) |
| `POST /register` | upsert worker; `port=0` allocates a free port; optional `user`, `self`, `pubkey` |
| `GET /hubkey` | the hub's public worker-login key |
| `POST /heartbeat` | `name=<worker>`; refresh `last_seen` |
| `POST /run` | `token=<client-token>&cmd=<shell command>`; schedule and execute |
| `GET /client/<token>` | burn token, return client installer; `410` if invalid |
| `GET /beaut.tar.gz` | `bin lib docs install.sh config.env.example beaut.service` |

The generated installers fetch `/beaut.tar.gz`, run `install.sh`, and then
`beaut enroll` (worker) or install the client role with a reusable
`CLIENT_TOKEN` (client). `/run` requires a valid client token and a known user;
it returns `403` for a bad token, `400` without `cmd`, `503` when no worker
fits, and `X-Beaut-Exit` with the command's status otherwise.

## Stats

`lib/stats.sh` does one awk pass over `workers.tsv` + `sessions.tsv`:

- `total` = worker rows; `active` = seen within `WORKER_STALE_SECONDS`;
  `stale` = the rest.
- Capacity sums only active workers (`cpu_total`, `mem_free_mib`,
  `disk_free_gib`).
- Free capacity subtracts the CPU/mem/disk of sessions assigned to those
  workers, floored at zero.
- `pending_users` counts `users.tsv` rows with `approved_ts == 0`.

Text and JSON come from the same snapshot, so they never disagree.

## Auth

- Users: `email`, optional SSH key, level `guest|registered|admin`, `approved_ts`.
  Adding a user creates a pending guest; `approve` promotes to registered.
- Tokens: 128-bit hex, single-use, TTL `TOKEN_TTL_SECONDS`. `token_burn` is
  atomic under the file lock, so two clients cannot redeem the same token.
- Client tokens: `token client <email>` stores a reusable 128-bit token in
  `clients.tsv`; `token revoke` deletes it. They are sent to `/run` and are
  bearer credentials, so keep `config.env` private.
- SSH keys are checked syntactically and with `ssh-keygen -l` when available.

## Worker enrollment and tunnel

`beaut enroll <pct>` computes the donated share, creates
`$WORKER_KEY_DIR/id_ed25519`, fetches `GET /hubkey`, and adds the hub's public
key to the worker account's `authorized_keys` with `no-pty` and forwarding
disabled. It then POSTs the worker name, capacity, user, `beaut` path and tunnel
public key to `/register`. The hub stores the key in `tunnel_keys.tsv` and
returns a tunnel port.

The worker daemon runs `autossh -N -R <allocated>:localhost:<WORKER_SSH_PORT>`
to `TUNNEL_USER@$DOMAIN:$TUNNEL_PORT` and sends `/heartbeat` every
`WORKER_HEARTBEAT_SECONDS`. The hub's sshd uses
`AuthorizedKeysCommand beaut __authorized-keys %u %f`, which prints keys from
`tunnel_keys.tsv` only for `TUNNEL_USER`; the tunnel account itself is
`nologin`.

## Scheduler and quotas

`hub_pick <cpu> <mem> <disk>` walks active `workers.tsv` rows, subtracts the
usage recorded in `sessions.tsv`, and chooses the fitting worker with the most
free memory. A tier value of `-1` (admin) means half of that worker's free
capacity, floored at 1. `hub_reserve` records the chosen session under the
`sessions.tsv` lock; `hub_run` executes over SSH and deletes the session when
the command finishes.

`beaut run` uses the reusable `CLIENT_TOKEN` to POST to `/run`; the hub maps the
email to a tier (`guest`, `registered` or `admin`) and runs
`beaut worker-exec <cpu> <mem> <disk> -- <cmd>` on the worker. On a hub host the
same path runs locally without HTTP, using `CLIENT_EMAIL` or the first
`ADMINS` entry. `worker-exec` uses `systemd-run --user --scope` with
`CPUQuota`/`MemoryMax` when possible, otherwise `nice -n 10`; disk quotas are
advisory.

## Install

`install.sh` copies `bin/` and `lib/` to `$PREFIX/share/beaut`, links
`$PREFIX/bin/beaut`, writes `config.env` from the example, and installs a
systemd unit. System layout: `/etc/beaut/config.env` is `root:beaut 0640`, state
is owned by the `beaut` service user. User layout: everything under
`$DIR` (~/.$NAME)
On a hub install it also creates the `tunnel` account and writes
`/etc/ssh/sshd_config.d/beaut.conf` with the `AuthorizedKeysCommand`, then
reloads sshd. `--no-sshd` skips that. A worker install gives the `beaut` service
account `/bin/sh` so the hub can log in and run `worker-exec`.

## Security notes

- Config is code: ownership and write permissions are enforced.
- State dir is 0700, files 0600, writes are locked and atomic.
- Workers should not hold no secrets but them private keys for authentication if not installed under root.
- `/register` is currently open (no enrollment secret or rate limit); add one
  before exposing the hub publicly.
- Client tokens are bearer secrets and travel over plain HTTP; use TLS in front
  of the hub and keep client configs private.
- The tunnel account only accepts keys from `tunnel_keys.tsv`, and worker keys
  are restricted with `no-pty`; the hub's own key (`HUB_KEY`) logs into workers.
- TLS is not implemented; put a reverse proxy in front of `:8888`.

## Status

Implemented: steps 1–4 (scaffold, config/state/auth, HTTP app, stats, worker
//enrollment/tunnel/quotas, scheduler + `run`).
//Planned: step 5 QEMU/SPICE `vm`, step 6 mail inscription.
