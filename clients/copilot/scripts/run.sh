#!/bin/bash
set -euo pipefail

# =============================================================================
# GitHub Copilot CLI - Orchestration du sandbox à deux conteneurs
#
# Ce dossier (ia-dev-containers) est prévu pour être copié à la racine du
# projet à sandboxer (ex: mon-projet/ia-dev-containers/) : /workspace dans
# le conteneur est un bind-mount de la racine du projet (PROJECT_ROOT, le
# dossier parent de cette copie), pas un volume Podman vide — le CLI IA
# travaille sur les vrais fichiers. Voir le README (section Sécurité) pour
# les implications de ce choix.
#
# Usage :
#   run.sh up                    construit les images, crée le réseau, lance le gateway
#   run.sh shell [-- CMD...]     lance (ou réutilise) le gateway puis un workspace interactif
#   run.sh test                  lance le workspace et exécute security-tests.sh
#   run.sh down [--purge-network] arrête les conteneurs (et supprime le réseau)
#   run.sh secrets                affiche le statut des secrets attendus (voir lib.sh: SECRETS)
#   run.sh doctor                  diagnostic plateforme hôte / réseau / projet détecté
#
# Variables d'environnement :
#   GATEWAY_HARDENED=1     active la Phase 2 (nftables + abandon de privilèges)
#   GATEWAY_ADDR_MODE=static  utilise l'IP fixe du gateway au lieu de la résolution DNS
#   IA_PROJECT_ROOT         force la racine du projet (par défaut : dossier
#                           parent de cette copie de ia-dev-containers)
#   IA_PROJECT_NAME         force le nom utilisé pour scoper les ressources
#                           Podman (par défaut : nom du dossier PROJECT_ROOT)
#   IA_SELF_MOUNT_RW=1      désactive l'auto-protection en lecture seule de
#                           ia-dev-containers/ dans /workspace (voir README,
#                           section Architecture) — le CLI IA peut alors
#                           modifier sa propre config sandbox depuis l'intérieur
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$(dirname "$CLIENT_ROOT")")"
PROJECT_ROOT="${IA_PROJECT_ROOT:-$(dirname "$REPO_ROOT")}"
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

# Génère .devcontainer/devcontainer.json à partir du template : les valeurs
# (réseau scopé projet, chemin du projet, volume ~/.npm-global scopé projet)
# ne peuvent pas être codées en dur, elles dépendent de PROJECT_ROOT/PROJECT_NAME.
render_devcontainer() {
    local template="$CLIENT_ROOT/.devcontainer/devcontainer.json.template"
    local out="$CLIENT_ROOT/.devcontainer/devcontainer.json"
    [ -f "$template" ] || return 0
    # PROJECT_ROOT est un chemin hôte arbitraire (pas sanitizé comme
    # NETWORK_NAME/NPM_GLOBAL_VOLUME) : échappé via _sed_escape_replacement
    # (scripts/common.sh) pour éviter qu'un "&" ou un "|" dans le chemin ne
    # corrompe silencieusement le fichier généré ou ne fasse échouer ce sed.
    # __SELF_PROTECT_MOUNT__ : entrée de mounts[] qui protège ia-dev-containers/
    # en lecture seule (voir scripts/common.sh: self_protect_mount_arg()), ou
    # chaîne vide si non applicable (relocalisé hors du projet, dogfooding, ou
    # IA_SELF_MOUNT_RW=1) — la ligne du template disparaît alors simplement.
    local self_protect_relpath self_protect_line=""
    self_protect_relpath="$(_self_protect_relpath)"
    if [ -n "$self_protect_relpath" ]; then
        self_protect_line="\"source=${REPO_ROOT},target=/workspace/${self_protect_relpath},type=bind,readonly\","
    fi
    sed \
        -e "s|__NETWORK_NAME__|$(_sed_escape_replacement "$NETWORK_NAME")|g" \
        -e "s|__PROJECT_ROOT__|$(_sed_escape_replacement "$PROJECT_ROOT")|g" \
        -e "s|__NPM_GLOBAL_VOLUME__|$(_sed_escape_replacement "$NPM_GLOBAL_VOLUME")|g" \
        -e "s|__SELF_PROTECT_MOUNT__|$(_sed_escape_replacement "$self_protect_line")|g" \
        "$template" > "$out"
}

gateway_running() {
    podman container exists "$GATEWAY_CONTAINER" && \
        [ "$(podman inspect -f '{{.State.Running}}' "$GATEWAY_CONTAINER" 2>/dev/null)" = "true" ]
}

start_gateway() {
    if gateway_running; then
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
        ${user_args[@]+"${user_args[@]}"} \
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
    # /bin/bash par défaut, où `mapfile` n'existe pas. Les "${arr[@]}" plus bas
    # sont gardés en "${arr[@]+...}" : sous `set -u`, bash 3.2 (contrairement
    # à bash >=4.4) lève "unbound variable" sur l'expansion d'un tableau vide
    # (vérifié empiriquement : podman run --rm -i bash:3.2 ...).
    local secret_args_list=()
    while IFS= read -r line; do
        secret_args_list+=("$line")
    done < <(secret_args)

    # Auto-protection : remonte ia-dev-containers/ en lecture seule sur
    # lui-même dans /workspace (voir scripts/common.sh: self_protect_mount_arg())
    # — vide si non applicable (relocalisé, dogfooding, IA_SELF_MOUNT_RW=1).
    local self_mount_args=()
    while IFS= read -r line; do
        self_mount_args+=("$line")
    done < <(self_protect_mount_arg)

    # --security-opt=label=disable : /workspace est un bind-mount du vrai
    # projet hôte (PROJECT_ROOT), pas un volume Podman. Sous SELinux
    # (Fedora/RHEL), un bind-mount d'un chemin arbitraire est refusé sans
    # relabeling. L'alternative `:Z` sur le -v relabelerait récursivement
    # les fichiers RÉELS du projet sur le disque (effet de bord persistant
    # hors du sandbox) ; label=disable désactive la confinement SELinux
    # pour ce conteneur sans toucher aux labels du projet — vérifié : les
    # deux permettent l'écriture, seul label=disable laisse `ls -Z` sur le
    # projet hôte inchangé. No-op inoffensif sur les hôtes sans SELinux.
    podman run --rm -it --name "$WORKSPACE_CONTAINER" \
        --user "$(id -u):$(id -g)" --userns=keep-id \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --security-opt=label=disable \
        --read-only --tmpfs=/tmp --tmpfs=/run \
        --network="$NETWORK_NAME" \
        -v "${PROJECT_ROOT}:/workspace" \
        ${self_mount_args[@]+"${self_mount_args[@]}"} \
        -v "${NPM_GLOBAL_VOLUME}:/home/devuser/.npm-global" \
        -v "${CACHE_VOLUME}:/home/devuser/.cache" \
        -e HTTP_PROXY="$proxy" -e HTTPS_PROXY="$proxy" \
        -e IA_CLIENT=copilot \
        ${secret_args_list[@]+"${secret_args_list[@]}"} \
        ${env_args[@]+"${env_args[@]}"} \
        "$WORKSPACE_IMAGE" "$@"
}

cmd="${1:-shell}"
shift || true

case "$cmd" in
    up)
        need_podman
        build_images
        ensure_network_and_ip
        start_gateway
        render_devcontainer
        ;;
    shell)
        need_podman
        build_images
        ensure_network_and_ip
        start_gateway
        [ "${1:-}" = "--" ] && shift
        start_workspace "$@"
        ;;
    test)
        need_podman
        build_images
        ensure_network_and_ip
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
        echo ""
        echo "Projet détecté : $PROJECT_ROOT"
        echo "Nom sandbox     : $PROJECT_NAME"
        echo "Réseau          : $NETWORK_NAME"
        echo "Auto-protection : $(self_protect_status)"
        if podman network exists "$NETWORK_NAME"; then
            echo "  subnet (existant) : $(podman network inspect "$NETWORK_NAME" --format '{{(index .Subnets 0).Subnet}}')"
        else
            echo "  pas encore créé — sera un /24 dans 10.89.0.0/16 (choisi par 'run.sh up')"
        fi
        echo "✅ Vérifications préliminaires OK."
        ;;
    *)
        echo "usage: run.sh {up|shell [-- CMD...]|test|down [--purge-network]|secrets|doctor}" >&2
        exit 1
        ;;
esac
