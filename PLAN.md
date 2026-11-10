# beaut — architecture plan

## Direction

A minimal shared-computing fabric built from plain bash, git and SSH. The
control server publishes scripts and metadata; nodes fetch and run them
(`curl … | sh`). The server never computes work. Complexity grows in layers,
and every surface stays replaceable: no backcompat aliases, no hidden modes.

## Current foundation

- **HTTP control plane** — `http_server.sh` (socat or the C relay) and
  `http_handler.sh`. Fictive work ids, `/work/<id>` returning
  `$SVR_ROOT/command`, `/done/<id>` archiving results, static trees limited to
  `PUBLISHED_ROOT` and `SVR_ROOT`.
- **Personal tree** — `SVR_ROOT` (`~/.svr`) is a separate git repository.
  `$PUBLISHED_ROOT/$SVR_NAME` is a symlink to it; `SVR_NAME` is generated once
  and persisted. `scripts/` is linked inside the tree while `/scripts/` stays
  public. Server-side trees accept pushes (`updateInstead`), so an authenticated
  `git push` updates the served checkout.
- **Journal** — independent git-backed markdown trees (`~/journal` by default,
  `$SVR_ROOT/perso` for the personal one), reference-compatible layout
  `YYYY/MM/DD/<subfolder>/<name>.md`, generated index, hard-link host view,
  pull/commit/push. Commands are installed by `svr install`.
- **Identity** — per-device WireGuard keys, a TSV registry, hashed passMessage
  invites, approval/revocation, and a default door. HTTP records pending
  devices; it never approves.
- **Network** — idempotent WireGuard server/client helpers and convergent
  `nft`/`iptables` rules. Not available in `--no-root` mode.
- **Deployment** — `deploy.sh` auto-detects an existing `SERVICE_USER`; a fresh
  host is bootstrapped as root, then everything runs as the service user.
  `sync_site.sh` swaps the published tree atomically; the root-owned script
  copy is refreshed by `install_privileged.sh`.
- **State** — TSV tables under `STATE_DIR` (`db.tsv`, device and invite
  registries, archives). Git is the safety mechanism for data duplication.

## Target layers

1. **`.svr` client environment** — `~/.svr`, a small local directory holding
   keys, configured remotes and the journal command. The current personal tree
   is the first slice; it should feel like a checkout, not a service.
2. **Fabric** — identity (keys, invites), network (WireGuard), policy (trust
   and access), scheduler (work ids -> leases -> results), gateway (HTTP).
   Each part is a library with a thin CLI.
3. **Services** — git-backed, containerized units. A service is a repository
   plus a manifest; deploy pulls it and lets the init system run it. The HTTP
   handler stays a static file server and control API; it never executes work.
4. **State** — TSV until volume demands more. Archives and git remotes provide
   durability; worker-memory RAID is deferred.
5. **Edge** — connection statistics derived from firewall state, pruning of
   stale peers, and a one-command OS bootstrap.

## Roadmap

- **Wiki**: markdown inside a journal repository, browsable over HTTP, writable
  by git push with public-key authentication. Server remotes use
  `receive.denyCurrentBranch=updateInstead` so a push updates the served tree.
- **One-command bootstrap**: `curl …/svr | sh` installs the client environment,
  keys and journal command on a fresh OS.
- **Scheduler**: promote fictive ids into a real queue with leases, retries and
  result validation. Keep the node protocol (`/work`, `/done`, `/get`) stable.
- **Container services**: a git-backed service catalog with per-service
  manifests, deployed by the service user; no long-running logic in the
  handler.
- **Edge pruning**: derive peer liveness from firewall counters and WireGuard
  handshakes; expire inactive devices.
- **Worker memory RAID**: deferred until the service layer exists.

## Invariants

- The server serves; it does not compute.
- `config.env.example` is the schema; environment variables win.
- Generated paths are symlinks or state, never uploaded payload.
- No legacy aliases or migration paths in normal operation.
- `tests/run.sh` stays green without root, real WireGuard or external network.
