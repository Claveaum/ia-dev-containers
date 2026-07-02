#!/bin/bash
# Fonctions génériques partagées par tous les clients (mistral-vibe, copilot,
# et tout futur client). Sourcé par clients/*/scripts/lib.sh, qui doit déjà
# avoir défini PROJECT_ROOT et CLIENT_NAME avant le `source` ; REPO_ROOT doit
# aussi être défini par l'appelant (run.sh) pour localiser ce fichier.
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

# Échappe une valeur pour un usage sûr comme texte de remplacement dans
# `sed 's|X|VALEUR|g'` : `&` (réinsère le texte matché) et `|` (le délimiteur
# utilisé ici) doivent être échappés, ainsi que `\` lui-même. Sans ça, un
# PROJECT_ROOT contenant l'un de ces caractères (ex: "AT&T Project", ou un
# chemin avec un "|" littéral) corromprait silencieusement le fichier généré
# ou ferait échouer `sed` en pleine commande `run.sh up`.
_sed_escape_replacement() {
    printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'
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
