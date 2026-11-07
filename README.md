# beaut

Plateforme de calcul partagé minimaliste (serveur de contrôle + agents répartis),
pure bash, architecture pull-based de type BOINC.

Le serveur ne contacte jamais les agents : ce sont les agents qui viennent
chercher le travail (beacon → get task → execute → report back).

## Déploiement du serveur

### Avec root (recommandé)

```bash
sudo ./deploy.sh
```

Installe WireGuard, le service systemd (`beaut.service`), ouvre les ports HTTP
et WireGuard dans le pare-feu.

### Sans root (--no-root)

```bash
./deploy.sh --no-root
```

Demande confirmation des ports et dossiers, installe en local sous `state/`.
Aucun privilège système n'est requis.

Le serveur expose quatre endpoints HTTP :

| Endpoint | Rôle |
|----------|------|
| `/install` | Renvoie le script d'installation de l'agent (exécute `wg_join.sh` avec la clé publique) |
| `/ask` | Un agent demande une tâche |
| `/give` | Un agent s'enregistre, envoie un heartbeat, rapporte un résultat, ou récupère une commande via token |
| `/done/<TOKEN>` | Un agent POSTe le résultat d'un token avant LEASE_TTL |
| `/stats` | Affiche l'état du serveur |

## Installation d'un agent

Sur chaque nœud invité (utilisateur non-root) :

```bash
curl http://$DOMAIN:$HTTP_PORT/install | sh
```

Le script télécharge l'agent, rejoint le WireGuard avec la clé publique du
serveur, s'enregistre, puis lance la boucle agent.

## Flux tokenisé (/give → /done/<TOKEN>)

1. Un agent contacte `/give`. Le serveur génère un token, associe une tâche,
   et retourne un script shell à exécuter via `| sh`.
2. Le script récupère la commande auprès du serveur, l'exécute, puis POSTe le
   résultat sur `/done/<TOKEN>` avant l'expiration du `LEASE_TTL`.
3. Le serveur vérifie le résultat aléatoirement (1 fois sur N=2) en attendant
   le même calcul d'un autre token, puis compare.

## Scripts par chemin (scripts/cmds/)

Les chemins HTTP `<mot-clef>/<numero>` sont résolus vers
`scripts/cmds/<mot-clef>/<numero>`, puis `<mot-clef>/DEFAUT.sh`, puis
`scripts/cmds/DEFAUT.sh`. Exemple : `/give/50` exécute
`scripts/cmds/give/50` s'il existe.

## Configuration

Toute la configuration se fait dans `config.env` (éditable à la main) :

- `DOMAIN` / `HTTP_PORT` : adresse et port du serveur de contrôle
- `WG_PORT` / `WG_NET` / `WG_SERVER_IP` : configuration WireGuard
- `LEASE_TTL_SECONDS` : durée d'un bail d'exécution
- `HEARTBEAT_INTERVAL` : intervalle entre deux heartbeats
- `WORKER_STALE_SECONDS` : délai avant qu'un worker soit considéré mort
- `LOG_LEVEL` : debug | info | warn | error
- `NICE_ROOT` / `NICE_VIP` / `NICE_GUEST` : priorités d'exécution (-20 / 0 / +19)

`config.env` est ignoré par git (ne jamais committer de config locale).

## Architecture

- **WireGuard** : VPN entre le serveur et tous les agents (IP virtuelles stables,
  trafic agent↔agent direct sans reverse-SSH ni tunnel SSH).
- **HTTP mini-server** (`socat`) : endpoints HTTP, max 2 requêtes concurrentes.
- **État** : fichiers TSV plats sous `state/` (workers, tasks, assignments,
  workers.trusted), protégés par `flock` + `mv` atomique.
- **Priorités nice** : root/admin `-20`, vip `0`, invité/esclave `+19`.
- **Watchdog** : maintient en vie un service (docker, systemctl, cron, commande
  simple) sur chaque agent.

## Fichiers

- `config.env` / `config.env.example` — configuration (éditable à la main)
- `deploy.sh` — installation du serveur (root ou --no-root, une seule fois)
- `scripts/lib/core.sh` — helpers pur bash (config, logging, TSV, nice)
- `scripts/lib/http.sh` — client HTTP pur bash (/dev/tcp)
- `scripts/lib/trusted.sh` — parsing de `workers.trusted`
- `scripts/lib/tsv/{find,field,append,update,stale,filter}.sh` — helpers TSV
- `scripts/wg_setup.sh` / `wg_join.sh` — WireGuard
- `scripts/http_server.sh` — mini serveur HTTP (`socat`)
- `scripts/http_handler.sh` — dispatch des requêtes HTTP (routing vers cmds/ et actions/)
- `scripts/http.sh` — serveur HTTP générique (enveloppe HTML)
- `scripts/actions/{install,ask,give,done,stats}.sh` — endpoints HTTP
- `scripts/agent.sh` — agent worker + watchdog
- `scripts/client.sh` — client donneur de tâches
- `scripts/cmds/<mot-clef>/<numero>` — commandes par chemin (futur)
- `scripts/cmds/DEFAUT.sh` — script par défaut
