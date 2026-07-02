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

# Détection best-effort de la plateforme hôte et, sur macOS/Windows, de
# l'état de la VM "podman machine" (Podman n'y tourne jamais nativement).
# Sur Linux, ne fait rien (pas de VM) : retour immédiat, zéro changement
# de comportement sur la plateforme déjà validée.
# Non vérifié sur matériel macOS/Windows réel (voir docs/macos.md,
# docs/windows.md) : la détection d'existence est fiable (testée y compris
# sur Linux sans machine configurée), la détection de l'état "Running" est
# volontairement best-effort/non bloquante.
preflight_platform_check() {
    local os
    os="$(uname -s)"
    case "$os" in
        Linux) return 0 ;;
        Darwin|MINGW*|MSYS*|CYGWIN*) ;;
        *)
            echo "⚠️  Plateforme hôte non reconnue ($os) — poursuite sans vérification podman machine." >&2
            return 0
            ;;
    esac

    local machine_names
    machine_names="$(podman machine list -q 2>/dev/null || true)"
    if [ -z "$machine_names" ]; then
        cat >&2 <<'EOF'
❌ Aucune VM "podman machine" détectée sur cette plateforme (macOS/Windows).
   Podman a besoin d'une machine virtuelle Linux pour fonctionner ici. Lancez :
     podman machine init
     podman machine start
   puis relancez cette commande. Voir docs/macos.md ou docs/windows.md.
EOF
        exit 1
    fi

    local machine_json
    machine_json="$(podman machine list --format json 2>/dev/null || true)"
    if [ -n "$machine_json" ] && ! printf '%s' "$machine_json" | grep -Eq '"Running":[[:space:]]*true'; then
        echo "⚠️  Aucune VM podman machine ne semble démarrée. Si la suite échoue :" >&2
        echo "     podman machine start" >&2
    fi
}
