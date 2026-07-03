#!/bin/bash
# Moteur d'orchestration générique du sandbox à deux conteneurs (gateway +
# workspace), partagé par tous les clients (mistral-vibe, copilot, et tout
# futur client). Sourcé par clients/*/scripts/run.sh, après lib.sh (données
# propres au client) et common.sh (gabarits de noms + fonctions génériques).
# Doit être sourcé, pas exécuté directement — le seul point d'entrée est
# orchestrator_main(), appelée par le run.sh du client avec "$@".
#
# Usage (identique pour tous les clients) :
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

need_podman() {
    command -v podman &> /dev/null || { echo "❌ podman n'est pas installé" >&2; exit 1; }
    preflight_platform_check
}

build_images() {
    echo "🔧 Construction des images..."
    podman image exists "$GATEWAY_BASE_IMAGE"   || podman build -t "$GATEWAY_BASE_IMAGE"   "$REPO_ROOT/gateway-base"
    podman image exists "$WORKSPACE_BASE_IMAGE" || podman build -t "$WORKSPACE_BASE_IMAGE" "$REPO_ROOT/workspace-base"
    podman build -t "$GATEWAY_IMAGE"   "$CLIENT_ROOT/gateway"
    # Contexte = racine du dépôt (pas CLIENT_ROOT) pour que le Dockerfile
    # puisse COPY scripts/security-tests-common.sh, partagé entre clients et
    # situé hors de clients/<client>/.
    podman build -t "$WORKSPACE_IMAGE" -f "$CLIENT_ROOT/workspace/Dockerfile" "$REPO_ROOT"
}

# Génère .devcontainer/devcontainer.json à partir du template : les valeurs
# (réseau scopé projet, chemin du projet, volume de paquets scopé projet) ne
# peuvent pas être codées en dur, elles dépendent de PROJECT_ROOT/PROJECT_NAME.
render_devcontainer() {
    local template="$CLIENT_ROOT/.devcontainer/devcontainer.json.template"
    local out="$CLIENT_ROOT/.devcontainer/devcontainer.json"
    [ -f "$template" ] || return 0
    # PROJECT_ROOT est un chemin hôte arbitraire (pas sanitizé comme
    # NETWORK_NAME/PKG_VOLUME) : échappé via _sed_escape_replacement
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
    # Une entrée de sed -e par élément de EXTRA_VOLUMES (scripts/common.sh),
    # chacune substituant le jeton propre à cette entrée (déclaré par
    # l'adaptateur, ex. "__COPILOT_STATE_VOLUME__") par son entrée mounts[]
    # — tableau vide (donc aucune substitution) si le client n'en déclare
    # pas, comme mistral-vibe aujourd'hui.
    local extra_volume_sed_args=()
    local extra_entry extra_target extra_placeholder extra_line
    for extra_entry in "${EXTRA_VOLUMES[@]+"${EXTRA_VOLUMES[@]}"}"; do
        extra_target="${extra_entry%%:*}"
        extra_placeholder="${extra_entry#*:}"
        extra_line="\"source=$(_extra_volume_name "$extra_target"),target=${extra_target},type=volume\","
        extra_volume_sed_args+=(-e "s|${extra_placeholder}|$(_sed_escape_replacement "$extra_line")|g")
    done
    # PKG_VOLUME_PLACEHOLDER (ex. "__LOCAL_VOLUME__", "__NPM_GLOBAL_VOLUME__")
    # est un jeton fixe posé par l'adaptateur (lib.sh) : sûr à interpoler tel
    # quel dans le motif sed (aucun caractère spécial), contrairement à sa
    # valeur de remplacement (PKG_VOLUME) qui passe par _sed_escape_replacement.
    # __WORKSPACE_SECURITY_ARGS__ : contrat d'isolation (userns, cap-drop,
    # tmpfs, read-only, security-opt) rendu en JSON depuis
    # WORKSPACE_SECURITY_ARGS (scripts/common.sh), identique aux flags que
    # start_workspace() applique via `podman run` — une seule source pour les
    # deux chemins de lancement.
    # __PROXY_URL__ : même valeur que start_workspace() (proxy_url(),
    # scripts/common.sh), pour que GATEWAY_ADDR_MODE=static soit aussi
    # respecté côté VS Code, pas seulement côté CLI.
    # __CLIENT_NAME__ : CLIENT_NAME (posé par l'adaptateur, lib.sh) plutôt
    # qu'une valeur codée en dur dans le template.
    sed \
        -e "s|__NETWORK_NAME__|$(_sed_escape_replacement "$NETWORK_NAME")|g" \
        -e "s|__PROJECT_ROOT__|$(_sed_escape_replacement "$PROJECT_ROOT")|g" \
        -e "s|${PKG_VOLUME_PLACEHOLDER}|$(_sed_escape_replacement "$PKG_VOLUME")|g" \
        -e "s|__SELF_PROTECT_MOUNT__|$(_sed_escape_replacement "$self_protect_line")|g" \
        -e "s|__WORKSPACE_SECURITY_ARGS__|$(_sed_escape_replacement "$(workspace_security_args_json)")|g" \
        -e "s|__CACHE_VOLUME__|$(_sed_escape_replacement "$CACHE_VOLUME")|g" \
        -e "s|__PROXY_URL__|$(_sed_escape_replacement "$(proxy_url)")|g" \
        -e "s|__CLIENT_NAME__|$(_sed_escape_replacement "$CLIENT_NAME")|g" \
        ${extra_volume_sed_args[@]+"${extra_volume_sed_args[@]}"} \
        "$template" > "$out"
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

    # _collect_arg_lines() (scripts/common.sh) porte le boilerplate while/read
    # bash-3.2-safe une seule fois pour les deux émetteurs ci-dessous.
    _collect_arg_lines secret_args
    local secret_args_list=(${COLLECTED_ARG_LINES[@]+"${COLLECTED_ARG_LINES[@]}"})

    # Auto-protection : remonte ia-dev-containers/ en lecture seule sur
    # lui-même dans /workspace (voir scripts/common.sh: self_protect_mount_arg())
    # — vide si non applicable (relocalisé, dogfooding, IA_SELF_MOUNT_RW=1).
    _collect_arg_lines self_protect_mount_arg
    local self_mount_args=(${COLLECTED_ARG_LINES[@]+"${COLLECTED_ARG_LINES[@]}"})

    # EXTRA_VOLUMES (scripts/common.sh) : volumes persistants optionnels pour
    # l'état du CLI (session, jeton d'auth) hors PKG_VOLUME_TARGET — vide
    # pour un client qui n'en déclare pas (EXTRA_VOLUMES vide).
    _collect_arg_lines extra_volume_mount_args
    local extra_volume_args=(${COLLECTED_ARG_LINES[@]+"${COLLECTED_ARG_LINES[@]}"})

    # WORKSPACE_SECURITY_ARGS (scripts/common.sh) : même contrat d'isolation
    # que .devcontainer/devcontainer.json.template (runArgs), généré depuis
    # cette même valeur par render_devcontainer() — voir le commentaire sur
    # WORKSPACE_SECURITY_ARGS pour le détail de chaque flag.
    podman run --rm -it --name "$WORKSPACE_CONTAINER" \
        --user "$(id -u):$(id -g)" \
        "${WORKSPACE_SECURITY_ARGS[@]}" \
        --network="$NETWORK_NAME" \
        -v "${PROJECT_ROOT}:/workspace" \
        ${self_mount_args[@]+"${self_mount_args[@]}"} \
        -v "${PKG_VOLUME}:${PKG_VOLUME_TARGET}" \
        -v "${CACHE_VOLUME}:/home/devuser/.cache" \
        ${extra_volume_args[@]+"${extra_volume_args[@]}"} \
        -e HTTP_PROXY="$proxy" -e HTTPS_PROXY="$proxy" \
        -e IA_CLIENT="$CLIENT_NAME" \
        ${secret_args_list[@]+"${secret_args_list[@]}"} \
        ${env_args[@]+"${env_args[@]}"} \
        "$WORKSPACE_IMAGE" "$@"
}

# Point d'entrée unique, appelé par le run.sh (wrapper mince) de chaque
# client avec "$@".
orchestrator_main() {
    local cmd="${1:-shell}"
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
}
