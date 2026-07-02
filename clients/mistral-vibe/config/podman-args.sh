#!/bin/bash

# =============================================================================
# Mistral Vibe CLI - Arguments Podman par défaut
# 
# Ce script définit les arguments recommandés pour lancer le conteneur
# Mistral Vibe CLI avec Podman de manière sécurisée.
# 
# Utilisation :
#   source config/podman-args.sh
#   podman run $PODMAN_ARGS -it ia-dev-container-mistral-vibe
# 
# Ou directement :
#   podman run $(cat config/podman-args.sh) -it ia-dev-container-mistral-vibe
# =============================================================================

# Initialiser les arguments
PODMAN_ARGS=""

# ---- Arguments de base ----
# Utilisateur non-root (remplacez par votre UID:GID si nécessaire)
PODMAN_ARGS+=" --user $(id -u):$(id -g)"
PODMAN_ARGS+=" --userns=keep-id"

# ---- Sécurité ----
# Mode rootless (recommandé)
PODMAN_ARGS+=" --cap-drop=ALL"
PODMAN_ARGS+=" --security-opt=no-new-privileges"

# ---- Réseau ----
# Pas de réseau direct (tout passe par le proxy)
PODMAN_ARGS+=" --network=none"

# ---- Système de fichiers ----
# Lecture seule
PODMAN_ARGS+=" --read-only"

# tmpfs pour les répertoires temporaires
PODMAN_ARGS+=" --tmpfs=/tmp"
PODMAN_ARGS+=" --tmpfs=/run"

# ---- Volumes ----
# Volume de travail (monté depuis l'hôte)
PODMAN_ARGS+=" -v $(pwd)/../../workspace:/workspace"

# Volumes pour les dépendances Python (persistantes)
PODMAN_ARGS+=" -v mistral-vibe-local:/home/devuser/.local"
PODMAN_ARGS+=" -v mistral-vibe-cache:/home/devuser/.cache"

# ---- Variables d'environnement ----
# Proxy
PODMAN_ARGS+=" -e HTTP_PROXY=http://localhost:3128"
PODMAN_ARGS+=" -e HTTPS_PROXY=http://localhost:3128"
PODMAN_ARGS+=" -e NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

# Variables pour Mistral Vibe
PODMAN_ARGS+=" -e IA_CLIENT=mistral-vibe"
PODMAN_ARGS+=" -e MISTRAL_API_URL=https://api.mistral.ai"

# ---- Options supplémentaires ----
# Supprimer automatiquement à l'arrêt
PODMAN_ARGS+=" --rm"

# Nom du conteneur
PODMAN_ARGS+=" --name mistral-vibe-dev"

# ---- Affichage des arguments ----
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "============================================================================="
    echo "Arguments Podman recommandés pour Mistral Vibe CLI :"
    echo "============================================================================="
    echo "$PODMAN_ARGS"
    echo ""
    echo "Commande complète :"
    echo "podman run $PODMAN_ARGS -it ia-dev-container-mistral-vibe"
    echo ""
    echo "Pour lancer :"
    echo "  1. source config/podman-args.sh"
    echo "  2. podman run \$PODMAN_ARGS -it ia-dev-container-mistral-vibe"
    echo ""
fi
