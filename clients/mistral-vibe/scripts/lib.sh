#!/bin/bash
# Constantes partagées par run.sh et security-tests.sh.
# Doit être sourcé, pas exécuté directement. Suppose que PROJECT_ROOT,
# CLIENT_ROOT et REPO_ROOT sont déjà définis par l'appelant (run.sh) avant
# le `source`.

CLIENT_NAME="mistral-vibe"

# _sanitize_name, PROJECT_NAME, _sed_escape_replacement, _subnet_offset_seed
# et ensure_network_and_ip sont génériques (aucune référence à mistral-vibe) :
# partagés avec clients/copilot via scripts/common.sh, pas dupliqués ici.
# shellcheck source=../../../scripts/common.sh
source "$REPO_ROOT/scripts/common.sh"

# dns   : le workspace joint le gateway via son alias réseau "gateway"
#         (résolu par aardvark-dns sur le réseau interne).
# static: repli sur l'IP fixe du gateway, si la résolution DNS pose problème.
GATEWAY_ADDR_MODE="${GATEWAY_ADDR_MODE:-dns}"

# 0 = Phase 1 (gateway non-root direct, pas de nftables)
# 1 = Phase 2 (gateway root-in-userns -> nftables -> abandon de privilèges)
GATEWAY_HARDENED="${GATEWAY_HARDENED:-0}"

# gateway-base/workspace-base : image partagée entre tous les projets et les
# deux clients (aucun contenu spécifique à un projet, juste Alpine+Squid ou
# Alpine+Python/Node) — un seul tag global profite du cache de layers.
GATEWAY_BASE_IMAGE="ia-dev-containers-gateway-base:latest"
WORKSPACE_BASE_IMAGE="ia-dev-containers-workspace-base:latest"

# Overlay gateway/workspace : contient potentiellement des réglages propres
# à ce projet (allowed-urls.txt) -> tag scopé par projet, sinon deux projets
# qui tournent en parallèle écraseraient le même tag avec des configs
# différentes pendant que l'autre tourne encore.
GATEWAY_IMAGE="ia-dev-containers-gateway-${CLIENT_NAME}-${PROJECT_NAME}:latest"
WORKSPACE_IMAGE="ia-dev-containers-workspace-${CLIENT_NAME}-${PROJECT_NAME}:latest"

NETWORK_NAME="ia-gw-internal-${CLIENT_NAME}-${PROJECT_NAME}"
GATEWAY_CONTAINER="${CLIENT_NAME}-${PROJECT_NAME}-gateway"
WORKSPACE_CONTAINER="${CLIENT_NAME}-${PROJECT_NAME}-workspace"

# ~/.local contient les VRAIS paquets installés par `pip install --user` (pas
# un simple cache) : scopé par projet, pour qu'un paquet compromis installé
# dans un projet ne devienne pas silencieusement importable depuis un autre.
# ~/.cache ne contient que le cache de téléchargement pip (rien d'exécutable
# "installé") : partagé entre projets par simplicité, pour éviter de
# retélécharger les mêmes paquets pour chaque projet.
LOCAL_VOLUME="mistral-vibe-local-${PROJECT_NAME}"
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
