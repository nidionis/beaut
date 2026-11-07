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
| `/<chemin>` | GET | Arborescence `HTTP_FILE_ROOT` (dossier → premier `DEFAU*.sh`) |
| autre | GET | `ERR404` (variable configurable) |

## Parsing
Aucune bibliothèque de parsing HTTP/AWK. On lit uniquement :
1. La première ligne (`METHOD /path HTTP/1.1`) pour extraire le chemin.
2. Le corps brut (`cat`) pour les POST.

## Données (TSV unique)
- `state/db.tsv` : une seule table avec colonne `type` (token, task, result, archive).
- Archivage journalier sous `state/archive/YYYY-MM-DD/`.
- `HIST_MEM_MAX = 20% de la RAM totale` : garde-fou désactivant l'archivage si la mémoire disponible est trop faible.

## Déploiement (`deploy.sh`) — deux temps, une bascule d'identité
1. **`$SUDOER`** (root conseillé, demandé au lancement) applique `deploy/files/amorce.sh` :
   crée `$NAME=beaut` (home standard `$HOME`, pas de `NAME_HOME`), autorise la clé
   publique, installe la **copie root:root** des scripts et le helper `s$NAME`.
2. Tout le reste se fait en **`$NAME`**, par clé uniquement (`BatchMode`, `publickey`),
   sans mot de passe, dans `$HOME/.beaut` : `scripts/`, `deploy/`, `state/`, `shared/`.
- `sudo` n'est accordé que pour les ressources spéciales : une seule règle
  `NOPASSWD` vers `/usr/local/sbin/s$NAME` (réseau/WireGuard). Le helper n'exécute
  que la copie root, jamais le code modifiable par `$NAME`.
- WireGuard sécurise les connexions entre clés reconnues.
- Serveur lancé en service utilisateur systemd (`deploy/files/beaut.service`), secours `setsid`.
- À l'issue : le serveur est joignable, `curl /node | sh` récupère le script node.
- Mise à jour et synchronisation des scripts par **git** (`git pull`).

## Fichiers clés
```
config.env              variables d'environnement (éditables à la main)
deploy.sh               amorçage distant SSH/SFTP (SUDOER puis NAME)
deploy/files/amorce.sh  première application en root : utilisateur, clé, sudo limité
deploy/files/sbeaut     helper root des ressources spéciales (installé en s$NAME)
deploy/files/beaut.service  service utilisateur systemd
deploy/files/start.sh   script de démarrage (fichier à part, jamais inline)
scripts/http_server.sh  lance socat + http_handler.sh
scripts/http_handler.sh handler serveur (routes + arborescence, pas d'exécution)
scripts/http_exec.sh    script node (| sh), réclame + exécute + rapporte
scripts/net.sh          WireGuard + pare-feu (source unique)
scripts/wg_setup.sh     délègue à net.sh
scripts/wg_join.sh      délègue à net.sh
scripts/lib/core.sh     config, log, état
scripts/lib/state.sh    TSV unique (find/append/update)
state/db.tsv            base d'état (tokens, travaux, résultats)
shared/                 arborescence HTTP servie (path = fichier, dossier = DEFAU*.sh)
```
