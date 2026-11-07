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
| `/<fichier>` | GET | Lecture seule depuis `HTTP_FILE_ROOT` (dossier → `DEFAULT.sh`) |
| autre | GET | `ERR404` (variable configurable) |

## Parsing
Aucune bibliothèque de parsing HTTP/AWK. On lit uniquement :
1. La première ligne (`METHOD /path HTTP/1.1`) pour extraire le chemin.
2. Le corps brut (`cat`) pour les POST.

## Données (TSV unique)
- `state/db.tsv` : une seule table avec colonne `type` (token, task, result, archive).
- Archivage journalier sous `state/archive/YYYY-MM-DD/`.
- `HIST_MEM_MAX = 20% de la RAM totale` : garde-fou désactivant l'archivage si la mémoire disponible est trop faible.

## Déploiement (`deploy.sh`)
- Connexion **SSH/SFTP** sur l'ordinateur `$DOMAIN`.
- Crée l'utilisateur sudoer `$NAME=beaut`.
- Autorise la clé d'installation (+ clés optionnelles depuis `config.env`).
- WireGuard sécurise les connexions entre clés reconnues.
- À l'issue : un serveur de scripts de déploiement est joignable à l'adresse principale + ses alias/DDNS.
- Mise à jour et synchronisation des scripts par **git** (`git pull`).

## Fichiers clés
```
config.env              variables d'environnement (éditables à la main)
deploy.sh               installation distante SSH/SFTP
deploy/files/start.sh   script de démarrage (fichier à part, jamais inline)
scripts/http_server.sh  lance socat + http_handler.sh
scripts/http_handler.sh handler serveur (routes, pas d'exécution)
scripts/http_exec.sh    script node (| sh), réclame + exécute + rapporte
scripts/net.sh          WireGuard + pare-feu (source unique)
scripts/wg_setup.sh     délègue à net.sh
scripts/wg_join.sh      délègue à net.sh
scripts/lib/core.sh     config, log, état
scripts/lib/state.sh    TSV unique (find/append/update)
state/db.tsv            base d'état (tokens, travaux, résultats)
```
