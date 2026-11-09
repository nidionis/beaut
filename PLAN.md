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
| `/signin` | GET/POST | Enrôlement d'un appareil (clé publique ; invite valide = acceptation auto) |
| `/signin/<id>` | GET | Statut d'un appareil (`pending` / `approved` / `revoked`) |
| `/door` | GET | Clé publique du serveur par défaut, endpoint et réseau WireGuard |
| `/<chemin>` | GET | Arborescence `PUBLISHED_ROOT` (fichier, sinon `index.html`, sinon premier `DEFAU*.sh`) |
| `/<secret>/...` | GET | Arborescence personnelle cachée (`SVR_MODE`) |
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

## Déploiement (`deploy.sh`) — identité auto-détectée
1. Le déploiement prouve d'abord que **`SERVICE_USER`** s'authentifie par clé et
   possède `sudo -n`. Si oui, aucun bootstrap n'est relancé. Sinon seulement,
   **`BOOTSTRAP_USER`** (root conseillé) applique `site/deploy/bootstrap.sh` :
   crée `SERVICE_USER=beaut`, autorise la clé publique, installe la **copie
   root:root** des scripts, écrit la config racine (surcharges d'abord, puis le
   schéma), accorde le sudo passwordless à `SERVICE_USER`.
2. Tout le reste se fait en **`SERVICE_USER`**, par clé uniquement (`BatchMode`,
   `publickey`), sans mot de passe, dans `$HOME/.beaut` : `site/` (l'arborescence
   publiée avec ses builtins), `state/`. Le démarrage du service est piloté par
   `site/deploy/remote_install.sh` (exécuté via `remote_run`).

- Les déploiements suivants rafraîchissent la copie root via
  `site/deploy/install_privileged.sh` (toujours root:root, non inscriptible
  par l'utilisateur de service).
- `sudo` passwordless est accordé à `SERVICE_USER` via `/etc/sudoers.d/<SERVICE_USER>`
  (règle `ALL=(ALL) NOPASSWD: ALL`, validée avec `visudo`) : l'accès réseau/WireGuard
  passe par la copie root, qui lit le registre et les clés de `$HOME/.beaut/state`.
- `--no-root` : mode utilisateur, sans sudo, sans WireGuard.
- WireGuard est **idempotent** (`scripts/lib/wireguard.sh`) : une clé par appareil
  (`state/wg/device_*.key`, repli legacy `state/wg_*.key`), interface `wg0`
  conservée, chaînes `nft`/`iptables` reconstruites vers un seul jeu de règles.
  Les appareils approuvés sont synchronisés comme peers (`sync-peers`, `/32`) ;
  les peers inconnus sont laissés intacts, les révoqués sont retirés.
- Publication : `/node` est généré **sur le serveur** depuis `site/scripts/node.sh`
  et l'adresse déployée, avec **aucun fichier sourcé**, en `sh` POSIX.
  `/join` n'est plus publié ; `site/scripts/wireguard_join.sh` et
  `site/scripts/device.sh join` restent des commandes du dépôt.
- Le dossier `site/` est archivé (hors `.git`) puis appliqué par
  `site/deploy/sync_site.sh` vers `$PUBLISHED_ROOT` (`~/.beaut/site`) ;
  l'ancienne arborescence est remplacée par un swap atomique, et les dossiers git
  de premier niveau sont clonés/fast-forwardés depuis leur remote.
- Les builtins (`site/scripts`, `site/deploy`) sont dans l'arborescence publiée :
  aucun second exemplaire sous `shared/`. Des liens symboliques `scripts` et
  `deploy` à la racine du dépôt gardent les commandes locales inchangées.
- Serveur lancé en service utilisateur systemd (`site/deploy/beaut.service`),
  secours `setsid` (fallback via `remote_install.sh`).
- À l'issue : le serveur est joignable via le listener `socat` ou le relay C
  compilé (`site/scripts/http_server.c`), `curl /node | sh` fonctionne sans
  fichier client.
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

## Appareils, invitations et porte

- Une **clé WireGuard par appareil**, générée une fois et persistée
  (`state/wg/device_*.key`, repli legacy `state/wg_*.key`) ; jamais partagée.
- `state/devices/registry.tsv` :
  `device_id | name | public_key | address | trust | status | created_at | approved_at`.
  `trust` = `owner` / `trusted` / `guest` ; `status` = `pending` / `approved` / `revoked`.
- Le serveur possède une seule ligne `owner` (clé stable entre déploiements).
  La porte par défaut (`GET /door`) est le plus ancien serveur `owner`/`trusted`
  approuvé, surchargeable par `DOOR_DEVICE_ID`.
- `scripts/lib/invites.sh` : un **passMessage** est affiché une seule fois ;
  seul son SHA-256 est stocké (`state/invites/registry.tsv`), avec usages, TTL,
  statut et note. Une invitation valide accepte automatiquement l'appareil en
  `trusted` ou `guest` ; sinon il reste `pending` jusqu'à approbation manuelle.
- `owner` n'est jamais délivrable par invitation. L'HTTP n'approuve jamais :
  KNOCK reste une décision manuelle (`device.sh approve`), suivie de `sync-peers`.

## Arborescence publique `site/`

- Le dossier `site/` du dépôt est la source de vérité **et** l'arborescence
  publiée. `deploy.sh` l'upload et la remplace dans `$PUBLISHED_ROOT`
  (`~/.beaut/site` sur le serveur) par un swap atomique : une entrée retirée du
  dépôt disparaît, sans manifeste séparé.
- Les builtins vivent dans `site/` : `site/scripts/` est servi à `/scripts/`,
  `site/deploy/` à `/deploy/`, et `/node` est généré dans `site/node/` après le
  sync. La racine du dépôt garde des liens symboliques `scripts` et `deploy`
  pour les commandes locales.
- Résolution : `/a/b/c` sert le fichier `$PUBLISHED_ROOT/a/b/c` ; `/a/b` sert
  `a/b/index.html` (ou `index.htm`) s'il existe, sinon le premier
  `a/b/DEFAU*.sh`, sinon une liste de dossier générée. Les pages HTML réelles,
  les endpoints de scripts et l'exploration de l'arborescence cohabitent.
- Les pages texte peuvent utiliser `{{SERVER_HOST}}`, `{{HTTP_PORT}}` et les
  autres valeurs publiques de configuration, remplacées au moment du service.
- Le journal n'est pas public : il vit dans l'arborescence cachée et n'est
  joignable qu'à `/<secret>/journal/`.
- Le type MIME suit l'extension (`.html`, `.css`, `.js`, `.json`, `.md`, images,
  ...) ; les scripts et fichiers inconnus restent `text/plain`.
- Les segments de chemin commençant par un point ne sont jamais servis : `.git`,
  `.env` et autres fichiers cachés restent privés, même dans un dépôt.
- Un dossier de premier niveau `site/<nom>` contenant `.git` est traité comme un
  dépôt git séparé : son URL d'origine est enregistrée, le dossier n'est pas
  uploadé, le serveur le clone ou le fast-forward. Il est servi à `/<nom>/`. Le
  remote doit être joignable depuis le serveur (SSH ou HTTPS).

## Arborescence personnelle cachée et journal

- `scripts/svr.sh` gère un worktree git caché : `$SVR_REPO` (`$SERVICE_ROOT/.svr`)
  est le dépôt séparé, `$PUBLISHED_ROOT/$SVR_NAME` est le worktree dont `.git`
  est un fichier pointant vers `$SVR_REPO`. `SVR_NAME` (8 alphanum, persisté
  dans `state/svr_name`) est le nom et le préfixe URL ; `SVR_PATH` peut
  surcharger l'URL. `svr.sh init` crée le dépôt, le worktree (`admin` + commit
  initial, `worktree add -B main`) et migre les anciens `.svr-*` / `svr/`.
- `SVR_PATH` fixe explicitement le préfixe URL caché (aléatoire par défaut).
  `SVR_MODE=random` : 8 caractères `[a-z0-9]`, persistés dans
  `state/svr_path` (mode 600). `sha` : 8 premiers caractères de
  `sha256("beaut-svr:" + SVR_SECRET)`. `plain` : valeur `SVR` explicite.
- L'HTTP sert `/<secret>/…` depuis le worktree `$PUBLISHED_ROOT/$SVR_NAME` ;
  un préfixe erroné ne donne jamais accès à l'arbre, et les segments commençant
  par un point (`.git`, y compris le fichier `.git` du worktree) restent privés.
- `svr.sh init` crée le worktree et lie `$PUBLISHED_ROOT/<secret>/scripts` ->
  `$PUBLISHED_ROOT/scripts`. Le handler autorise cette cible publique, donc
  `/<secret>/scripts/` sert les mêmes scripts que `/scripts/`, qui reste public.
- `scripts/lib/journal.sh` est un portage de `~/.svr/usr/bin/journal` :
  `$SVR_ROOT/journal/YYYY/MM/DD/<sous-dossier>/<nom>.md`, en-tête
  (AAMMJJ, heure, utilisateur, hôte, séparateur, chemin), vue
  `$SVR_ROOT/journal/<hôte>/<sous-dossier>/<nom>.md` et `index.html` régénéré.
- `svr.sh install` installe les commandes `journal` et `journal-perso` dans
  `$SVR_BIN_DIR` (défaut `~/.local/bin`) et ajoute ce dossier aux fichiers de
  démarrage du shell de connexion s'il manque au `PATH` (`SVR_INSTALL_PATH=0`
  pour désactiver). Le dossier journal est un dépôt git :
  pull avant édition, commit après, push si un remote existe (`JOURNAL_GIT=0`
  pour désactiver). `svr.sh remote <url>` (ou `JOURNAL_REMOTE`) remplace
  `origin`, ce qui sert à repointers un serveur restauré. `JOURNAL_REMOTE=hidden`
  pousse vers `user@host:<arborescence cachée>/journal` (`JOURNAL_REMOTE_ROOT`
  fixe le chemin côté serveur).
- `svr.sh init` migre l'ancien `$SERVICE_ROOT/svr` et son `diary/` vers le
  nouveau dossier et `journal/`.

## Tests

Sous-projet `tests/` : `tests/run.sh`. Aucun root, aucun réseau externe, aucun
WireGuard réel. Chaque test lance le relay C sur `127.0.0.1` avec un état
temporaire et couvre : cycle de vie des tokens, TTL, arborescences statique et
cachée, pages `index.html` et types MIME, chemins cachés bloqués, synchronisation
du `site/` public (remplacement complet, purge, dépôts git), 404, traversée,
`curl /node | sh` depuis un dossier vide, `/join` non publié, `/signin` +
`/door`, registre des appareils, invitations hachées, journal compatible
`~/.svr` (arbre AAAA/MM/JJ, en-tête, vue par hôte, commits git et commande
installée), arborescence cachée servie sous le préfixe secret, attributions
virtuelles, clés WireGuard par appareil, synchronisation des peers et
idempotence du pare-feu (commandes factices), `bash -n` /
`gcc -fsyntax-only` / `git diff --check`.

## Configuration
Tout est défini dans `config.env` et `config.env.example` (le modèle sert aussi
de schéma de repli). Le chargement se fait avec `set -a`, donc **tout est exporté
automatiquement** : aucune liste d'export à maintenir.

## Fichiers clés
```
config.env                  variables d'environnement (éditables à la main)
config.env.example          modèle + schéma de repli
deploy.sh                   orchestrateur client SSH/SFTP (SERVICE_USER auto-détecté ; BOOTSTRAP_USER en secours ; --no-root = user)
site/deploy/bootstrap.sh   première application en root : utilisateur, clé, config racine, sudo grant
site/deploy/install_privileged.sh  rafraîchit la copie root des scripts + config gelée
site/deploy/sync_site.sh   remplace site/ dans PUBLISHED_ROOT + clone/fast-forward git
site/deploy/remote_install.sh   phase utilisateur : service systemd + demarrage du serveur
site/deploy/beaut.service  service utilisateur systemd
site/deploy/start.sh       script de démarrage (fichier à part, jamais inline)
site/scripts/http_server.sh      chaine de listeners : socat → relay C → fail
site/scripts/http_server.c       relay TCP minimal (socat-enough, gcc)
site/scripts/http_handler.sh     handler serveur (routes + arborescences, pas d'exécution)
site/scripts/lib/http.sh         réponses HTTP (dont redirections), parsing, form, client
site/scripts/lib/state.sh        TSV unique + helpers token_create/token_find/token_field
site/scripts/node.sh             script node POSIX autonome (| sh), réclame + exécute + rapporte
site/scripts/build_published_node.sh  génère /node avec l'adresse figée, sans source
site/scripts/network.sh          wrapper WireGuard + pare-feu + sync-peers
site/scripts/lib/wireguard.sh    clés par appareil, peers, helpers client/serveur idempotents
site/scripts/device.sh           CLI identité appareil, invitations, enrôlement, approbation
site/scripts/lib/devices.sh      registre, clés, adresses, trust, porte
site/scripts/lib/invites.sh      invitations passMessage hachées (usages/TTL/révocation)
site/scripts/svr.sh              CLI worktree .svr, journal git et installeur
site/scripts/journal_cli.sh      commande installée journal / journal-perso
site/scripts/lib/personal_tree.sh  dépôt .svr, worktree $SVR_NAME, chemins secrets et lien scripts
site/scripts/lib/journal.sh      journal compatible ~/.svr : arbre daté, vue hôte, git
site/scripts/lib/passphrase.sh   mots, aléa, passphrases, secrets
site/scripts/attribution.sh      CLI d'attribution virtuelle (secrets/chemins)
site/scripts/lib/virtual_path.sh algorithme passphrase/chemin/registre
site/scripts/lib/core.sh         chemins, config, log, état
scripts, deploy             liens symboliques vers site/ pour les commandes locales
site/                       arborescence publique ET builtins (PUBLISHED_ROOT = ~/.beaut/site)
tests/                      sous-projet de tests isolé (tests/run.sh)
state/db.tsv                base d'état (tokens, travaux, résultats)
```
