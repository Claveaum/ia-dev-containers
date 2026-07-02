#!/bin/bash
set -euo pipefail

# =============================================================================
# Mistral Vibe CLI - Orchestration du sandbox à deux conteneurs
#
# Usage :
#   run.sh up                    construit les images, crée le réseau, lance le gateway
#   run.sh shell [-- CMD...]     lance (ou réutilise) le gateway puis un workspace interactif
#   run.sh test                  lance le workspace et exécute security-tests.sh
#   run.sh down [--purge-network] arrête les conteneurs (et supprime le réseau)
#
# Variables d'environnement :
#   GATEWAY_HARDENED=1     active la Phase 2 (nftables + abandon de privilèges)
#   GATEWAY_ADDR_MODE=static  utilise l'IP fixe du gateway au lieu de la résolution DNS
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$(dirname "$CLIENT_ROOT")")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

need_podman() {
    command -v podman &> /dev/null || { echo "❌ podman n'est pas installé" >&2; exit 1; }
}

build_images() {
    echo "🔧 Construction des images..."
    podman image exists "$GATEWAY_BASE_IMAGE"   || podman build -t "$GATEWAY_BASE_IMAGE"   "$REPO_ROOT/gateway-base"
    podman image exists "$WORKSPACE_BASE_IMAGE" || podman build -t "$WORKSPACE_BASE_IMAGE" "$REPO_ROOT/workspace-base"
    podman build -t "$GATEWAY_IMAGE"   "$CLIENT_ROOT/gateway"
    # Contexte = racine du client (pas workspace/) pour que le Dockerfile
    # puisse COPY scripts/security-tests.sh, situé hors de workspace/.
    podman build -t "$WORKSPACE_IMAGE" -f "$CLIENT_ROOT/workspace/Dockerfile" "$CLIENT_ROOT"
}

ensure_network() {
    if ! podman network exists "$NETWORK_NAME"; then
        echo "🔧 Création du réseau interne $NETWORK_NAME ($SUBNET, --internal)..."
        podman network create --internal --subnet "$SUBNET" "$NETWORK_NAME"
    fi
}

gateway_running() {
    podman container exists "$GATEWAY_CONTAINER" && \
        [ "$(podman inspect -f '{{.State.Running}}' "$GATEWAY_CONTAINER" 2>/dev/null)" = "true" ]
}

start_gateway() {
    if gateway_running; then
        # On interroge le conteneur réel plutôt que la variable d'env locale
        # (qui peut différer d'un précédent `up` lancé dans un autre shell).
        local running_mode="simple"
        podman inspect -f '{{.HostConfig.CapAdd}}' "$GATEWAY_CONTAINER" 2>/dev/null | grep -q NET_ADMIN && running_mode="durci"
        echo "ℹ️  Gateway déjà démarré (mode $running_mode)."
        return
    fi
    podman rm -f "$GATEWAY_CONTAINER" &> /dev/null || true

    local cap_args=(--cap-drop=ALL)
    local user_args=()
    if [ "$GATEWAY_HARDENED" = "1" ]; then
        cap_args+=(--cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SETUID --cap-add=SETGID)
        echo "🚀 Démarrage du gateway (Phase 2 : nftables + abandon de privilèges)..."
    else
        user_args+=(--user 65534:65534)
        echo "🚀 Démarrage du gateway (Phase 1 : non-root direct, sans nftables)..."
    fi

    podman run -d --name "$GATEWAY_CONTAINER" \
        "${user_args[@]}" \
        "${cap_args[@]}" \
        --security-opt=no-new-privileges \
        --read-only --tmpfs=/tmp --tmpfs=/run \
        --network="${NETWORK_NAME}:ip=${GATEWAY_IP},alias=gateway" \
        --network=podman \
        -e ENABLE_NFT="$GATEWAY_HARDENED" \
        "$GATEWAY_IMAGE" > /dev/null

    echo "✅ Gateway démarré ($GATEWAY_CONTAINER)"
}

start_workspace() {
    local proxy; proxy="$(proxy_url)"
    local env_file="$CLIENT_ROOT/.env"
    local env_args=()
    [ -f "$env_file" ] && env_args+=(--env-file "$env_file")

    podman run --rm -it --name "$WORKSPACE_CONTAINER" \
        --user "$(id -u):$(id -g)" --userns=keep-id \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only --tmpfs=/tmp --tmpfs=/run \
        --network="$NETWORK_NAME" \
        -v "${WORKSPACE_VOLUME}:/workspace" \
        -v "${LOCAL_VOLUME}:/home/devuser/.local" \
        -v "${CACHE_VOLUME}:/home/devuser/.cache" \
        -e HTTP_PROXY="$proxy" -e HTTPS_PROXY="$proxy" \
        -e IA_CLIENT=mistral-vibe \
        "${env_args[@]}" \
        "$WORKSPACE_IMAGE" "$@"
}

cmd="${1:-shell}"
shift || true

case "$cmd" in
    up)
        need_podman
        build_images
        ensure_network
        start_gateway
        ;;
    shell)
        need_podman
        build_images
        ensure_network
        start_gateway
        [ "${1:-}" = "--" ] && shift
        start_workspace "$@"
        ;;
    test)
        need_podman
        build_images
        ensure_network
        start_gateway
        start_workspace /security-tests.sh
        ;;
    down)
        podman rm -f "$GATEWAY_CONTAINER" "$WORKSPACE_CONTAINER" &> /dev/null || true
        if [ "${1:-}" = "--purge-network" ]; then
            podman network rm "$NETWORK_NAME" &> /dev/null || true
        fi
        echo "✅ Conteneurs arrêtés."
        ;;
    *)
        echo "usage: run.sh {up|shell [-- CMD...]|test|down [--purge-network]}" >&2
        exit 1
        ;;
esac
