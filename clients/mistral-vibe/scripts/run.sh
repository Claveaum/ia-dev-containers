#!/bin/bash
set -euo pipefail

# =============================================================================
# Mistral Vibe CLI - Script de lancement
# 
# Ce script construit (si nécessaire) et lance le conteneur
# Mistral Vibe CLI avec la configuration sécurisée.
# 
# Utilisation :
#   ./scripts/run.sh
# =============================================================================

echo "============================================================================="
echo "  Mistral Vibe CLI - Conteneur de développement sécurisé"
echo "============================================================================="
echo ""

# ---- Vérifier que Podman est installé ----
if ! command -v podman &> /dev/null; then
    echo "❌ ERREUR : Podman n'est pas installé !"
    echo ""
    echo "Pour installer Podman :"
    echo "  Linux (Debian/Ubuntu) : sudo apt install -y podman"
    echo "  Linux (Fedora/RHEL) : sudo dnf install -y podman"
    echo "  macOS : brew install podman && podman machine init && podman machine start"
    echo ""
    exit 1
fi

echo "✅ Podman est installé (version : $(podman --version))"

# ---- Vérifier que nous sommes dans le bon répertoire ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ ! -f "$PROJECT_ROOT/Dockerfile" ]; then
    echo "❌ ERREUR : Le Dockerfile n'est pas trouvé !"
    echo "   Exécutez ce script depuis : $PROJECT_ROOT/"
    exit 1
fi

# ---- Construire l'image si elle n'existe pas ----
IMAGE_NAME="ia-dev-container-mistral-vibe"

if ! podman image exists "$IMAGE_NAME"; then
    echo "🔧 Construction de l'image $IMAGE_NAME..."
    echo ""
    
    # Naviguer vers le répertoire du client
    cd "$PROJECT_ROOT"
    
    # Construire avec le cache pour accélérer
    if ! podman build -t "$IMAGE_NAME" .; then
        echo "❌ ERREUR : La construction de l'image a échoué !"
        exit 1
    fi
    
    echo "✅ Image construite avec succès !"
    echo ""
else
    echo "ℹ️  Image $IMAGE_NAME déjà présente, pas de reconstruction."
    echo ""
fi

# ---- Charger les arguments Podman ----
source "$PROJECT_ROOT/config/podman-args.sh"

# ---- Lancer le conteneur ----
echo "🚀 Démarrage du conteneur Mistral Vibe CLI..."
echo ""
echo "Commande exécutée :"
echo "podman run $PODMAN_ARGS -it $IMAGE_NAME"
echo ""

# Exécuter la commande
podman run $PODMAN_ARGS -it "$IMAGE_NAME"

# Si on arrive ici, le conteneur s'est arrêté
echo ""
echo "ℹ️  Le conteneur s'est arrêté. Pour le relancer :"
echo "   cd $PROJECT_ROOT"
echo "   ./scripts/run.sh"
