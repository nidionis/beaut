# beaut

Plateforme de calcul partagé minimaliste : un serveur de contrôle qui **sert des
scripts** et **valide des tokens**, des nodes qui viennent les chercher
(`curl … | sh`). Le serveur n'exécute jamais le travail.

## Déploiement

```bash
./deploy.sh              # remote: SSH/SFTP to $SERVER_HOST
./deploy.sh --no-root    # local, no privileges
```

The remote deployment has two phases and a single identity switch:

1. **`BOOTSTRAP_USER`** (root recommended, prompted at launch) applies
   `deploy/files/bootstrap.sh`: creates `SERVICE_USER=beaut`, authorizes your
   public key, installs the root-owned script copy and the `s$SERVICE_USER` helper.
2. Everything else runs as **`SERVICE_USER`**, key-only (no password), inside
   `$HOME/.beaut`: `scripts/`, `deploy/`, `state/`, `shared/`.

WireGuard uses a single scoped sudo rule: `NOPASSWD` to
`/usr/local/sbin/s$SERVICE_USER`. The helper only reads the root copy
(`/usr/local/lib/beaut`), never user-writable code.

## Configuration

All defaults live in `config.env.example`, which doubles as the fallback schema;
`config.env` overrides it. Files are sourced with `set -a`, so every variable is
exported automatically — no export list to maintain.

- `SERVICE_USER`, `BOOTSTRAP_USER`, `SSH_PRIVATE_KEY`: identity and first connection
- `SERVICE_ROOT`, `STATE_DIR`, `PUBLISHED_ROOT`: layout and served tree
- `SERVER_HOST` / `HTTP_PORT`: control server address
- `WG_PORT` / `WG_NETWORK` / `WG_SERVER_IP`: WireGuard
- `TOKEN_TTL_SECONDS`: token lifetime
- `NOT_FOUND_BODY`, `ARCHIVE_MEMORY_DIVISOR`, `LOG_LEVEL`

`config.env` is git-ignored (never commit local configuration).

## Routes HTTP

| Route | Role |
|-------|------|
| `GET /work` | creates a token, returns it |
| `GET /work/<token>` | returns the bound command |
| `POST /done/<token>` | records the result bound to the token |
| `POST /get` | dataset request (`key=value&key=value`) |
| `GET /<path>` | `PUBLISHED_ROOT` tree (read-only) |

The static route mirrors the tree: `/a/b/c` serves `$PUBLISHED_ROOT/a/b/c`, and a
directory serves its first `DEFAU*.sh` (`/backdoors` →
`$PUBLISHED_ROOT/backdoors/DEFAU*.sh`). Nothing is executed server-side.

## Node

```bash
curl -fsS http://$SERVER_HOST:$HTTP_PORT/node | sh
```

The node claims a token, fetches the command, runs it locally and POSTs the
result to `/done/<token>`.

## Files

- `deploy.sh` — remote bootstrap (BOOTSTRAP_USER → SERVICE_USER)
- `deploy/files/bootstrap.sh` — first application as root
- `deploy/files/sbeaut` — root helper for privileged resources (installed as `s$SERVICE_USER`)
- `deploy/files/beaut.service` — systemd user service
- `deploy/files/start.sh` — server launcher (standalone file, never inline)
- `scripts/http_server.sh` — `socat` + `http_handler.sh`
- `scripts/http_handler.sh` — routes + tree, no execution
- `scripts/node.sh` — node script (`| sh`)
- `scripts/network.sh` — WireGuard + firewall (single source)
- `scripts/wireguard_setup.sh` / `scripts/wireguard_join.sh` — delegate to `network.sh`
- `scripts/lib/core.sh` / `scripts/lib/state.sh` — paths/config/log and the single TSV
- `state/db.tsv` — tokens, tasks, results
- `shared/` — published HTTP tree
