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
lib/http.sh          (step 2) HTTP accept-loop + routing on :8888
lib/stats.sh         (step 2) stats gathering / rendering
lib/worker.sh        (step 3) give<N> enroll, reverse tunnel, caps, worker-exec
lib/hub.sh           (step 4) worker registry + scheduler
lib/vm.sh            (step 5) QEMU/SPICE sessions via .svr scripts
lib/mail.sh          (step 6) mailbox poll, join@ handling, replies, approval
install.sh           one-command bootstrap (system or --user)
beaut.service        systemd unit running `beaut daemon`
config.env.example   all settings, documented
tests/               bash smoke tests (`tests/run.sh`)
```

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
Numeric fields (ports, `TUNNEL_PORT_RANGE`, `GIVE_PCT`, `TOKEN_TTL_SECONDS`,
`MAIL_POLL_SECONDS`, `TIERS`) are validated at load. Note that derived values
written in the file (e.g. `MAIL_FROM="join@$DOMAIN"`) are expanded when the
file is sourced, so overriding `BEAUT_DOMAIN` does not recompute them.

## State (`$STATE_DIR`, default `/var/lib/beaut`, mode 0700, files 0600)

If `STATE_DIR` is set (config or env) and not writable, commands fail with a
clear error. Only the built-in default falls back to `$XDG_STATE_HOME/beaut`.

| file           | columns                                                                  |
|----------------|--------------------------------------------------------------------------|
| `workers.tsv`  | `name tunnel_port cpu_pct cpu_total mem_free_mib disk_free_gib last_seen` |
| `users.tsv`    | `email ssh_pubkey level(guest|registered|admin) approved_ts` (0 = pending) |
| `tokens.tsv`   | `token email created_ts used(0/1)`                                       |
| `sessions.tsv` | `id user worker kind(cmd|vm) cpu mem disk started_ts`                    |

Writers take an `flock` on `<file>.lock`; replacements are atomic (`mktemp` + `mv`).

## Tiers

```
guest       1 CPU  2048 MiB  16 GiB
registered  4 CPU  4096 MiB  32 GiB
admin      -1 -1 -1           # half of the chosen worker's free resources
```

A session must fit on a single worker.

## Security notes

- Workers only dial out (NAT-friendly); the hub exposes `:8888` and sshd.
- The hub `tunnel` account is restricted (no pty, forced command) — step 3.
- Tokens are 128-bit, single-use, expire after `TOKEN_TTL_SECONDS`.
- Donated machines hold no secrets; owners can always inspect/kill the slice.
