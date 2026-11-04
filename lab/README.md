# beaut lab — orchestrator / router / neighbours

A small, standalone prototype of the beaut pool. It is pure bash, needs no
root and no network, and writes only under `$DIR` (`~/.beaut` by default).

```
worker ── heartbeat (resources, term) ──▶ orchestrator
client ── request (pubkey auth) ────────▶ orchestrator
orchestrator ── answer (worker, port, lease) ──▶ client
client ── ssh -p <tunnel port> ─────────▶ worker   (through the reverse tunnel)
orchestrator ── reap (stale heartbeat / expired lease) ──▶ kill tombstone
```

## Files

| file | role |
|---|---|
| `config.env` | core: identity, orchestrator, hub ports, tunnels, auth paths, tiers |
| `config.advanced.env` | router, neighbours, failover, dispatch/lease, exec caps |
| `lib/lab.sh` | config, TSV state, key auth, dispatch, reap/kill |
| `beaut-lab` | CLI: `init`, `client`, `worker`, `keys`, `heartbeat`, `request`, `answer`, `renew`, `run`, `release`, `reap`, `status` |
| `tests/run.sh` | hermetic smoke tests (`bash lab/tests/run.sh`) |

`config.advanced.env` is sourced automatically after `config.env` (same stem).
Override with `LAB_CONFIG` / `LAB_ADVANCED`.

## Auth — recognized as-is

Two authorized_keys files, no accounts, no tokens:

- `CLIENT_KEYS` (`$DIR/clients`) — a client is recognized **as-is** when its
  public key is a line in this file. `request` fingerprints the presented key
  and refuses anything not listed.
- `WORKER_KEYS` (`$DIR/workers`) — a worker is recognized when its key is in
  this file; that key may open the reverse tunnel to the orchestrator.

```sh
beaut-lab client add alice.pub alice     # append to $DIR/clients
beaut-lab worker add box1.pub            # append to $DIR/workers
beaut-lab keys orchestrator              # authorized_keys for the hub
beaut-lab keys worker                    # authorized_keys for a worker
```

`keys orchestrator` emits worker keys restricted to reverse forwarding
(`no-pty`, `permitlisten=*`). `keys worker` emits the same client keys
restricted to loopback forwarding (`permitopen="127.0.0.1:*"`), so the client
hops through the orchestrator into the worker's tunnel. Neither side gets a
shell or agent forwarding.

## Heartbeat → dispatch → answer

A worker announces its free capacity every `FAILOVER_HEARTBEAT_SECONDS`:

```sh
beaut-lab heartbeat --name box1 --addr 10.42.0.21 --cpu-total 8 \
  --cpu-free 6.5 --mem-free 8192 --disk-free 64 --port 22021 \
  --priority 10 --term 1
```

The orchestrator stores `last_seen`, `term` (fencing token) and `status=up`.
A heartbeat with a lower term is refused: an old leader cannot come back.

A client asks for a slice; the answer is written to `requests/<id>.ans`:

```sh
beaut-lab request --key alice.pub --cpu 2 --mem 1024 --disk 8
# s-...   ok      box1    10.42.0.21      22021   1       <lease> -
# s-...   denied -       -               -       0       0       no-capacity
```

Dispatch picks the live worker that fits, highest `priority` first, then most
free memory. CPU/mem/disk committed to `pending`/`running` sessions is
subtracted before the fit test.

## Leases and termination

Every session carries `lease_until`. `run` starts the command on the worker
under the caps from `config.advanced.env` (nice/ionice/ulimit by default;
`LAB_USE_SYSTEMD_RUN=1` uses `systemd-run --scope` with `CPUQuota`,
`MemoryMax`, `IOWeight`). Output goes to `$STATE_DIR/logs/<id>.out|.err`.

`reap` runs on the orchestrator and enforces two rules:

1. **Heartbeat** — a worker not seen for `WORKER_STALE_SECONDS` is marked
   `down` and all its pending/running sessions are terminated.
2. **Lease** — a session whose `lease_until` has passed is terminated unless
   the client renewed it (`beaut-lab renew <id>`).

Termination is a tombstone in `kill/<worker>/<id>` holding the pid. The worker
drains it: `SIGTERM` to the process group, then `SIGKILL` after
`KILL_GRACE_SECONDS`. The orchestrator drains its own worker name immediately,
so a single-host lab needs no extra step; remote workers run `beaut-lab reap`
(or fetch the same directory over the shared state volume).

## Quick run

```sh
cd lab
./beaut-lab init
./beaut-lab client add ~/.ssh/id_ed25519.pub me
./beaut-lab heartbeat --name "$(hostname -s)" --cpu-total 4 --cpu-free 4 \
    --mem-free 4096 --disk-free 32 --port 22000 --priority 100 --term 1
out=$(LAB_CLIENT_KEY=~/.ssh/id_ed25519.pub ./beaut-lab request --cpu 1 --mem 256 --disk 1)
id=${out%%$'\t'*}
./beaut-lab run "$id" -- sleep 300
./beaut-lab renew "$id"
./beaut-lab status
./beaut-lab release "$id"
```

## Limitations

- State is TSV on a shared filesystem; remote workers must see `$STATE_DIR`.
- The HTTP app, TLS and the actual `autossh -R` wiring are not part of this
  prototype (beaut's `lib/http.sh` owns the real hub).
- `ROLES` is informational here; `orchestrator` and `router` are lab roles, not
  beaut's `hub|worker|client` validator.
- `EXEC_MEMORY_MAX="512G"` in `config.advanced.env` is inherited from the
  simplified config; lower it (e.g. `512M`) to make the cap meaningful.
