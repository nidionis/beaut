# beaut

Plateforme de calcul partagé minimaliste (serveur de contrôle + agents répartis),
pure bash, architecture pull-based de type BOINC.

Le serveur ne contacte jamais les agents : ce sont les agents qui viennent
chercher le travail (beacon → get task → execute → report back).

## Déploiement rapide

### 1. Sur le serveur de contrôle (DOMAIN=192.168.8.240)

```bash
# Configuration
cp config.env.example config.env
# (optionnel) adaptez config.env

# Installation de beaut.sh dans le PATH
./deploy.sh install

# Lancement du serveur (WireGuard + HTTP)
beaut.sh server
```

Le serveur expose 4 endpoints HTTP :

| Endpoint | Rôle |
|----------|------|
| `/install` | Renvoie le script d'installation de l'agent |
| `/ask` | Un agent demande une tâche |
| `/give` | Un agent s'enregistre, envoie un heartbeat, ou rapporte un résultat |
| `/stats` | Affiche l'état du serveur (workers, tâches) |

### 2. Sur un agent (nœud invité/esclave)

```bash
# Rejoindre le WireGuard (nécessite la clé publique du serveur)
beaut.sh agent  # ou wg_join.sh <cle_pub_serveur> puis beaut.sh agent

# Ou installation one-liner depuis le serveur
curl http://$DOMAIN:$HTTP_PORT/install | sh
```

### 3. Soumettre une tâche

```bash
beaut.sh submit 'echo hello-world'
beaut.sh status <task_id>
beaut.sh result <task_id>
```

### 4. Démonstration complète (serveur + agent + docker-compose)

```bash
./deploy.sh demo
```

La démo lance le serveur, un agent, crée un `docker-compose.yml` hello-world,
soumet la tâche et affiche le résultat.

## Architecture

- **WireGuard** : VPN entre le serveur et tous les agents (IP virtuelles stables,
  trafic agent↔agent direct sans reverse-SSH).
- **HTTP mini-server** (`socat`) : endpoints `/install`, `/ask`, `/give`, `/stats`,
  max 2 requêtes concurrentes.
- **État** : fichiers TSV plats sous `state/` (workers, tasks, assignments,
  workers.trusted), protégés par `flock` + `mv` atomique.
- **Priorités nice** : root/admin `-20`, vip `0`, invité/esclave `+19`.
- **Watchdog** : maintient en vie un service (docker, systemctl, cron, commande
  simple) sur chaque agent.

## Exemple : déployer un docker-compose hello-world

```bash
beaut.sh submit 'cd /path/to/tutor/hello.docker && docker-compose up'
```

Le serveur dispatch la tâche à un agent disponible, qui l'exécute avec la priorité
nice de son rôle et rapporte le résultat.

## Fichiers

- `config.env` / `config.env.example` — configuration
- `deploy.sh` — point d'entrée (installe `beaut.sh`)
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
