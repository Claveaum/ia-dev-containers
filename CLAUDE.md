# ia-dev-containers

Conteneurs Podman sécurisés (deux conteneurs, `gateway` + `workspace`) pour faire tourner des clients IA CLI (Mistral Vibe, GitHub Copilot) sans exposer le poste hôte. Ce dépôt est destiné à être **copié** à la racine du projet à sandboxer (`mon-projet/ia-dev-containers/`) ; voir le [README](README.md) pour la doc utilisateur complète.

## Architecture

- **`gateway`** : seul conteneur avec accès réseau réel. Squid + allowlist de domaines (`clients/<client>/gateway/config/allowed-urls.txt`). Durcissement optionnel via nftables (`GATEWAY_HARDENED=1`).
- **`workspace`** : exécute le CLI IA. Attaché uniquement à un réseau Podman `--internal` (aucune route sortante par défaut), `cap-drop=ALL`, `--read-only`, non-root. `/workspace` est un **bind-mount direct** du projet hôte (pas une copie) — voir les avertissements du README sur les conséquences pour `ia-dev-containers/` lui-même.
- `gateway-base/` et `workspace-base/` : images génériques, **partagées entre tous les clients et tous les projets**. `clients/<client>/{gateway,workspace}/` : overlays spécifiques à un client (allowlist, dépendances du CLI).
- Réseau, conteneurs et images overlay sont scopés **par projet** (nom déduit du dossier contenant la copie) ; les images `*-base` restent globales.

## Structure

```
gateway-base/          # image générique gateway (Squid, nftables)
workspace-base/        # image générique workspace (CLI IA)
clients/<nom>/
  gateway/             # overlay : allowlist de domaines
  workspace/           # overlay : dépendances du client (Python, Node...)
  scripts/{lib.sh,run.sh,security-tests.sh}
  .devcontainer/devcontainer.json.template
  .env.example
docs/agents/           # config lue par les skills d'ingénierie (voir plus bas)
docs/{macos,windows}.md
scripts/common.sh      # utilitaires partagés entre clients
```

## Commandes clés (depuis `clients/<nom-du-client>/`)

- `./scripts/run.sh up` — construit les images, crée le réseau interne du projet, démarre le gateway
- `./scripts/run.sh shell` — shell interactif dans le workspace
- `./scripts/run.sh test` — suite de tests de sécurité contre le vrai gateway
- `./scripts/run.sh down [--purge-network]` — arrête tout
- `./scripts/run.sh secrets` — statut des secrets (`podman secret` préféré à `.env`)
- `./scripts/run.sh doctor` — diagnostic plateforme hôte + réseau du projet

## Conventions

- Jamais de `-e CLE=valeur` pour un secret — `podman secret create` (repli `.env`).
- Ne jamais installer le CLI IA lui-même au build d'une image `workspace` (le proxy `HTTP_PROXY` n'existe qu'au runtime) — toujours au runtime (`pip install --user`, `npm install --prefix`).
- Un nouveau client s'ajoute en copiant `clients/mistral-vibe/scripts/{lib.sh,run.sh,security-tests.sh}` et en changeant `CLIENT_NAME` dans `lib.sh` — le reste (subnet, noms de ressources) en découle automatiquement.
- Toute modification doit être validée par un run réel (`run.sh up && run.sh test`), pas seulement une relecture du code — ce projet documente explicitement ce qui est vérifié vs. non vérifié (ex. macOS/Windows expérimentaux, session Copilot authentifiée non testée).

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
