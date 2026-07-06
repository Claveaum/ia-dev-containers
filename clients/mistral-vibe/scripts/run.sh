#!/bin/bash
set -euo pipefail

# =============================================================================
# Mistral Vibe CLI - point d'entrée. Toute l'orchestration vit dans
# scripts/orchestrator.py (partagé avec les autres clients) ; ce fichier ne
# fait que poser les chemins hôte et charger les données propres à ce client
# (lib.sh), qu'il transmet à l'orchestrateur Python en arguments CLI
# explicites — jamais en variable globale/d'environnement implicite. Voir
# scripts/orchestrator.py pour l'usage complet des commandes et des
# variables d'environnement.
#
# Ce dossier (ia-dev-containers) est prévu pour être copié à la racine du
# projet à sandboxer (ex: mon-projet/ia-dev-containers/) : /workspace dans
# le conteneur est un bind-mount de la racine du projet (PROJECT_ROOT, le
# dossier parent de cette copie), pas un volume Podman vide — le CLI IA
# travaille sur les vrais fichiers. Voir le README (section Sécurité) pour
# les implications de ce choix.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$(dirname "$CLIENT_ROOT")")"
PROJECT_ROOT="${IA_PROJECT_ROOT:-$(dirname "$REPO_ROOT")}"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

command -v python3 &> /dev/null || {
    echo "❌ python3 n'est pas installé (requis pour scripts/orchestrator.py — voir README, section Plateformes hôte)" >&2
    exit 1
}

# lib.sh (données propres à ce client) traverse la frontière bash -> Python
# uniquement via ces arguments nommés, jamais via une variable d'environnement
# ad hoc : chaque champ consommé par l'orchestrateur est explicite et
# documenté par `orchestrator.py --help`.
args=(
    --client-name "$CLIENT_NAME"
    --client-root "$CLIENT_ROOT"
    --repo-root "$REPO_ROOT"
    --project-root "$PROJECT_ROOT"
    --pkg-volume-target "$PKG_VOLUME_TARGET"
    --devcontainer-display-name "$DEVCONTAINER_DISPLAY_NAME"
    --devcontainer-settings-json "$DEVCONTAINER_SETTINGS_JSON"
    --pkg-install-hint "$PKG_INSTALL_HINT"
    --registry-url "$REGISTRY_URL"
    --registry-user "$REGISTRY_USER"
)
for ext in "${DEVCONTAINER_EXTENSIONS[@]+"${DEVCONTAINER_EXTENSIONS[@]}"}"; do
    args+=(--extension "$ext")
done
for vol in "${EXTRA_VOLUMES[@]+"${EXTRA_VOLUMES[@]}"}"; do
    args+=(--extra-volume "$vol")
done
for secret in "${SECRETS[@]+"${SECRETS[@]}"}"; do
    args+=(--secret "$secret")
done
for kv in "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}"; do
    args+=(--extra-env "$kv")
done

exec python3 "$REPO_ROOT/scripts/orchestrator.py" "${args[@]}" -- "$@"
