# Making `beaut run` work — plan v2

Observed (2026-10-22):

```
beaut approve <id> 3      → appended a third line (priv.tsv now 3,2,3)
beaut run 2cheval.fr …    → no worker available
beaut peers               → (empty)
```

Decisions taken in this revision:

- **P1 is the C event protocol** (socket, one binary), not SSH pull. `A`
  (SSH/`sync`) stays only as an offline/bootstrap fallback, and whatever the
  carrier, **identity is checked on every request** (P2), not once per
  heartbeat or per connection.
- **P0 is self-hosted**: a request addressed to a domain or IP must be routed
  through orchestrator/router and **executed locally when this is the only
  node**.

## 1. Root causes (unchanged)

1. No live heartbeat: `peers` counts `heartbeat` entries younger than
   `BEAUT_STALE_S=90`; nothing emits them. `beaut heartbeat; beaut peers`
   works, then expires.
2. `pick` refuses a single node: `src/orch.c:184`
   `if (n < C.reserve_nodes + 1) return -1;` with `reserve_nodes=1`.
3. `approve` appends; `auth()` returns the first match, so 3,2,3 means “3 by
   accident”; `pending.tsv` keeps four duplicates.
4. No transport: `log.enc` is local per host; `deploy` copies binaries only.
5. `watch` skips self-originated tasks: `[ "$worker" = "$me" ] && continue`.
6. `peers` cores is a constant: heartbeat sends `ip:load`, readers default to
   `BEAUT_PEER_CORES=4`.

---

## 2. P0 — self-hosted core (orchestrator + router + local fallback)

Goal: `beaut run <domain|ip> <cmd>` works on a single machine through the same
path it would use on a cluster, and never says “no worker” when a valid local
executor exists.

### 2.1 Target resolution

```
beaut run <target> <cmd>
  target = IPv4 / IPv6        → that node
  target = domain             → a live worker advertising that domain
  no candidate                → self, if self is a worker for that domain
                                (or any worker when the domain is unset)
```

- The heartbeat advertises `domain` (from `BEAUT_DOMAIN`), `cores` and `load`;
  the scheduler filters by domain before ranking.
- The candidate set is **live peers ∪ {self}**. Self is always a candidate:
  `reserve_nodes` applies to *remote* peers only and must never exclude the
  machine that is running the request.
- `pick` returns the chosen IP; when the answer is this node's IP, `run` posts
  a task addressed to itself and `watch` executes it. When `pick` is empty,
  `run` falls back to self if this node is a worker for the target domain.

### 2.2 Roles, one binary

`beaut` becomes the only binary with three roles, all listening on the same
protocol:

| role | does | never does |
|---|---|---|
| `router` | terminates external connections, verifies request, forwards to orchestrator | execute |
| `orchestrator` | verifies, schedules by domain/load, forwards to a worker or itself | execute remote payload directly (except when also a worker) |
| `worker` | verifies, executes, posts `result`/`fail` | schedule or forward |

- Single-machine mode: `router` and `orchestrator` are the same process; the
  request goes `run → orchestrator → self`, and `run` returns immediately with
  a local `request_id`.
- The separate `beaut-router` ELF is retired; `beaut router` (or
  `beaut watch --listen --role router`) is the front door.
- Orchestrator and router can be co-located; a worker-only node still runs a
  minimal local orchestrator so `run` works there too.

**Roles are composable** (`ROLE="worker,client"`), because the graph has three
legitimate edges:

```
orchestrator → worker                  dispatch
worker       → (orchestrator + client) report results + ask for work
client       → (orchestrator + worker) submit + receive results
```

- `install.sh` writes `ROLE` and `BEAUT_CAPS` as a normalised, quoted list and
  exports `BEAUT_DOMAIN` (`router`→`vm`, `worker`→`worker`, otherwise first cap).
- Every node keeps a **local orchestrator+router**; `BEAUT_CAPS` only says what
  is advertised publicly.
- `watch` requires `worker`; `run` requires level ≥ 2 and refuses to target
  self when this node is client-only.
- `client → (orchestrator + worker)` is the abusive case: an orchestrator may
  `nice` or kill the process it started for a client (see 2.5).

### 2.5 Abuse control (nice / kill)

Execution is always sandboxed by policy, whether the client is local or remote:

| knob | default | effect |
|---|---|---|
| `BEAUT_NICE` | 10 | nice level of every task |
| `BEAUT_EXEC_TIMEOUT_S` | 300 | hard kill via `timeout` |
| `BEAUT_MAX_CONCURRENT` | 1 | processes per client; beyond → nice 19 or kill |
| `BEAUT_RATE_LIMIT` | 60 | accepted requests per client per 60 s |
| `BEAUT_ABUSE_ACTION` | `nice` | `nice` (throttle) or `kill` (terminate tree) |

- Tasks are launched in the background so `watch` keeps reading the log and can
  act on a later abusive request.
- `kill` terminates the whole process tree (subshell → `nice`/`timeout` →
  payload), not just the wrapper.
- Every decision is appended to `connections.log` as `EXEC_START`,
  `EXEC_THROTTLED`, `EXEC_BLOCKED` or `EXEC_KILL`.

### 2.3 Self execution

- Remove the blanket `worker == me` skip. Deduplicate by **event id**
  (`stamp:seq` or `sha256(header)`), not by hostname.
- A task with `target == myip` (or `local` flag) is executed by the local
  executor when `BEAUT_ALLOW_EXEC=1` and the caller’s level allows it.
- Result/fail events keep the same shape, so a local run and a remote run are
  indistinguishable in the log.

### 2.4 P0 fixes folded in

| # | change | where |
|---|---|---|
| 1 | heartbeat at `watch` start + every `BEAUT_HEARTBEAT_S` | CLI `watch` |
| 2 | `SCHEDULER_RESERVE_NODES` default 0, remote-only | `src/orch.c` `cfg_init`/`pick` |
| 3 | self is a candidate via its own heartbeat; `run` adds one if needed | `src/orch.c`, CLI `run` |
| 4 | domain + real `cores` in heartbeat payload | `c_heartbeat`/`peers_scan` |
| 5 | `auth()` = max level; `approve` = exact level 1..3, collapses duplicates, clears pending, refuses to demote the last admin | `c_auth`/`c_approve` |
| 6 | `join` refuses already pending/approved ids | `c_join` |
| 7 | remove self-skip; dedupe by task stamp/event hash | CLI `watch` |
| 8 | explicit errors (`no worker for domain`, `level < N`, client-only self) | CLI `run` |
| 9 | `beaut priv dedupe` one-off migration (priv + pending) | CLI/C |

**Status:** implemented and exercised on 2026-10-22 (single node, 64 px not
involved): self-run, IP-target, composable caps, level gates, approve upsert,
join dedupe, rate-kill. Remote frames remain P1.

---

## 3. P1 — C event protocol (chosen)

One binary, length-prefixed frames, no separate daemon language.

### 3.1 Transport

- `beaut router --listen ADDR:PORT` and
  `beaut orchestrator --listen ADDR:PORT` (or `watch --listen … --role …`).
- Plain TCP by default; optional TLS/Noise later. **Security does not depend on
  the socket**: every frame is an AEAD envelope plus a per-request signature.
- Connection is open by default: no allow-list at accept time. Identity is
  established by the first request and re-checked on each one.

### 3.2 Frame

```
AAD  = { version, stamp, seq, kind, target, origin, ts, nonce }
body = XChaCha20-Poly1305(plaintext, key=cluster_key, aad=AAD)
sig  = Ed25519(device_key, sha256(AAD || body))        # per request
frame = len(4) || AAD || body || sig
```

Kinds: `request`, `result`, `fail`, `heartbeat`, `open`, `close`,
`missing`, `resend`.

- `nonce` + `ts` give replay protection (seen-cache + clock window).
- The router forwards the frame unchanged; the orchestrator and the worker each
  verify it. No hop is trusted.

### 3.3 Why A (SSH pull) is demoted

- It cannot carry per-request verification without turning into a protocol of
  its own, and it needs an out-of-band schedule.
- Keep `beaut sync <peer>` only for: first bootstrap, offline sites, and the
  stegano channel. It stays a log merge (dedupe by event id) and is never a
  substitute for a request path.

---

## 4. P2 — identity checked on every request

“Approval” is no longer a door: a connection is open, and each request proves
who sent it and at what level.

### 4.1 Key split (prerequisite)

```
BEAUT_PASSWORD → Argon2id → cluster_key     # encrypts log and frames
device            → Ed25519 keypair         # signs every request
$PREFIX/etc/device.key (0600)               # private half
priv.tsv:  id \t pk \t level                # public half, real key now
```

Today `pk` is a hash of the password and is unused; each device needs its own
generated keypair, registered through `join` → `approve`. Migration:
`beaut priv migrate` creates `device.key` once and re-registers the device.

### 4.2 Check order on every request (router, orchestrator, worker)

1. frame bounds and version;
2. `stamp/seq` not seen recently (replay cache, LRU);
3. `ts` within ±30 s;
4. AEAD open with `cluster_key`;
5. `id` → `pk` in `priv.tsv`; signature verifies;
6. level ≥ action requirement;
7. only then schedule / forward / execute.

A heartbeat is a **key-proof signal** (`open`/`tick`/`close`), not a bypass: it
proves the key and refreshes presence, but every subsequent request is verified
again.

### 4.3 Levels

| level | name | may |
|---|---|---|
| 3 | admin | approve, ban, config |
| 2 | client | `run` (ask for work) |
| 1 | worker/invited | `watch`, execute, `heartbeat` |
| 0 | unknown | `join` only, never `run` |

Enforced in the CLI today (clear errors, local boundary). P1/P2 moves the same
matrix into C at the request boundary; until then a local user can still call
`$PREFIX/lib/beaut/beaut-bin` directly.

---

## 4.4 Implementation notes (2026-10-22)

The installed transport is a **hub/peer mirror of the signed log**, still one C
binary; it keeps the P1/P2 guarantees without a second frame format:

- `beaut hub [port]` — orchestration/router front door. It verifies every
  incoming record with the cluster key + the origin's Ed25519 key, appends it
  to its own `log.enc`, and rebroadcasts it to the other connected peers.
- `beaut peer <host> [port]` — tails this node's log and sends new records to
  the hub; verifies and appends records coming back. Run it next to `watch`
  on workers and clients.
- `beaut push <host> [port]` — one-shot variant used by `run` when the target
  is remote: sends the last local record and pulls the hub's recent ring, so a
  task can leave the node even if no long-lived peer is running. Results are
  delivered asynchronously; keep `peer` running to receive them live.
- Wire record (newline-delimited, exactly the log line):
  `outer_ts hex(XChaCha20-Poly1305(v2 \t ts \t id \t nonce \t sig \t worker \t action \t payload))`.
- The signature covers
  `beaut1\n ts \n id \n nonce \n worker \n action \n payload`; `id` is the
  first 8 bytes of `sha256(device_pk)`, and the receiver resolves `id → pk`
  from `priv.tsv` before checking the signature.
- `log_read` drops anything unsigned, tampered, expired, or from an id below
  level 1. `watch` additionally refuses `task` records below level 2.
- The hub has a per-connection record rate (`BEAUT_HUB_RATE`, default 240/min)
  and closes a peer after repeated invalid records. A 512-record in-memory
  ring deduplicates relays and replays.
- Abuse controls stay where the process runs: `watch` applies `nice`/kill by
  the authenticated origin id, not by a forgeable hostname.

Enrollment is still explicit: `beaut join` prints an id; the admin runs
`beaut approve <id> <level> [pk]` (pending file or supplied public key), then
copies the resulting `~/.beaut/etc/priv.tsv` to each node. Every node needs the
same table to verify the others. Automatic `priv.tsv` distribution over the hub
is not implemented yet.

Verified on 2026-10-22 with two isolated state directories on one host:
heartbeats propagated both ways, a task posted on B executed on A, its result
returned to B, a forged/tampered record was dropped, and a valid level-1 task
was refused with `EXEC_BLOCKED`.

**Status:** P1 hub/peer and P2 per-request verification implemented; `priv`
distribution and TLS/Noise remain future work.

---

## 5. P3 — stegano transport

`docs/stegano-plan.md` becomes another carrier for the exact same frames.
Because P1 frames are self-authenticating, a PNG package needs no extra
security: unpack → verify per request → same path.

---

## 6. Acceptance

P0 (verified locally):

1. **Single node, no peers:** `beaut run worker 'echo test'` resolves to self,
   executes with `BEAUT_ALLOW_EXEC=1`, logs `result`.
2. `beaut run <self-ip> 'echo test'` behaves the same.
3. `beaut run <domain>` with one worker advertising that domain → that worker.
4. `beaut run` with no executor for the domain → explicit
   `no worker for domain X`; client-only self → `client-only node`.
5. Composable installs: `worker,client`, `orchestrator,worker` both run their
   own requests; `client` alone refuses to execute.
6. Level 1 `run`/`approve` refused by the CLI; levels are enforced in C for
   `approve`/`ban` at P2.
7. `approve` twice → one line, exact level, pending cleared; demoting the last
   admin refused.
8. `join` twice → `already pending` / `already approved`.
9. Rate abuse with `BEAUT_ABUSE_ACTION=kill` → `EXEC_BLOCKED` + `EXEC_KILL`,
   and no orphan `sleep`/payload process remains.
10. `beaut priv dedupe` collapses `priv.tsv` 3,2,3 → one line and drops
    already-approved ids from `pending.tsv`.

P1/P2 (still open):

11. Two nodes, C protocol: `peers` shows both; router forwards; worker executes;
    `run` returns a result.
12. Replay a captured frame → rejected (nonce/ts).
13. Tamper `AAD.target` → AEAD fails.
14. Router never executes, even if `BEAUT_ALLOW_EXEC=1` on the router.
15. No heartbeat for `BEAUT_STALE_S` → node leaves `peers`; its in-flight
    requests still verify or fail on the per-request checks.

## 7. Local smoke test

```bash
BEAUT_ALLOW_EXEC=1 beaut watch &        # executor (local orchestrator path)
beaut run worker 'echo hello'           # → posted -> <self-ip>
beaut peers                             # name ip load cores domain
BEAUT_RATE_LIMIT=1 BEAUT_ABUSE_ACTION=kill beaut watch   # abuse test
```
