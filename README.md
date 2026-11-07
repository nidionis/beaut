# beaut

Plateforme de calcul partagé minimaliste (serveur de contrôle + agents répartis),
pure bash, architecture pull-based de type BOINC.

Le serveur ne contacte jamais les agents : ce sont les agents qui viennent
chercher le travail (beacon → get task → execute → report back).

## Déploiement du serveur (une fois, en root)

```bash
sudo ./deploy.sh
```

Ce script installe uniquement l'infrastructure de contrôle sur l'hôte :

1. crée le répertoire d'état (`state/`) ;
2. configure WireGuard (`wg_setup.sh`) ;
3. installe un service systemd (`beaut.service`) qui lance le serveur HTTP au démarrage ;
4. ouvre les ports HTTP et WireGuard dans le pare-feu ;
5. vérifie que le service est en ligne.

Le serveur expose quatre endpoints HTTP :

| Endpoint | Rôle |
|----------|------|
| `/install` | Renvoie le script d'installation de l'agent |
| `/ask` | Un agent demande une tâche |
| `/give` | Un agent s'enregistre, envoie un heartbeat, ou rapporte un résultat |
| `/stats` | Affiche l'état du serveur (workers, tâches) |

## Installation d'un agent (sur chaque nœud invité)

Sur chaque machine qui doit exécuter des tâches (en tant qu'utilisateur
non-root) :

```bash
curl http://$DOMAIN:$HTTP_PORT/install | sh
```

Puis rejoindre le WireGuard avec la clé publique du serveur :

```bash
wg_join.sh <cle_publique_serveur>
```

## Configuration

Toute la configuration se fait dans `config.env` (éditer à la main) :

- `DOMAIN` / `HTTP_PORT` : adresse et port du serveur de contrôle
- `WG_PORT` / `WG_NET` / `WG_SERVER_IP` : configuration WireGuard
- `LEASE_TTL_SECONDS` : durée d'un bail d'exécution
- `HEARTBEAT_INTERVAL` : intervalle entre deux heartbeats
- `WORKER_STALE_SECONDS` : délai avant qu'un worker soit considéré mort
- `NICE_ROOT` / `NICE_VIP` / `NICE_GUEST` : priorités d'exécution

Le fichier `config.env` est ignoré par git (ne jamais committer de config locale).

## Architecture

- **WireGuard** : VPN entre le serveur et tous les agents (IP virtuelles stables,
  trafic agent↔agent direct sans reverse-SSH ni tunnel SSH).
- **HTTP mini-server** (`socat`) : endpoints `/install`, `/ask`, `/give`, `/stats`.
- **État** : fichiers TSV plats sous `state/` (workers, tasks, assignments,
  workers.trusted), protégés par `flock` + `mv` atomique.
- **Priorités nice** : root/admin `-20`, vip `0`, invité/esclave `+19`.
- **Watchdog** : maintient en vie un service (docker, systemctl, cron, commande
  simple) sur chaque agent.
- **Mots-clés futurs** : `scripts/cmds/<mot-clef>/<numero>` (install, give, use,
  buy, get, send, sell, del) pour le déploiement par chemin (non encore utilisé).

## Exemple : déployer un docker-compose hello-world

```bash
beaut.sh submit 'cd /path/to/tutor/hello.docker && docker-compose up'
```

Le serveur dispatch la tâche à un agent disponible, qui l'exécute avec la priorité
nice de son rôle et rapporte le résultat.

## Fichiers

- `config.env` / `config.env.example` — configuration (éditable à la main)
- `deploy.sh` — installation du serveur (root, une seule fois)
- `beaut.sh` — CLI utilisateur (installé par `deploy.sh install`)
- `scripts/lib/core.sh` — helpers pur bash (config, logging, TSV, nice)
- `scripts/lib/http.sh` — client HTTP pur bash (/dev/tcp)
- `scripts/lib/trusted.sh` — parsing de `workers.trusted`
- `scripts/lib/tsv/{find,field,append,update,stale,filter}.sh` — helpers TSV
- `scripts/wg_setup.sh` / `wg_join.sh` — WireGuard
- `scripts/http_server.sh` — mini serveur HTTP (`socat`)
- `scripts/http_handler.sh` — dispatch des requêtes HTTP vers les actions
- `scripts/http.sh` — serveur HTTP générique (enveloppe HTML)
- `scripts/actions/{install,ask,give,stats}.sh` — endpoints HTTP
- `scripts/agent.sh` — agent worker + watchdog
- `scripts/client.sh` — client donneur de tâches
- `scripts/cmds/<mot-clef>/<numero>` — commandes par mot-clé (futur)
