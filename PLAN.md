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
- Le serveur détruit le token après `TOKEN_TTL_SECONDS`.
- Si le travail est rendu dans les temps, le token reste archivé un temps comme preuve de travail prototypique, valorisable ultérieurement en privilèges (plus un node a travaillé, plus il peut utiliser de ressources mais laisser ce concept virtuel).
- Le réseau est supposé privé ; la vérification croisée par un node différent est non imposée mais possible en cas de doute grace a l'archivage ou une verification aleatoire (randomnumber of 1 \ VERIF_RATIO ex:controle only 1 result of 3 results sample).

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
- Archivage toute les heures sous `state/archive/YYYY-MM-DD/`.
- `ARCHIVE_MEMORY_DIVISOR` : l'archivage est ignoré si la RAM disponible est
  inférieure ou égale à la RAM totale divisée par ce diviseur (défaut 5, soit 20%).

## Déploiement (`deploy.sh`) — deux temps, une bascule d'identité
1. **`BOOTSTRAP_USER`** (root conseillé, demandé au lancement) applique
   `deploy/files/bootstrap.sh` : crée `SERVICE_USER=beaut`, autorise la clé
   publique, installe la **copie root:root** des scripts, écrit la config racine
   depuis `config.env.example` + les 3 overrides (`SERVICE_ROOT`, `STATE_DIR`,
   `PUBLISHED_ROOT`), accorde le sudo passwordless à `SERVICE_USER`.
2. Tout le reste se fait en **`SERVICE_USER`**, par clé uniquement (`BatchMode`,
   `publickey`), sans mot de passe, dans `$HOME/.beaut` : `scripts/`, `deploy/`,
   `state/`, `shared/`. Le démarrage du service est piloté par
   `deploy/files/remote_install.sh` (exécuté via `remote_run`).

- `sudo` passwordless est accordé à `SERVICE_USER` via `/etc/sudoers.d/<SERVICE_USER>`
  (règle `ALL=(ALL) NOPASSWD: ALL`, validée avec `visudo`) : l'accès réseau/WireGuard
  passe par la copie root.
- `--no-root` : mode utilisateur, sans sudo, sans WireGuard.
- WireGuard est **idempotent** (`scripts/lib/wireguard.sh`) : clés réutilisées,
  interface `wg0` conservée si déjà configurée, chaînes `nft`/`iptables`
  reconstruites vers un seul jeu de règles. La clé publique du serveur reste
  stable entre déploiements.
- Publication : `shared/node/DEFAULT.sh` est généré avec `SERVER_HOST` et
  `HTTP_PORT` figés et **aucun fichier sourcé**, en `sh` POSIX. `/join` n'est
  plus publié ; `scripts/wireguard_join.sh` reste une commande du dépôt.
- Serveur lancé en service utilisateur systemd (`deploy/files/beaut.service`),
  secours `setsid` (fallback via `remote_install.sh`).
- À l'issue : le serveur est joignable via le listener `socat` ou le relay C
  compilé (`scripts/http_server.c`), `curl /node | sh` fonctionne sans fichier
  client.
- Mise à jour et synchronisation des scripts par **git** (`git pull`).

## Attribution virtuelle (secrets / chemins)

`scripts/attribution.sh` est une fonction générique et réutilisable, indépendante
de WireGuard : elle associe un **chemin virtuel** aléatoire à une ressource
(secret, clé, service, requête, dataset, ...). Le chemin n'existe jamais sur
disque ; seul le registre (`state/attributions/registry.tsv`) porte la
correspondance. Le chemin est une phrase de dictionnaire + suffixe hexadécimal.

- `create`, `ensure` (réutilise l'identité `kind/name`), `resolve`, `rotate`,
  `remove`, `list`.
- Paramètres : `ATTRIBUTION_DIRECTORY`, `ATTRIBUTION_REGISTRY`,
  `ATTRIBUTION_WORD_COUNT`, `ATTRIBUTION_SECRET_BYTES`,
  `ATTRIBUTION_PATH_NAMESPACE`, `ATTRIBUTION_DICTIONARY`.

## Tests

Sous-projet `tests/` : `tests/run.sh`. Aucun root, aucun réseau externe, aucun
WireGuard réel. Chaque test lance le relay C sur `127.0.0.1` avec un état
temporaire et couvre : cycle de vie des tokens, TTL, arborescence statique, 404,
traversée, `curl /node | sh` depuis un dossier vide, `/join` non publié,
attributions virtuelles, réutilisation des clés WireGuard et idempotence du
pare-feu (commandes factices), `bash -n` / `gcc -fsyntax-only` / `git diff --check`.

## Configuration
Tout est défini dans `config.env` et `config.env.example` (le modèle sert aussi
de schéma de repli). Le chargement se fait avec `set -a`, donc **tout est exporté
automatiquement** : aucune liste d'export à maintenir.

## Fichiers clés
```
config.env                  variables d'environnement (éditables à la main)
config.env.example          modèle + schéma de repli
deploy.sh                   orchestrateur client SSH/SFTP (BOOTSTRAP_USER puis SERVICE_USER ; --no-root = user)
deploy/files/bootstrap.sh   première application en root : utilisateur, clé, config racine, sudo grant
deploy/files/remote_install.sh   phase utilisateur : service systemd + demarrage du serveur
deploy/files/beaut.service  service utilisateur systemd
deploy/files/start.sh       script de démarrage (fichier à part, jamais inline)
scripts/http_server.sh      chaine de listeners : socat → relay C → fail
scripts/http_server.c       relay TCP minimal (socat-enough, gcc)
scripts/http_handler.sh     handler serveur (routes + arborescence, pas d'exécution)
scripts/lib/http.sh         réponses HTTP, parsing, form, client http_request
scripts/lib/state.sh        TSV unique + helpers token_create/token_find/token_field
scripts/node.sh             script node POSIX autonome (| sh), réclame + exécute + rapporte
scripts/build_published_node.sh  génère /node avec l'adresse figée, sans source
scripts/network.sh          wrapper WireGuard + pare-feu
scripts/lib/wireguard.sh    helpers WireGuard/pare-feu idempotents
scripts/attribution.sh      CLI d'attribution virtuelle (secrets/chemins)
scripts/lib/virtual_path.sh algorithme passphrase/chemin/registre
scripts/lib/core.sh         chemins, config, log, état
tests/                      sous-projet de tests isolé (tests/run.sh)
state/db.tsv                base d'état (tokens, travaux, résultats)
shared/                     arborescence HTTP servie (path = fichier, dossier = DEFAU*.sh)
```
