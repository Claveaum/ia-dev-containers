#!/bin/bash
# Fonctions et gabarits de noms génériques partagés par tous les clients
# (mistral-vibe, copilot, et tout futur client), utilisés côté hôte
# uniquement (jamais copié dans une image — voir scripts/orchestrator.sh
# pour le moteur d'orchestration, et scripts/security-tests-common.sh pour
# les vérifications côté conteneur). Sourcé par clients/*/scripts/run.sh,
# après le lib.sh du client, qui doit déjà avoir défini PROJECT_ROOT,
# CLIENT_NAME et PKG_VOLUME_TARGET avant le `source` ; REPO_ROOT doit aussi
# être défini par l'appelant (run.sh) pour localiser ce fichier (et pour le
# calcul d'auto-protection ci-dessous, qui compare REPO_ROOT à PROJECT_ROOT).
# Doit être sourcé, pas exécuté directement.

_sanitize_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-' | tr '[:upper:]' '[:lower:]'
}

# Ce dossier (ia-dev-containers) est une copie autonome placée à la racine
# du projet à sandboxer (ex: mon-projet/ia-dev-containers/) — PROJECT_ROOT
# est son dossier parent. Plusieurs projets (donc plusieurs copies) peuvent
# tourner en parallèle sur la même machine : tous les noms de ressources
# Podman ci-dessous sont scopés par PROJECT_NAME pour éviter toute collision
# entre projets. Contournable via IA_PROJECT_NAME (ex: deux projets qui
# partagent le même nom de dossier) — passé par _sanitize_name() comme le nom
# dérivé par défaut, sinon une valeur avec majuscule/espace casse `podman
# build` (tags en majuscule refusés) ou `podman network create`/`create
# --name` (espaces refusés).
PROJECT_NAME="$(_sanitize_name "${IA_PROJECT_NAME:-$(basename "$PROJECT_ROOT")}")"

# --- Gabarits génériques de noms de ressources Podman, par (client, projet) ---
# Identiques pour tous les clients aujourd'hui (aucune référence spécifique à
# un client au-delà de CLIENT_NAME/PKG_VOLUME_TARGET, tous deux déjà posés
# par l'adaptateur avant de sourcer ce fichier) — déclarés ici plutôt que
# dans chaque lib.sh pour qu'un futur client n'ait pas à les redéclarer.
GATEWAY_BASE_IMAGE="ia-dev-containers-gateway-base:latest"
WORKSPACE_BASE_IMAGE="ia-dev-containers-workspace-base:latest"
GATEWAY_IMAGE="ia-dev-containers-gateway-${CLIENT_NAME}-${PROJECT_NAME}:latest"
WORKSPACE_IMAGE="ia-dev-containers-workspace-${CLIENT_NAME}-${PROJECT_NAME}:latest"
NETWORK_NAME="ia-gw-internal-${CLIENT_NAME}-${PROJECT_NAME}"
GATEWAY_CONTAINER="${CLIENT_NAME}-${PROJECT_NAME}-gateway"
WORKSPACE_CONTAINER="${CLIENT_NAME}-${PROJECT_NAME}-workspace"
CACHE_VOLUME="${CLIENT_NAME}-cache"

# Volume des VRAIS paquets installés par le client (pip/npm/...), pas un
# simple cache : scopé par projet, pour qu'un paquet compromis installé dans
# un projet ne devienne pas silencieusement importable depuis un autre. Nom
# dérivé de CLIENT_NAME + du dernier segment de PKG_VOLUME_TARGET (ex.
# "/home/devuser/.local" -> "local") plutôt que déclaré tel quel par chaque
# adaptateur — vérifié équivalent aux noms historiques ("mistral-vibe-local-
# ${PROJECT_NAME}", "copilot-npm-global-${PROJECT_NAME}") pour ne pas
# orpheliner les volumes déjà installés d'un utilisateur existant.
PKG_VOLUME="${CLIENT_NAME}-$(basename "$PKG_VOLUME_TARGET" | sed -e 's/^\.//')-${PROJECT_NAME}"

# Volumes optionnels supplémentaires pour l'état persistant d'un CLI (ex.
# ~/.copilot : session, jeton d'auth, logs) quand il écrit ailleurs que
# PKG_VOLUME_TARGET — déclarés par l'adaptateur (lib.sh) via EXTRA_VOLUMES,
# un tableau de chemins cibles simples (pas de jeton devcontainer à
# associer : le mount, côté CLI comme côté devcontainer.json, est dérivé
# depuis cette même valeur — voir extra_volume_mount_args() ci-dessous et
# devcontainer_mounts_json() dans scripts/orchestrator.sh). Vide par défaut
# (mistral-vibe aujourd'hui, aucun besoin) — un client peut en déclarer
# autant qu'il lui faut. Le repli `${EXTRA_VOLUMES[@]+...}` gère aussi bien
# un tableau vide qu'un tableau jamais déclaré par lib.sh (bash 3.2/set -u,
# même piège que _collect_arg_lines ci-dessous).
EXTRA_VOLUMES=(${EXTRA_VOLUMES[@]+"${EXTRA_VOLUMES[@]}"})

# Nom du volume Podman pour une entrée de EXTRA_VOLUMES, dérivé comme
# PKG_VOLUME : CLIENT_NAME + dernier segment du chemin, scopé par projet —
# un jeton d'auth compromis dans un projet ne doit pas être silencieusement
# réutilisable depuis un autre.
_extra_volume_name() {
    printf '%s-%s-%s' "$CLIENT_NAME" "$(basename "$1" | sed -e 's/^\.//')" "$PROJECT_NAME"
}

# Arguments `-v` pour chaque entrée de EXTRA_VOLUMES, une ligne par argument
# (même idiome que self_protect_mount_arg()/secret_args(), consommé via
# _collect_arg_lines()) — rien du tout si EXTRA_VOLUMES est vide.
extra_volume_mount_args() {
    local target
    for target in "${EXTRA_VOLUMES[@]+"${EXTRA_VOLUMES[@]}"}"; do
        printf -- '-v\n%s:%s\n' "$(_extra_volume_name "$target")" "$target"
    done
}

# dns   : le workspace joint le gateway via son alias réseau "gateway"
#         (résolu par aardvark-dns sur le réseau interne).
# static: repli sur l'IP fixe du gateway, si la résolution DNS pose problème.
GATEWAY_ADDR_MODE="${GATEWAY_ADDR_MODE:-dns}"

# 0 = Phase 1 (gateway non-root direct, pas de nftables)
# 1 = Phase 2 (gateway root-in-userns -> nftables -> abandon de privilèges)
GATEWAY_HARDENED="${GATEWAY_HARDENED:-0}"

# Contrat d'isolation du conteneur workspace (namespace utilisateur inclus) :
# appliqué tel quel par start_workspace() (scripts/orchestrator.sh, `podman
# run`), et rendu en JSON dans devcontainer.json (runArgs) par
# workspace_security_args_json() (scripts/orchestrator.sh, colocalisée avec
# son unique appelante render_devcontainer()) — source unique pour que les
# deux chemins de lancement (CLI, VS Code) ne puissent pas diverger sur les
# garanties de sécurité réelles.
# `userns=keep-id` : mappe l'UID/GID de l'hôte dans le conteneur (au lieu de
# root), pour que les fichiers créés dans /workspace appartiennent au bon
# utilisateur côté hôte. Correspond à `--user "$(id -u):$(id -g)"`, posé à
# part par start_workspace() (non templatable : la spec devcontainer utilise
# containerUser/remoteUser à la place d'un `--user` littéral).
# `security-opt=label=disable` : /workspace est un bind-mount d'un chemin
# hôte arbitraire (PROJECT_ROOT), pas un volume Podman. Sous SELinux
# (Fedora/RHEL), un bind-mount d'un chemin arbitraire est refusé sans
# relabeling. L'alternative `:Z` sur le mount relabelerait récursivement les
# fichiers RÉELS du projet sur le disque (effet de bord persistant hors du
# sandbox) ; label=disable désactive le confinement SELinux pour ce
# conteneur sans toucher aux labels du projet — vérifié : les deux
# permettent l'écriture, seul label=disable laisse `ls -Z` sur le projet
# hôte inchangé. No-op inoffensif sur les hôtes sans SELinux.
WORKSPACE_SECURITY_ARGS=(
    --userns=keep-id
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --security-opt=label=disable
    --read-only
    --tmpfs=/tmp
    --tmpfs=/run
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

# Remplit COLLECTED_ARG_LINES (tableau global, scratch — pas de namerefs
# `declare -n` ici : bash 3.2 sur macOS ne les supporte pas) avec la sortie
# de la fonction émettrice passée en argument (ex. secret_args(),
# self_protect_mount_arg() : une ligne par élément d'argument `podman run`,
# rien du tout si non applicable). while/read plutôt que `mapfile` (bash
# >=4) : macOS fournit bash 3.2 en /bin/bash par défaut, où `mapfile`
# n'existe pas. L'appelant doit copier COLLECTED_ARG_LINES dans son propre
# tableau local juste après l'appel (avant le prochain appel, qui l'écrase) :
#   _collect_arg_lines secret_args
#   local secret_args_list=(${COLLECTED_ARG_LINES[@]+"${COLLECTED_ARG_LINES[@]}"})
# Le repli `${arr[@]+"${arr[@]}"}` est nécessaire aussi bien ici qu'à la
# copie : sous `set -u`, bash 3.2 (contrairement à bash >=4.4) lève "unbound
# variable" sur l'expansion d'un tableau vide (vérifié empiriquement :
# podman run --rm -i bash:3.2 ...).
_collect_arg_lines() {
    local emitter="$1"
    COLLECTED_ARG_LINES=()
    while IFS= read -r line; do
        COLLECTED_ARG_LINES+=("$line")
    done < <("$emitter")
}

# --- Allocation de subnet par (projet, client) ---
# squid.conf (workspace_net) et gateway.nft acceptent tout 10.89.0.0/16 :
# chaque réseau --internal reçoit un /24 déterministe dans cette plage
# (dérivé du chemin absolu du projet), avec repli séquentiel en cas de
# collision (deux projets différents peuvent, rarement, dériver le même
# offset). `cksum` est utilisé pour le hash : POSIX, disponible sur
# Linux/macOS/WSL2 sans dépendance supplémentaire (contrairement à sha256sum,
# absent de macOS par défaut).
_subnet_offset_seed() {
    printf '%s:%s' "$PROJECT_ROOT" "$CLIENT_NAME" | cksum | awk '{print $1}'
}

# Résout SUBNET/GATEWAY_IP et crée le réseau --internal s'il n'existe pas
# encore. Utilise $NETWORK_NAME, défini par l'appelant (clients/*/scripts/
# lib.sh) après avoir sourcé ce fichier. Si le réseau existe déjà (cas
# normal : deuxième `run.sh` sur le même projet), relit son subnet réel via
# `podman network inspect` plutôt que de recalculer — source de vérité
# unique, ne peut pas diverger même après un éventuel repli de collision lors
# de la création initiale.
# --- Auto-protection de ia-dev-containers/ contre l'écriture depuis le workspace ---
# /workspace est un bind-mount rw de PROJECT_ROOT ; quand cette copie de
# ia-dev-containers est déposée À L'INTÉRIEUR de PROJECT_ROOT (déploiement
# in-tree standard), le CLI IA (non fiable par hypothèse) peut sinon modifier
# sa propre config sandbox (allowed-urls.txt, run.sh/lib.sh, Dockerfiles)
# depuis l'intérieur du conteneur — voir README, section Architecture. On
# empile un second bind-mount, en lecture seule, de REPO_ROOT sur lui-même :
# la lecture (et donc `git status` sur le projet hôte) reste identique, seule
# l'écriture est bloquée. Retourne le chemin relatif de REPO_ROOT sous
# PROJECT_ROOT sur stdout, ou rien (chaîne vide) si aucune protection n'est
# applicable :
#   - IA_SELF_MOUNT_RW=1              échappatoire explicite
#   - REPO_ROOT == PROJECT_ROOT       dogfooding (ia-dev-containers sandboxé
#                                     lui-même) : remonter /workspace en
#                                     lecture seule sur lui-même casserait
#                                     tout le sandbox
#   - REPO_ROOT hors de PROJECT_ROOT  copie relocalisée via IA_PROJECT_ROOT :
#                                     rien à protéger, /workspace ne contient
#                                     déjà pas cette copie
_self_protect_relpath() {
    [ "${IA_SELF_MOUNT_RW:-0}" = "1" ] && return 0
    [ "$REPO_ROOT" = "$PROJECT_ROOT" ] && return 0
    case "$REPO_ROOT" in
        "$PROJECT_ROOT"/*) ;;
        *) return 0 ;;
    esac
    printf '%s' "${REPO_ROOT#"$PROJECT_ROOT"/}"
}

# Arguments `-v` à passer à `podman run` pour activer l'auto-protection,
# imprimés une ligne par argument (même idiome que secret_args() dans
# scripts/orchestrator.sh, consommé via _collect_arg_lines() ci-dessus) —
# pas de sortie du tout si non applicable.
self_protect_mount_arg() {
    local rel
    rel="$(_self_protect_relpath)"
    [ -n "$rel" ] || return 0
    printf -- '-v\n%s:/workspace/%s:ro\n' "$REPO_ROOT" "$rel"
}

# Résumé lisible pour `run.sh doctor`.
self_protect_status() {
    if [ "${IA_SELF_MOUNT_RW:-0}" = "1" ]; then
        printf 'désactivée (IA_SELF_MOUNT_RW=1)'
    elif [ -n "$(_self_protect_relpath)" ]; then
        printf 'active (lecture seule sur ia-dev-containers/)'
    else
        printf 'non applicable (relocalisé hors du projet, ou dogfooding)'
    fi
}

ensure_network_and_ip() {
    if podman network exists "$NETWORK_NAME"; then
        SUBNET="$(podman network inspect "$NETWORK_NAME" --format '{{(index .Subnets 0).Subnet}}')"
    else
        local seed offset created=0 i last_err
        seed="$(_subnet_offset_seed)"
        offset=$(( (seed % 240) + 10 ))
        echo "🔧 Création du réseau interne $NETWORK_NAME (--internal)..."
        for i in $(seq 1 20); do
            SUBNET="10.89.${offset}.0/24"
            if last_err="$(podman network create --internal --subnet "$SUBNET" "$NETWORK_NAME" 2>&1 >/dev/null)"; then
                created=1
                break
            fi
            offset=$(( offset + 1 ))
            [ "$offset" -gt 249 ] && offset=10
        done
        if [ "$created" != "1" ]; then
            # N'importe quelle erreur (pas seulement une collision de subnet)
            # fait échouer chaque essai de la boucle : sur Windows/podman
            # machine avec le bug nftables #25201 par exemple, TOUTES les
            # tentatives échoueraient pour la même raison (pare-feu, pas
            # subnet). Afficher la dernière erreur réelle plutôt qu'un
            # message générique qui pointerait vers la mauvaise cause.
            echo "❌ Impossible de créer $NETWORK_NAME après 20 essais de subnet." >&2
            echo "   Dernière erreur podman : $last_err" >&2
            echo "   Si l'erreur mentionne nftables sur Windows (podman machine), voir docs/windows.md." >&2
            exit 1
        fi
    fi
    GATEWAY_IP="$(printf '%s' "$SUBNET" | cut -d. -f1-3).2"
}
