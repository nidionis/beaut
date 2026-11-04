# beaut

Recycle spare compute by mutualising resources. Pure bash. One host can be a
`hub`, a `worker`, a `client`, or any combination.

```
owner:  curl http://hub:8888/give50 | sudo sh      # donate 50%
client: beaut run <cmd>  /  beaut vm
admin:  http://hub:8888/                            # stats + enrollment
```

**Status:** steps 1–4 of 6 are implemented — scaffold, config/state/auth, the
HTTP stats/enrollment app, worker enrollment with reverse SSH tunnels and
quotas, and the hub scheduler with `beaut run`. Graphical VM sessions (step 5)
and mail inscription (step 6) are planned. See
[docs/architecture.md](docs/architecture.md) for the full contract and
[.junie/plans/beaut-bash-resource-bot.md](.junie/plans/beaut-bash-resource-bot.md)
for the delivery plan.

## Quick start

```sh
# hub, as root
sudo ./install.sh --roles hub --domain pool.example.org --deps
sudo systemctl status beaut

# worker, on a machine donating capacity
curl -fsSL http://pool.example.org:8888/give50 | sudo sh

# client, after an admin issues a token
beaut token issue alice@example.org            # on the hub
curl -fsSL http://pool.example.org:8888/client/<token> | sh
beaut run uname -a

# no install needed for the CLI
./bin/beaut --help
./bin/beaut config
./bin/beaut status
```

## Roles

| role | does |
|---|---|
| `hub` | HTTP app on `:8888`, worker registry, scheduler, mailbox poller |
| `worker` | donates N% of CPU/RAM/disk, keeps a reverse SSH tunnel to the hub |
| `client` | `beaut run <cmd>`, `beaut vm` |

Roles are composable: `ROLES="hub,worker,client"` or `--roles hub,worker`.

## Layout

```
bin/beaut          dispatcher: options, roles, subcommands
lib/common.sh      config, state dir, logging, TSV + tiers
lib/auth.sh        users, tokens, client tokens, SSH keys, admins
lib/http.sh        HTTP app on :8888
lib/stats.sh       capacity snapshot (text + JSON)
lib/worker.sh      enrollment, reverse SSH tunnel, heartbeat, quota exec
lib/hub.sh         scheduler, reservation, remote execution, hub key
lib/client.sh      `beaut run` over HTTP or locally on the hub
install.sh         one-command bootstrap
beaut.service      systemd unit (`beaut daemon`)
tests/run.sh       smoke tests (no root, no network)
```

## Docs

- [HOWTO.md](HOWTO.md) — install, configure, operate
- [HOWITWORKS.md](HOWITWORKS.md) — internals and data flow
- [docs/architecture.md](docs/architecture.md) — detailed design

## Tests

```sh
bash tests/run.sh
```
