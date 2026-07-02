#!/bin/bash
# Constantes partagées par run.sh et security-tests.sh.
# Doit être sourcé, pas exécuté directement.

NETWORK_NAME="ia-gw-internal"
SUBNET="10.89.0.0/24"
GATEWAY_IP="10.89.0.2"

# dns   : le workspace joint le gateway via son alias réseau "gateway"
#         (résolu par aardvark-dns sur le réseau interne).
# static: repli sur l'IP fixe du gateway, si la résolution DNS pose problème.
GATEWAY_ADDR_MODE="${GATEWAY_ADDR_MODE:-dns}"

# 0 = Phase 1 (gateway non-root direct, pas de nftables)
# 1 = Phase 2 (gateway root-in-userns -> nftables -> abandon de privilèges)
GATEWAY_HARDENED="${GATEWAY_HARDENED:-0}"

GATEWAY_BASE_IMAGE="ia-dev-containers-gateway-base:latest"
WORKSPACE_BASE_IMAGE="ia-dev-containers-workspace-base:latest"
GATEWAY_IMAGE="ia-dev-containers-gateway-mistral-vibe:latest"
WORKSPACE_IMAGE="ia-dev-containers-workspace-mistral-vibe:latest"

GATEWAY_CONTAINER="mistral-vibe-gateway"
WORKSPACE_CONTAINER="mistral-vibe-workspace"

WORKSPACE_VOLUME="mistral-vibe-workspace"
LOCAL_VOLUME="mistral-vibe-local"
CACHE_VOLUME="mistral-vibe-cache"

# Secrets exposés en variable d'environnement dans le workspace via
# `podman secret` (type=env), si le secret existe. Format par entrée :
# "nom-du-secret:VARIABLE_ENV". Absent -> repli sur .env (--env-file).
# Création : printf '%s' 'sk-...' | podman secret create mistral-vibe-mistral-api-key -
SECRETS=(
    "mistral-vibe-mistral-api-key:MISTRAL_API_KEY"
)

proxy_url() {
    if [ "$GATEWAY_ADDR_MODE" = "static" ]; then
        echo "http://${GATEWAY_IP}:3128"
    else
        echo "http://gateway:3128"
    fi
}

# Remarque (documentation, pas une protection par chmod) : le workspace
# n'est JAMAIS lancé avec -v /run/podman/podman.sock, -v /run/docker.sock,
# ni --device. C'est ça, et pas un chmod interne au conteneur, qui empêche
# l'accès aux sockets/devices de l'hôte.
