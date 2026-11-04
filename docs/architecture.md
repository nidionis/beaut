# beaut — architecture

`beaut` recycles spare compute by mutualising resources. One command donates a
percentage of a machine; registered users then run remote commands or graphical
VM sessions on the pooled capacity. It is pure bash; `.svr` (a symlinked
personal environment) is reused as the toolbox and never modified.

## Roles (composable, `ROLES=hub,worker,client`)

| role   | what it does                                                   |
|--------|----------------------------------------------------------------|
| hub    | serves `$DOMAIN`: HTTP app on `:$ADMIN_PORT` (8888), mailbox poller, scheduler |
| worker | donates N% of CPU/RAM/disk, keeps a reverse SSH tunnel to the hub |
| client | `beaut run <cmd>` / `beaut vm`                                 |

```
curl $DOMAIN/give50 | sh          owner machine  ──autossh -R──▶  hub
mail join@$DOMAIN  ──▶ hub poller ──msmtp──▶ token + client install line
beaut run / vm     ──▶ hub picks a fitting worker ──ssh -p <port> localhost──▶ worker
client ──ssh -J hub -L <spice>──▶ worker VM (QEMU + SPICE)
```

## Layout

```
bin/beaut            dispatcher: options, roles, subcommands
lib/common.sh        config load, validation, state dir, logging, TSV + tier helpers
lib/auth.sh          tokens, users.tsv, admin list, ssh-key helpers
lib/http.sh          HTTP app on :8888 (socat accept-loop + routing)
lib/stats.sh         worker/session capacity snapshot (text + JSON)
lib/worker.sh        give<N> enroll, reverse tunnel, caps, worker-exec
lib/hub.sh           worker registry + scheduler + remote execution
lib/client.sh        `beaut run` over HTTP or locally on the hub
lib/vm.sh            (step 5) QEMU/SPICE sessions via .svr scripts
lib/mail.sh          (step 6) mailbox poll, join@ handling, replies, approval
install.sh           one-command bootstrap (system or --user)
beaut.service        systemd unit running `beaut daemon`
config.env.example   all settings, documented
tests/               bash smoke tests (`tests/run.sh`)
```

## HTTP app (`beaut serve`, role hub)

One `socat` listener on `$ADMIN_BIND:$ADMIN_PORT`; each connection is handled by
`beaut __http`, which parses a single request and closes. Responses are
`Content-Length` framed, `Cache-Control: no-store`, and never echo user input.

| request | response |
|---|---|
| `GET /`, `GET /stats` | plain-text capacity snapshot |
| `GET /stats.json` | same snapshot as one-line JSON |
| `GET /health` | `ok` |
| `GET /give<N>` | worker installer; N clamped to 1..100 |
| `POST /register` | upsert worker; form `name&port&cpu_pct&cpu_total&mem_free_mib&disk_free_gib` (or `key=value&...`); optional `user`, `self`, `pubkey`; `port=0` allocates from `TUNNEL_PORT_RANGE`; replies `ok port=<n>` |
| `GET /hubkey` | public half of the hub's worker-login key |
| `POST /heartbeat` | `name=<worker>`; refresh `last_seen`, `404` if unknown |
| `POST /run` | `token=<client-token>&cmd=<shell command>`; schedule and execute on a worker; `X-Beaut-Exit` carries the status |
| `GET /client/<token>` | burns the one-time token and returns the client installer, `410` if used/expired |
| `GET /beaut.tar.gz` | the bash tree (`bin lib docs install.sh config.env.example beaut.service`), no config/state |

Request line and header bytes are capped (4 KiB / 100 headers), bodies at
64 KiB, and `Transfer-Encoding` is refused. The generated installers only embed
validated values (domain, port, percentage) and fetch `/beaut.tar.gz`.

## Configuration

`config.env` is bash, sourced by `lib/common.sh`. Lookup order:
`$BEAUT_CONFIG`, `<repo>/config.env`, `~/.config/beaut/config.env`,
`/etc/beaut/config.env`. Files writable by others, or owned by someone other
than the caller or root, are refused (they are code). A config that exists but
is unreadable is an error, never skipped: an admin without access must not end
up on defaults and a private state dir. The system install writes
`/etc/beaut/config.env` as `root:beaut 0640` (dir `0750`): root edits it, the
`beaut` service user only reads it, and both pass the ownership check.

Known keys can be overridden with `BEAUT_<KEY>` in the environment (allow-list:
only config keys, so `BEAUT_PATH` is ignored); `--roles` and `-c` are shortcuts.
Numeric fields (ports, `TUNNEL_PORT_RANGE`, `WORKER_STALE_SECONDS`, `GIVE_PCT`,
`TOKEN_TTL_SECONDS`, `MAIL_POLL_SECONDS`, `TIERS`) are validated at load. Note that derived values
written in the file (e.g. `MAIL_FROM="join@$DOMAIN"`) are expanded when the
file is sourced, so overriding `BEAUT_DOMAIN` does not recompute them.

## State (`$STATE_DIR`, default `/var/lib/beaut`, mode 0700, files 0600)

If `STATE_DIR` is set (config or env) and not writable, commands fail with a
clear error. Only the built-in default falls back to `$XDG_STATE_HOME/beaut`.

| file           | columns                                                                  |
|----------------|--------------------------------------------------------------------------|
| `workers.tsv`  | `name tunnel_port cpu_pct cpu_total mem_free_mib disk_free_gib last_seen worker_user beaut_path`; rows older than `WORKER_STALE_SECONDS` are excluded from capacity |
| `users.tsv`    | `email ssh_pubkey level(guest|registered|admin) approved_ts` (0 = pending) |
| `tokens.tsv`   | `token email created_ts used(0/1)`                                       |
| `clients.tsv`  | `email token created_ts` — reusable client token                         |
| `sessions.tsv` | `id user worker kind(cmd|vm) cpu mem disk started_ts`                    |
| `tunnel_keys.tsv` | `name ssh_pubkey added_ts` — worker tunnel keys read by `__authorized-keys` |

Writers take an `flock` on `<file>.lock`; replacements are atomic (`mktemp` + `mv`).

## Tiers

```
guest       1 CPU  2048 MiB  16 GiB
registered  4 CPU  4096 MiB  32 GiB
admin      -1 -1 -1           # half of the chosen worker's free resources
```

A session must fit on a single worker.

## Worker enrollment and tunnel

`beaut enroll <pct>` computes N% of the host's CPUs, RAM and free disk, creates
an ed25519 key under `WORKER_KEY_DIR`, fetches the hub public key from
`GET /hubkey`, and authorizes it for the worker account with `no-pty` and
forwarding disabled. It then registers capacity, the worker user, the `beaut`
path and the tunnel public key with `POST /register`; the hub stores the key in
`tunnel_keys.tsv` and returns an allocated port.

The worker daemon runs `autossh -N -R <allocated>:localhost:<WORKER_SSH_PORT>`
to `TUNNEL_USER@$DOMAIN:$TUNNEL_PORT` and heartbeats
`POST /heartbeat`. The hub's sshd uses
`AuthorizedKeysCommand beaut __authorized-keys %u %f`, which returns keys from
`tunnel_keys.tsv` only for `TUNNEL_USER`; the tunnel account is `nologin`.

## Scheduler and execution

`lib/hub.sh` reads active workers, subtracts the usage recorded in
`sessions.tsv`, and picks the fitting worker with the most free memory.
Tier `-1` (admin) means half of that worker's free capacity, floored at 1.
`hub_reserve` records a session under the `sessions.tsv` lock; `hub_run` opens
an SSH connection through the worker's tunnel port, runs
`beaut worker-exec <cpu> <mem> <disk> -- <cmd>`, and removes the session when it
finishes. No fit returns 4 (`503` over HTTP); an SSH/setup failure returns 5.

`beaut run` with `CLIENT_TOKEN` posts the shell-quoted command to `/run`. On a
hub host it bypasses HTTP and uses `CLIENT_EMAIL` or the first `ADMINS` entry.
`worker-exec` uses `systemd-run --user --scope` with `CPUQuota`/`MemoryMax`
when available, else `nice -n 10`; disk is advisory.

## Security notes

- Workers only dial out (NAT-friendly); the hub exposes `:8888` and sshd.
- The hub `tunnel` account accepts only keys from `tunnel_keys.tsv`, and the
  account itself has no login shell.
- Tokens are 128-bit, single-use, expire after `TOKEN_TTL_SECONDS`; client
  tokens are reusable bearer secrets, so use TLS and keep client configs private.
- Donated machines hold no secrets; owners can always inspect/kill the slice.

## Status

Implemented: steps 1–4 (scaffold, config/state/auth, HTTP app, stats, worker
enrollment/tunnel/quotas, scheduler + `run`).
Planned: step 5 QEMU/SPICE `vm`, step 6 mail inscription.
