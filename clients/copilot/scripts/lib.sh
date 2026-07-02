#!/bin/bash
# Constantes partagées par run.sh et security-tests.sh.
# Doit être sourcé, pas exécuté directement.

NETWORK_NAME="ia-gw-internal-copilot"
# Sous-réseau distinct de mistral-vibe (10.89.0.0/24) : Podman refuse deux
# réseaux --internal sur le même subnet, et gateway-base/config/squid.conf
# a une ACL workspace_net qui couvre 10.89.0.0/16 pour englober tous les
# clients (voir ce fichier pour l'allocation complète).
SUBNET="10.89.1.0/24"
GATEWAY_IP="10.89.1.2"

# dns   : le workspace joint le gateway via son alias réseau "gateway"
#         (résolu par aardvark-dns sur le réseau interne).
# static: repli sur l'IP fixe du gateway, si la résolution DNS pose problème.
GATEWAY_ADDR_MODE="${GATEWAY_ADDR_MODE:-dns}"

# 0 = Phase 1 (gateway non-root direct, pas de nftables)
# 1 = Phase 2 (gateway root-in-userns -> nftables -> abandon de privilèges)
GATEWAY_HARDENED="${GATEWAY_HARDENED:-0}"

GATEWAY_BASE_IMAGE="ia-dev-containers-gateway-base:latest"
WORKSPACE_BASE_IMAGE="ia-dev-containers-workspace-base:latest"
GATEWAY_IMAGE="ia-dev-containers-gateway-copilot:latest"
WORKSPACE_IMAGE="ia-dev-containers-workspace-copilot:latest"

GATEWAY_CONTAINER="copilot-gateway"
WORKSPACE_CONTAINER="copilot-workspace"

WORKSPACE_VOLUME="copilot-workspace"
NPM_GLOBAL_VOLUME="copilot-npm-global"
CACHE_VOLUME="copilot-cache"

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
