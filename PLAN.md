# beaut — PLAN technique (synthétique)

## Vue d'ensemble
Plateforme de calcul partagé minimaliste. Le serveur ne calcule jamais : il **sert des scripts** aux nodes (`curl … | sh`) et valide des **tokens** de travail. Chaque token lie une tâche à un résultat, avec un TTL configuré. Après expiry, le token est auto-brûlé par le serveur.

## Terminologie
- **node** : ordinateur qui réclame un travail, l'exécute et rapporte le résultat. (Jamais "client".)
- **serveur** : hôte de contrôle qui expose l'HTTP et stocke l'état TSV.

## Token (authentification + preuve de travail)
- Créé à chaque requête de travail (`GET /work`).
- Identifie de façon unique une tâche proposée à un node.
- Le node doit utiliser ce token pour rendre son résultat (`POST /done/<token>`).
- Le serveur détruit le token après `TOKEN_TTL_SECONDS` (pas de route `/burn`).
- Si le travail est rendu dans les temps, le token reste archivé un temps comme preuve de travail prototypique, valorisable ultérieurement en privilèges (plus un node a travaillé, plus il peut utiliser de ressources).
- Le réseau est supposé privé ; la vérification croisée par un node différent est favorisée mais non imposée.

## Routes HTTP (serveur)

| Chemin | Méthode | Rôle |
|--------|---------|------|
| `/work` | GET | Crée un token, assigne une tâche, renvoie le token au node |
| `/work/<token>` | GET | Renvoie la commande/dataset associée au token (si valide et non expiré) |
| `/done/<token>` | POST | Le node POSTe son résultat ; le token lie travail et résultat |
| `/get` | POST | Requête dataset sur mesure (corps `cle=val&cle=val`) ; privilèges vérifiés via token |
| `/<chemin>` | GET | Arborescence `PUBLISHED_ROOT` (dossier → premier `DEFAU*.sh`) |
| autre | GET | `NOT_FOUND_BODY` (variable configurable) |

## Parsing
Aucune bibliothèque de parsing HTTP. On lit uniquement :
1. La première ligne (`METHOD /path HTTP/1.1`) pour extraire le chemin.
2. Les en-têtes jusqu'à la ligne vide, pour `Content-Length`.
3. Exactement `Content-Length` octets de corps pour les POST (jamais de `cat` bloquant sur un GET).

## Données (TSV unique)
- `state/db.tsv` : une seule table avec colonne `type` (token, task, result, archive).
- Archivage journalier sous `state/archive/YYYY-MM-DD/`.
- `ARCHIVE_MEMORY_DIVISOR` : l'archivage est ignoré si la RAM disponible est
  inférieure ou égale à la RAM totale divisée par ce diviseur (défaut 5, soit 20%).

## Déploiement (`deploy.sh`) — deux temps, une bascule d'identité
1. **`BOOTSTRAP_USER`** (root conseillé, demandé au lancement) applique
   `deploy/files/bootstrap.sh` : crée `SERVICE_USER=beaut`, autorise la clé
   publique, installe la **copie root:root** des scripts, écrit la config racine
   depuis `config.env.example` + les 3 overrides (`SERVICE_ROOT`, `STATE_DIR`,
   `PUBLISHED_ROOT`), installe le helper `s$SERVICE_USER`.
2. Tout le reste se fait en **`SERVICE_USER`**, par clé uniquement (`BatchMode`,
   `publickey`), sans mot de passe, dans `$HOME/.beaut` : `scripts/`, `deploy/`,
   `state/`, `shared/`. Le démarrage du service est piloté par
   `deploy/files/remote_install.sh` (exécuté via `remote_run`).
- `sudo` n'est accordé que pour les ressources spéciales : une seule règle
  `NOPASSWD` vers `/usr/local/sbin/s$SERVICE_USER` (réseau/WireGuard). Le helper
  n'exécute que la copie root, jamais le code modifiable par `SERVICE_USER`.
- WireGuard sécurise les connexions entre clés reconnues.
- Serveur lancé en service utilisateur systemd (`deploy/files/beaut.service`),
  secours `setsid` (fallback via `remote_install.sh`).
- À l'issue : le serveur est joignable via le listener `socat` ou le relay C
  compilé (`scripts/http_server.c`), `curl /node | sh` récupère le script node.
- Mise à jour et synchronisation des scripts par **git** (`git pull`).

## Configuration
Tout est défini dans `config.env` et `config.env.example` (le modèle sert aussi
de schéma de repli). Le chargement se fait avec `set -a`, donc **tout est exporté
automatiquement** : aucune liste d'export à maintenir.

## Fichiers clés
```
config.env                  variables d'environnement (éditables à la main)
config.env.example          modèle + schéma de repli
deploy.sh                   orchestrateur client SSH/SFTP (BOOTSTRAP_USER puis SERVICE_USER)
deploy/files/bootstrap.sh   première application en root : utilisateur, clé, config racine, sudo limité
deploy/files/remote_install.sh   phase utilisateur : service systemd + demarrage du serveur
deploy/files/sbeaut         helper root des ressources spéciales (installé en s$SERVICE_USER)
deploy/files/beaut.service  service utilisateur systemd
deploy/files/start.sh       script de démarrage (fichier à part, jamais inline)
scripts/http_server.sh      chaine de listeners : socat → relay C → fail
scripts/http_server.c       relay TCP minimal (socat-enough, gcc)
scripts/http_handler.sh     handler serveur (routes + arborescence, pas d'exécution)
scripts/lib/http.sh         réponses HTTP, parsing, form, client http_request
scripts/lib/state.sh        TSV unique + helpers token_create/token_find/token_field
scripts/node.sh             script node (| sh), réclame + exécute + rapporte
scripts/network.sh          WireGuard + pare-feu (source unique)
scripts/lib/core.sh         chemins, config, log, état
state/db.tsv                base d'état (tokens, travaux, résultats)
shared/                     arborescence HTTP servie (path = fichier, dossier = DEFAU*.sh)
```
