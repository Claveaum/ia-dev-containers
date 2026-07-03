#!/bin/bash
set -euo pipefail

# =============================================================================
# GitHub Copilot CLI - point d'entrée. Toute l'orchestration vit dans
# scripts/orchestrator.sh (partagé avec les autres clients) ; ce fichier ne
# fait que poser les chemins hôte et déléguer, après avoir chargé les
# données propres à ce client (lib.sh). Voir scripts/orchestrator.sh pour
# l'usage complet des commandes et des variables d'environnement.
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
# shellcheck source=../../../scripts/common.sh
source "$REPO_ROOT/scripts/common.sh"
# shellcheck source=../../../scripts/orchestrator.sh
source "$REPO_ROOT/scripts/orchestrator.sh"

orchestrator_main "$@"
