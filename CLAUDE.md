# ia-dev-containers

Conteneurs Podman sécurisés (deux conteneurs, `gateway` + `workspace`) pour faire tourner des clients IA CLI (Mistral Vibe, GitHub Copilot) sans exposer le poste hôte. Ce dépôt est destiné à être **copié** à la racine du projet à sandboxer (`mon-projet/ia-dev-containers/`) ; voir le [README](README.md) pour la doc utilisateur complète.

## Architecture

- **`gateway`** : seul conteneur avec accès réseau réel. Squid + allowlist de domaines (`clients/<client>/gateway/config/allowed-urls.txt`). Durcissement optionnel via nftables (`GATEWAY_HARDENED=1`).
- **`workspace`** : exécute le CLI IA. Attaché uniquement à un réseau Podman `--internal` (aucune route sortante par défaut), `cap-drop=ALL`, `--read-only`, non-root. `/workspace` est un **bind-mount direct** du projet hôte (pas une copie) — voir les avertissements du README sur les conséquences pour `ia-dev-containers/` lui-même.
- `gateway-base/` et `workspace-base/` : images génériques, **partagées entre tous les clients et tous les projets**. `clients/<client>/{gateway,workspace}/` : overlays spécifiques à un client (allowlist, dépendances du CLI).
- Réseau, conteneurs et images overlay sont scopés **par projet** (nom déduit du dossier contenant la copie) ; les images `*-base` restent globales.
- **Module profond d'orchestration** (voir `/codebase-design`) : `scripts/orchestrator.py` (point d'entrée unique `main()`, Python — voir plus bas) et `scripts/security-tests.sh` portent toute la logique générique du sandbox (build, mounts, doctor, batterie de tests). `gateway-base/scripts/gateway-checks.sh` porte les vérifications côté gateway, également générique. Chaque client n'expose qu'un adaptateur mince : `clients/<client>/scripts/lib.sh` (données : `CLIENT_NAME`, volume de paquets, domaines testés, `SECRETS`, callback `client_package_manager_tests()`) et `run.sh` (bash, construit les arguments CLI depuis `lib.sh` et délègue à `orchestrator.py`). Ne pas dupliquer de logique dans un `lib.sh` de client, ni recréer un fichier par client pour quelque chose de générique — si ce n'est pas spécifique à un client, ça va dans `scripts/` ou `gateway-base/`.
- **Orchestration côté hôte en Python, tout le reste en bash** : `scripts/orchestrator.py` (build, réseau, gateway, workspace, rendu `devcontainer.json`) est le seul composant Python de ce dépôt — il tourne exclusivement sur l'hôte, jamais copié dans une image. **`python3` est donc un prérequis hôte obligatoire**, au même titre que Podman (voir README, tableau Plateformes hôte). Tout ce qui tourne *dans* un conteneur (`gateway-base/`, `workspace-base/`, `scripts/security-tests.sh`) reste en bash : ces scripts sont triviaux et gateway-base (Alpine/musl) ne fournit pas Python. `clients/*/scripts/lib.sh` reste bash lui aussi, pour une raison précise : il est sourcé côté hôte par `run.sh` **et** copié tel quel dans l'image workspace, où `security-tests.sh` le source à nouveau pour `client_package_manager_tests()` — le convertir casserait ce second usage. La frontière `run.sh` (bash) → `orchestrator.py` (Python) se fait uniquement par arguments CLI nommés et explicites (`--client-name`, `--extension`, `--secret`, ...), jamais par variable d'environnement ad hoc — voir `orchestrator.py --help`.

## Structure

```
gateway-base/                     # image générique gateway (Squid, nftables)
  scripts/gateway-checks.sh       # vérifications côté gateway, génériques (podman exec ... /gateway-checks.sh)
workspace-base/        # image générique workspace (CLI IA)
scripts/                          # orchestrateur générique, partagé par tous les clients
  orchestrator.py                 # Python, côté hôte uniquement — up|shell|test|down|secrets|doctor (main()) ; Config, gabarits de noms, WORKSPACE_SECURITY_ARGS, proxy_url, préflight plateforme, allocation réseau, auto-protection, render_devcontainer()
  test_orchestrator.py            # tests rapides sans Podman de orchestrator.py (unittest stdlib)
  security-tests.sh               # batterie de tests générique (copiée dans l'image workspace, source /lib.sh) — bash, tourne dans le conteneur
  devcontainer-skeleton.json.template  # squelette VS Code partagé par tous les clients, rendu par render_devcontainer()
clients/<nom>/
  gateway/             # overlay : allowlist de domaines uniquement
  workspace/           # overlay : dépendances du client (Python, Node...) — COPY lib.sh + scripts/security-tests.sh au build
  scripts/
    lib.sh             # adaptateur bash : CLIENT_NAME, volume de paquets, domaines testés, SECRETS, callback de test, cosmétique VS Code (DEVCONTAINER_*) — reste bash (sourcé aussi dans le conteneur par security-tests.sh)
    run.sh             # point d'entrée mince : source lib.sh, construit les arguments CLI, exec python3 orchestrator.py
  .devcontainer/       # devcontainer.json généré au runtime (run.sh up) — pas de template ici, voir scripts/
  .env.example
docs/agents/           # config lue par les skills d'ingénierie (voir plus bas)
docs/{macos,windows}.md
```

## Commandes clés (depuis `clients/<nom-du-client>/`)

- `./scripts/run.sh up` — construit les images, crée le réseau interne du projet, démarre le gateway
- `./scripts/run.sh shell [--no-build] [-- CMD...]` — shell interactif dans le workspace (ou exécute `CMD`)
- `./scripts/run.sh test [--no-build]` — suite de tests de sécurité contre le vrai gateway + `gateway-checks.sh`
- `./scripts/run.sh exec [-- CMD...]` — second shell dans le workspace déjà lancé par un `run.sh shell` vivant ailleurs
- `./scripts/run.sh down [--purge-network]` — arrête tout
- `./scripts/run.sh purge [--volumes]` — supprime images/réseau/conteneurs de ce projet ; `--volumes` supprime aussi les volumes scopés par projet (irréversible)
- `./scripts/run.sh logs [gateway|workspace]` — logs d'un des deux conteneurs
- `./scripts/run.sh secrets` — statut des secrets (`podman secret` préféré à `.env`)
- `./scripts/run.sh doctor` — diagnostic plateforme hôte + réseau du projet

## Conventions

- Jamais de `-e CLE=valeur` pour un secret — `podman secret create` (repli `.env`).
- Ne jamais installer le CLI IA lui-même au build d'une image `workspace` (le proxy `HTTP_PROXY` n'existe qu'au runtime) — toujours au runtime (`pip install --user`, `npm install --prefix`).
- Un nouveau client s'ajoute en copiant `clients/mistral-vibe/scripts/{lib.sh,run.sh}` : seul `lib.sh` doit être adapté (`CLIENT_NAME` et le reste des données propres au client) — `run.sh` se copie tel quel, il délègue entièrement à `scripts/orchestrator.py`. `security-tests.sh` et `gateway-checks.sh` sont déjà partagés (`scripts/`, `gateway-base/`) — rien à créer pour eux. Le Dockerfile `workspace/` doit `COPY` `lib.sh` + `scripts/security-tests.sh` (contexte de build = racine du dépôt).
- `python3 scripts/test_orchestrator.py` (rapide, sans Podman) pour vérifier la logique pure de `orchestrator.py` (noms de ressources, échappement JSON, auto-protection, rendu `devcontainer.json` contre le vrai squelette pour chaque client réel) ; `run.sh up && run.sh test` reste le seul test qui vérifie les garanties réelles du sandbox (isolation réseau, non-root, lecture seule) — toute modification doit être validée par les deux, pas seulement une relecture du code. Ce projet documente explicitement ce qui est vérifié vs. non vérifié (ex. macOS/Windows expérimentaux, session Copilot authentifiée non testée).

## Conventions de commit

- **L'auteur d'un commit est toujours la personne qui commite, jamais un agent IA.** Objectif : pouvoir savoir qui a commité quoi si ce dépôt a plusieurs contributeurs humains — une identité générique type "Claude Code" écraserait cette information.
- Aucune mention de Claude/Anthropic dans les messages de commit : pas de trailer `Co-Authored-By: Claude ...`, pas de `Claude-Session: ...`, pas de mention "Generated with Claude Code". Ceci **remplace** la convention par défaut de l'outil Claude Code qui ajoute normalement ce trailer.
- Un agent qui commite pour le compte d'un utilisateur doit utiliser l'identité git de cet utilisateur (nom + email), jamais une identité par défaut de l'outil — sans jamais modifier `git config` (ni local ni global) pour y parvenir : passer `--author="Nom <email>"` et surcharger `GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` en variables d'environnement sur la commande, ou (préférable, durable) demander à l'utilisateur de configurer lui-même `git config user.name`/`user.email` dans ce dépôt.
- Historique réécrit le 2026-07-03 pour appliquer cette règle rétroactivement (tous les commits jusque-là attribués à "Claude Code <noreply@anthropic.com>" sont réattribués, trailers supprimés) ; ancienne référence conservée localement dans `refs/original/refs/heads/main` sur la machine où la réécriture a eu lieu.

## Agent skills

### Issue tracker

Issues live in GitHub Issues (Claveaum/ia-dev-containers), via the `gh` CLI. External PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
