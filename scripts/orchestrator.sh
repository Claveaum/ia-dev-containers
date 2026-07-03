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
    # Inconditionnel, comme les deux builds client ci-dessous : `podman build`
    # a déjà son propre cache de layers (no-op rapide si le Dockerfile/contexte
    # n'a pas changé). Un garde `podman image exists || ...` ici empêcherait
    # silencieusement toute modification future de *-base/Dockerfile de
    # jamais prendre effet sur une machine où le tag existe déjà depuis un
    # build précédent (vécu : un `RUN` ajouté à workspace-base/Dockerfile
    # restait invisible, l'overlay client échouant ensuite en FROM dessus).
    podman build -t "$GATEWAY_BASE_IMAGE"   "$REPO_ROOT/gateway-base"
    podman build -t "$WORKSPACE_BASE_IMAGE" "$REPO_ROOT/workspace-base"
    podman build -t "$GATEWAY_IMAGE"   "$CLIENT_ROOT/gateway"
    # Contexte = racine du dépôt (pas CLIENT_ROOT) pour que le Dockerfile
    # puisse COPY scripts/security-tests-common.sh, partagé entre clients et
    # situé hors de clients/<client>/.
    podman build -t "$WORKSPACE_IMAGE" -f "$CLIENT_ROOT/workspace/Dockerfile" "$REPO_ROOT"
}

# Échappe une valeur pour un usage sûr comme texte de remplacement dans
# `sed 's|X|VALEUR|g'` : `&` (réinsère le texte matché) et `|` (le délimiteur
# utilisé ici) doivent être échappés, ainsi que `\` lui-même. Sans ça, un
# PROJECT_ROOT contenant l'un de ces caractères (ex: "AT&T Project", ou un
# chemin avec un "|" littéral) corromprait silencieusement le fichier généré
# ou ferait échouer `sed` en pleine commande `run.sh up`. Deuxième passe :
# échappe aussi les retours à la ligne internes en `\<retour à la ligne>`,
# seule syntaxe qu'accepte `sed -e "s|X|VALEUR|g"` pour un texte de
# remplacement multi-lignes (ex. workspace_security_args_json() ci-dessous) —
# no-op sur une valeur mono-ligne (rien à remplacer). Fait en bash pur
# (`${var//motif/remplacement}`, bash 3.2-safe) plutôt qu'avec un deuxième
# `sed` : l'idiome GNU sed `:a;N;$!ba;s/\n/\\\n/g` pour joindre les lignes
# n'est pas portable sur BSD sed (macOS), qui interprète `:a;N;...` comme une
# seule étiquette malformée plutôt que trois commandes distinctes.
# Colocalisée ici (pas dans scripts/common.sh) : son unique appelante est
# render_devcontainer() ci-dessous, comme les autres helpers de rendu JSON
# qui suivent.
_sed_escape_replacement() {
    local escaped nl
    escaped="$(printf '%s' "$1" | sed -e 's/[\&|]/\\&/g')"
    nl=$'\n'
    printf '%s' "${escaped//$nl/\\$nl}"
}

# WORKSPACE_SECURITY_ARGS (scripts/common.sh), un élément JSON par ligne
# (avec virgule finale : toujours suivi d'au moins "--network=..." dans le
# squelette). Passé par render_devcontainer() à _sed_escape_replacement(),
# qui échappe aussi les retours à la ligne internes à cette valeur
# multi-lignes.
workspace_security_args_json() {
    local arg
    for arg in "${WORKSPACE_SECURITY_ARGS[@]}"; do
        printf '    "%s",\n' "$arg"
    done
}

# Génère le contenu de "mounts": [ ... ] pour render_devcontainer() — mêmes
# volumes, même ordre que start_workspace() ci-dessous, depuis les mêmes
# données (scripts/common.sh : _self_protect_relpath(), PKG_VOLUME,
# EXTRA_VOLUMES, CACHE_VOLUME) : une seule source pour "quels volumes sont
# montés", au lieu d'un JSON dupliqué à la main par client (la classe de bug
# déjà rencontrée pour ~/.copilot — voir README, section Architecture).
# CACHE_VOLUME reste toujours en dernier, sans virgule finale : seul élément
# garanti systématiquement présent en dernière position, quel que soit
# EXTRA_VOLUMES (vide ou non).
devcontainer_mounts_json() {
    local self_protect_relpath
    self_protect_relpath="$(_self_protect_relpath)"
    if [ -n "$self_protect_relpath" ]; then
        printf '    "source=%s,target=/workspace/%s,type=bind,readonly",\n' "$REPO_ROOT" "$self_protect_relpath"
    fi
    printf '    "source=%s,target=%s,type=volume",\n' "$PKG_VOLUME" "$PKG_VOLUME_TARGET"
    local extra_target
    for extra_target in "${EXTRA_VOLUMES[@]+"${EXTRA_VOLUMES[@]}"}"; do
        printf '    "source=%s,target=%s,type=volume",\n' "$(_extra_volume_name "$extra_target")" "$extra_target"
    done
    printf '    "source=%s,target=/home/devuser/.cache,type=volume"\n' "$CACHE_VOLUME"
}

# customizations.vscode.extensions (lib.sh: DEVCONTAINER_EXTENSIONS), sans
# virgule finale sur le dernier élément (pas de ligne statique garantie
# après, contrairement à workspace_security_args_json() ci-dessus) — virgule
# en tête de chaque élément sauf le premier plutôt qu'en fin, pour ne pas
# dépendre de la position dans la boucle.
devcontainer_extensions_json() {
    local ext first=1
    for ext in "${DEVCONTAINER_EXTENSIONS[@]+"${DEVCONTAINER_EXTENSIONS[@]}"}"; do
        if [ "$first" -eq 1 ]; then
            printf '        "%s"' "$ext"
            first=0
        else
            printf ',\n        "%s"' "$ext"
        fi
    done
    printf '\n'
}

# Génère .devcontainer/devcontainer.json à partir du squelette partagé
# (scripts/devcontainer-skeleton.json.template, identique pour tous les
# clients) : les valeurs (réseau scopé projet, chemin du projet, volumes
# scopés projet) ne peuvent pas être codées en dur, elles dépendent de
# PROJECT_ROOT/PROJECT_NAME ; le nom affiché, les extensions/réglages VS
# Code et le message d'installation viennent de l'adaptateur (lib.sh :
# DEVCONTAINER_DISPLAY_NAME, DEVCONTAINER_EXTENSIONS,
# DEVCONTAINER_SETTINGS_JSON, PKG_INSTALL_HINT).
render_devcontainer() {
    local template="$REPO_ROOT/scripts/devcontainer-skeleton.json.template"
    local out="$CLIENT_ROOT/.devcontainer/devcontainer.json"
    [ -f "$template" ] || return 0
    # Le dossier .devcontainer/ ne contient plus de fichier suivi par git
    # (le template est désormais partagé, pas per-client) : le créer au
    # besoin plutôt que de dépendre de son existence préalable.
    mkdir -p "$(dirname "$out")"
    # PROJECT_ROOT est un chemin hôte arbitraire (pas sanitizé comme
    # NETWORK_NAME/PKG_VOLUME) : échappé via _sed_escape_replacement pour
    # éviter qu'un "&" ou un "|" dans le chemin ne corrompe silencieusement
    # le fichier généré ou ne fasse échouer ce sed.
    # __ALL_MOUNTS__ : contenu de mounts[], voir devcontainer_mounts_json()
    # ci-dessus.
    # __WORKSPACE_SECURITY_ARGS__ : contrat d'isolation (userns, cap-drop,
    # tmpfs, read-only, security-opt) rendu en JSON depuis
    # WORKSPACE_SECURITY_ARGS (scripts/common.sh), identique aux flags que
    # start_workspace() applique via `podman run` — une seule source pour les
    # deux chemins de lancement.
    # __PROXY_URL__ : même valeur que start_workspace() (proxy_url(),
    # scripts/common.sh), pour que GATEWAY_ADDR_MODE=static soit aussi
    # respecté côté VS Code, pas seulement côté CLI.
    # __CLIENT_NAME__, __DEVCONTAINER_DISPLAY_NAME__, __PKG_INSTALL_HINT__,
    # __DEVCONTAINER_EXTENSIONS__, __DEVCONTAINER_SETTINGS__ : posés par
    # l'adaptateur (lib.sh) plutôt que codés en dur dans le squelette.
    sed \
        -e "s|__NETWORK_NAME__|$(_sed_escape_replacement "$NETWORK_NAME")|g" \
        -e "s|__PROJECT_ROOT__|$(_sed_escape_replacement "$PROJECT_ROOT")|g" \
        -e "s|__ALL_MOUNTS__|$(_sed_escape_replacement "$(devcontainer_mounts_json)")|g" \
        -e "s|__WORKSPACE_SECURITY_ARGS__|$(_sed_escape_replacement "$(workspace_security_args_json)")|g" \
        -e "s|__PROXY_URL__|$(_sed_escape_replacement "$(proxy_url)")|g" \
        -e "s|__CLIENT_NAME__|$(_sed_escape_replacement "$CLIENT_NAME")|g" \
        -e "s|__DEVCONTAINER_DISPLAY_NAME__|$(_sed_escape_replacement "$DEVCONTAINER_DISPLAY_NAME")|g" \
        -e "s|__PKG_INSTALL_HINT__|$(_sed_escape_replacement "$PKG_INSTALL_HINT")|g" \
        -e "s|__DEVCONTAINER_EXTENSIONS__|$(_sed_escape_replacement "$(devcontainer_extensions_json)")|g" \
        -e "s|__DEVCONTAINER_SETTINGS__|$(_sed_escape_replacement "$DEVCONTAINER_SETTINGS_JSON")|g" \
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
    # que devcontainer.json (runArgs), généré depuis cette même valeur par
    # render_devcontainer() — voir le commentaire sur WORKSPACE_SECURITY_ARGS
    # pour le détail de chaque flag.
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
