# beaut

Plateforme de calcul partagé minimaliste (serveur de contrôle + agents répartis), pur bash.
Architecture **pull-based** de type BOINC : le hub ne contacte jamais les nœuds ; les agents viennent chercher le travail (beacon → get task → execute → report back).

## Installation / déploiement

```bash
# 1. configuration (copie du modèle)
cp config.env.example config.env
# (optionnel) adaptez config.env ou créez un .env gitignoré pour vos overrides locaux

# 2. initialiser l'état
./deploy.sh init

# 3. lancer le hub + un agent
./deploy.sh up

# 4. démonstration : un agent exécute une tâche qui crée un dossier partagé
#    contenant hello world et y lance un serveur HTTP
./deploy.sh demo

# 5. arrêter
./deploy.sh down
```

Après `demo`, le résultat affiche le dossier partagé (`$STATE_DIR/demo`) avec `index.html` contenant `Hello World`.
Pour servir ce dossier vous-même : `python3 -m http.server 8000 --directory $STATE_DIR/demo`

## Comment ça marche (HOWITWORKS)

- `config.env` (surchargé par `.env` si présent) définit l'hôte du hub, les ports, les délais (stale heartbeat, TTL de bail) et le répertoire d'état (`STATE_DIR`).
- `scripts/hub.sh` expose `init`, `register`, `heartbeat`, `submit`, `daemon` (dispatch), `poll`, `result`, `list`. L'état est stocké en TSV sous `state/` (`workers.tsv`, `tasks.tsv`, `assignments.tsv`), protégé par `flock` + `mv` atomique.
- `scripts/agent.sh` s'enregistre auprès du hub (clé publique + capacités), puis boucle : heartbeat → `poll` récupère une tâche en attente → exécution sous `timeout` (bail) → `result` remonte la sortie.
- `scripts/client.sh` soumet une commande (`submit`) et consulte le statut / résultat (`status`, `result`).
- Le transport est du SSH pur (pas de tunnel, pas de forward reverse) ; en local (`HUB_HOST=127.0.0.1`) les appels se font directement, sans réseau.
- Un worker sans heartbeat pendant `WORKER_STALE_SECONDS` est marqué `stale` et ne reçoit plus de tâches.

## Fichiers

- `config.env` / `config.env.example` — configuration
- `deploy.sh` — point d'entrée (init / up / down / demo)
- `scripts/hub.sh` — serveur de contrôle
- `scripts/agent.sh` — agent réparti (worker)
- `scripts/client.sh` — client donneur de tâches
- `scripts/lib/core.sh` — briques partagées (config, logging, état, SSH)
