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
#   run.sh secrets                affiche le statut des secrets attendus (voir lib.sh: SECRETS)
#   run.sh doctor                  diagnostic plateforme hôte / podman machine (macOS, Windows)
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
    preflight_platform_check
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

# Construit les --secret pour chaque entrée de SECRETS (lib.sh) dont le
# `podman secret` correspondant existe déjà. Les secrets absents sont
# silencieusement ignorés (pas une erreur : optionnel/incrémental).
secret_args() {
    local secret_entry secret_name var_name
    for secret_entry in "${SECRETS[@]}"; do
        secret_name="${secret_entry%%:*}"
        var_name="${secret_entry#*:}"
        if podman secret exists "$secret_name" 2>/dev/null; then
            echo "--secret"
            echo "${secret_name},type=env,target=${var_name}"
        fi
    done
}

# Affiche, pour chaque secret attendu par ce client, s'il est couvert par
# `podman secret` (recommandé) ou par .env (repli), ou absent des deux.
list_secrets() {
    local secret_entry secret_name var_name
    echo "Secrets attendus pour ce client :"
    for secret_entry in "${SECRETS[@]}"; do
        secret_name="${secret_entry%%:*}"
        var_name="${secret_entry#*:}"
        if podman secret exists "$secret_name" 2>/dev/null; then
            echo "  $var_name : ✅ défini (podman secret '$secret_name')"
        elif [ -f "$CLIENT_ROOT/.env" ] && grep -q "^${var_name}=" "$CLIENT_ROOT/.env" 2>/dev/null; then
            echo "  $var_name : ✅ défini (.env, repli — la valeur apparaît en clair dans 'podman inspect')"
        else
            echo "  $var_name : ❌ absent — printf '%s' 'valeur' | podman secret create $secret_name -"
        fi
    done
}

start_workspace() {
    local proxy; proxy="$(proxy_url)"
    local env_file="$CLIENT_ROOT/.env"
    local env_args=()
    [ -f "$env_file" ] && env_args+=(--env-file "$env_file")

    # while/read plutôt que `mapfile` (bash >=4) : macOS fournit bash 3.2 en
    # /bin/bash par défaut, où `mapfile` n'existe pas.
    local secret_args_list=()
    while IFS= read -r line; do
        secret_args_list+=("$line")
    done < <(secret_args)

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
        "${secret_args_list[@]}" \
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
    secrets)
        need_podman
        list_secrets
        ;;
    doctor)
        need_podman
        echo "Système hôte : $(uname -s) ($(uname -m))"
        echo "podman        : $(podman version --format '{{.Client.Version}}' 2>/dev/null || echo inconnu)"
        if [ "$(uname -s)" != "Linux" ]; then
            echo ""
            echo "Machines podman :"
            podman machine list
        fi
        echo "✅ Vérifications préliminaires OK."
        ;;
    *)
        echo "usage: run.sh {up|shell [-- CMD...]|test|down [--purge-network]|secrets|doctor}" >&2
        exit 1
        ;;
esac
