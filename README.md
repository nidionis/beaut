# beaut

Plateforme de calcul partagé minimaliste : un serveur de contrôle qui **sert des
scripts** et **valide des tokens**, des nodes qui viennent les chercher
(`curl … | sh`). Le serveur n'exécute jamais le travail.

## Déploiement

```bash
./deploy.sh              # distant : SSH/SFTP sur $DOMAIN
./deploy.sh --no-root    # local, sans privilèges
```

Le déploiement distant se fait en deux temps, avec une seule bascule d'identité :

1. **`$SUDOER`** (root conseillé, demandé au lancement) applique
   `deploy/files/amorce.sh` : crée `$NAME=beaut`, autorise votre clé publique,
   installe la copie root des scripts et le helper `s$NAME`.
2. Tout le reste se fait en **`$NAME`**, par clé uniquement (aucun mot de passe),
   dans `$HOME/.beaut` : `scripts/`, `deploy/`, `state/`, `shared/`.

WireGuard n'utilise qu'une règle sudo limitée : `NOPASSWD` vers
`/usr/local/sbin/s$NAME`. Le helper ne lit que la copie root
(`/usr/local/lib/beaut`), jamais le code modifiable par l'utilisateur.

## Routes HTTP

| Route | Rôle |
|-------|------|
| `GET /work` | crée un token, renvoie le token |
| `GET /work/<token>` | renvoie la commande associée |
| `POST /done/<token>` | enregistre le résultat lié au token |
| `POST /get` | requête dataset (`cle=val&cle=val`) |
| `GET /<chemin>` | arborescence `HTTP_FILE_ROOT` (lecture seule) |

La route statique reflète l'arborescence : `/a/b/c` sert `$HTTP_FILE_ROOT/a/b/c`,
et un dossier sert son premier `DEFAU*.sh` (`/backdoors` →
`$HTTP_FILE_ROOT/backdoors/DEFAU*.sh`). Aucune exécution côté serveur.

## Node

```bash
curl -fsS http://$DOMAIN:$HTTP_PORT/node | sh
```

Le node réclame un token, récupère la commande, l'exécute localement et POSTe le
résultat sur `/done/<token>`.

## Configuration (`config.env`)

- `NAME`, `SUDOER`, `SSH_KEY` : identité, première connexion, clé privée locale
- `DOMAIN` / `HTTP_PORT` : adresse et port du serveur
- `WG_PORT` / `WG_NET` / `WG_SERVER_IP` : WireGuard
- `TOKEN_TTL_SECONDS` : validité d'un token
- `HTTP_FILE_ROOT` : racine de l'arborescence servie (défaut `$DIR/shared`)
- `ERR404`, `HIST_MEM_MAX_RATIO`, `LOG_LEVEL`

`config.env` est ignoré par git (ne jamais committer de config locale).

## Fichiers

- `deploy.sh` — amorçage distant (SUDOER → NAME)
- `deploy/files/amorce.sh` — première application en root
- `deploy/files/sbeaut` — helper root des ressources spéciales (installé en `s$NAME`)
- `deploy/files/beaut.service` — service utilisateur systemd
- `deploy/files/start.sh` — démarrage du serveur (fichier à part, jamais inline)
- `scripts/http_server.sh` — `socat` + `http_handler.sh`
- `scripts/http_handler.sh` — routes + arborescence, sans exécution
- `scripts/http_exec.sh` — script node (`| sh`)
- `scripts/net.sh` — WireGuard + pare-feu (source unique)
- `scripts/lib/core.sh` / `scripts/lib/state.sh` — config/log et TSV unique
- `state/db.tsv` — tokens, travaux, résultats
- `shared/` — arborescence HTTP publiée
