# beaut tests

A self-contained test subproject. It needs **no root, no WireGuard, and no
external network**: every server runs on `127.0.0.1` with temporary state.

## Run

```bash
tests/run.sh                 # every test
tests/run.sh --verbose       # show passing logs too
tests/run.sh --filter handler
tests/run.sh --list
```

A single test can also run directly:

```bash
bash tests/handler_test.sh
```

Dependencies: `bash`, `curl`, `gcc`, `mktemp`. `dash` is used as an extra POSIX
syntax check when present, and `git` lets `site_test.sh` exercise clone/pull.
The compiled relay lives in `tests/.build/` (git-ignored), never in `/tmp`,
because some systems mount `/tmp` `noexec`.

## Layout

| File | Coverage |
|------|----------|
| `lib/assert.sh` | assertions (`equal`, `contains`, `matches`, `status`, ...) |
| `lib/server.sh` | compile and run the C relay on loopback, isolated roots |
| `handler_test.sh` | token lifecycle, `/done`, `/get`, static tree, index.html, MIME, hidden paths, 404, traversal, TTL |
| `served_node_test.sh` | `curl /node \| sh` from an empty directory, `/join` unpublished |
| `site_test.sh` | complete `site/` replacement, reserved names, git clone/pull |
| `svr_test.sh` | hidden directory and URL path modes, journal under the secret prefix, migration, CLI install |
| `device_test.sh` | device registry, key reuse, addresses, approval, door, CLI |
| `invite_test.sh` | hashed passMessage, uses, expiry, revocation |
| `signin_test.sh` | `/signin`, invite auto-accept, `/signin/<id>`, `/door`, URL decoding |
| `journal_test.sh` | reference layout (YYYY/MM/DD), header, host view, git commits, installed command |
| `deploy_publish_test.sh` | server-rendered node artifact and deploy wiring |
| `virtual_path_test.sh` | create/ensure/resolve/rotate/remove, uniqueness, custom dictionary |
| `network_test.sh` | per-device keys, peer sync idempotence, firewall rules (fake commands) |
| `syntax_test.sh` | `bash -n`, `gcc -fsyntax-only`, `git diff --check`, POSIX artifact |

## Notes

- Each test owns a `mktemp -d` sandbox and stops its server in `EXIT` trap.
- `handler_test.sh` starts the C relay directly; the handler is the real
  `scripts/http_handler.sh`, with `STATE_DIR` and `PUBLISHED_ROOT` overridden.
- `site_test.sh` runs `site/deploy/files/sync_site.sh` against a temporary tree
  and a local bare git repository, so it never touches the real server.
- `network_test.sh` replaces `wg`, `ip` and `nft` with tiny fakes in a temporary
  `PATH`, proving key reuse and rule idempotence without touching the host.
- The suite deliberately does not test real WireGuard interfaces or real
  firewall state; those stay manual checks on the target host.
