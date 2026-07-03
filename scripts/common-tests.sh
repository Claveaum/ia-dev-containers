#!/bin/bash
# Tests rapides, sans Podman, des fonctions pures de scripts/common.sh — pas
# un remplacement de security-tests.sh (qui reste le seul test vérifiant les
# garanties réelles du sandbox : isolation réseau, non-root effectif,
# lecture seule), un complément pour vérifier vite la logique d'orchestration
# elle-même (calcul de noms de ressources, mount d'auto-protection) sans
# avoir à booter de conteneur.
# Usage : ./scripts/common-tests.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
SKIP=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "❌ $desc"
        echo "   attendu : $(printf '%q' "$expected")"
        echo "   obtenu  : $(printf '%q' "$actual")"
        FAIL=$((FAIL + 1))
    fi
}

# Résultat ignoré (ni ✅ ni ❌) : ce projet n'a aucune dépendance hôte hors
# Podman+bash (voir README, tableau Plateformes hôte) — un test qui a besoin
# d'un parseur JSON ne doit pas devenir un nouveau prérequis obligatoire.
# Compté à part pour rester visible sans faire échouer la suite sur un hôte
# minimal.
skip_note() {
    local desc="$1" reason="$2"
    echo "⚠️  $desc — ignoré ($reason)"
    SKIP=$((SKIP + 1))
}

CLIENT_NAME="test-client"
PKG_VOLUME_TARGET="/home/devuser/.local"
PROJECT_ROOT="/tmp/mon-projet"
REPO_ROOT="/tmp/mon-projet/ia-dev-containers"
unset IA_PROJECT_NAME IA_SELF_MOUNT_RW GATEWAY_ADDR_MODE GATEWAY_HARDENED 2>/dev/null || true

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=orchestrator.sh
source "$SCRIPT_DIR/orchestrator.sh"

# --- Gabarits de noms de ressources (dérivés de CLIENT_NAME/PROJECT_NAME) ---
assert_eq "PROJECT_NAME dérivé du dossier" "mon-projet" "$PROJECT_NAME"
assert_eq "GATEWAY_IMAGE" "ia-dev-containers-gateway-test-client-mon-projet:latest" "$GATEWAY_IMAGE"
assert_eq "WORKSPACE_IMAGE" "ia-dev-containers-workspace-test-client-mon-projet:latest" "$WORKSPACE_IMAGE"
assert_eq "NETWORK_NAME" "ia-gw-internal-test-client-mon-projet" "$NETWORK_NAME"
assert_eq "CACHE_VOLUME" "test-client-cache" "$CACHE_VOLUME"
# Vérifié équivalent aux noms historiques ("mistral-vibe-local-\$PROJECT_NAME",
# "copilot-npm-global-\$PROJECT_NAME") lors de la fusion dans common.sh — voir
# scripts/common.sh pour le détail de la dérivation.
assert_eq "PKG_VOLUME dérivé de PKG_VOLUME_TARGET" "test-client-local-mon-projet" "$PKG_VOLUME"

# --- _collect_arg_lines (émetteur vide et émetteur à plusieurs lignes) ---
_empty_emitter() { :; }
_two_line_emitter() { printf -- '-v\nfoo:bar:ro\n'; }
_collect_arg_lines _empty_emitter
empty_result=(${COLLECTED_ARG_LINES[@]+"${COLLECTED_ARG_LINES[@]}"})
assert_eq "_collect_arg_lines émetteur vide (0 élément)" "0" "${#empty_result[@]}"
_collect_arg_lines _two_line_emitter
two_line_result=(${COLLECTED_ARG_LINES[@]+"${COLLECTED_ARG_LINES[@]}"})
assert_eq "_collect_arg_lines émetteur 2 lignes (2 éléments)" "2" "${#two_line_result[@]}"
assert_eq "_collect_arg_lines préserve l'ordre" "-v" "${two_line_result[0]}"

# --- _collect_arg_lines : 3 appels d'affilée (même forme que start_workspace()) ---
# Le test ci-dessus ne vérifie qu'un émetteur à la fois. Le vrai risque est
# que start_workspace() (scripts/orchestrator.sh) enchaîne 3 appels
# consécutifs (secret_args, self_protect_mount_arg, extra_volume_mount_args),
# chacun devant être copié IMMÉDIATEMENT avant le suivant : COLLECTED_ARG_LINES
# est un scratch global écrasé à chaque appel. Un futur refactor qui
# grouperait les 3 appels avant de copier ferait silencieusement alias les 3
# résultats sur le dernier — rien ne le détecterait sans ce test (les vrais
# émetteurs sont tous les trois vides dans cet environnement synthétique,
# ce qui masquerait justement ce bug). Émetteurs jetables distincts, pas les
# vrais émetteurs de production : isole le test de la discipline de copie
# elle-même, indépendamment de ce que ceux-ci renvoient par ailleurs.
_alpha_emitter() { printf -- 'alpha-1\n'; }
_beta_emitter() { printf -- 'beta-1\nbeta-2\n'; }
_gamma_emitter() { printf -- 'gamma-1\ngamma-2\ngamma-3\n'; }
_collect_arg_lines _alpha_emitter
alpha_result=(${COLLECTED_ARG_LINES[@]+"${COLLECTED_ARG_LINES[@]}"})
_collect_arg_lines _beta_emitter
beta_result=(${COLLECTED_ARG_LINES[@]+"${COLLECTED_ARG_LINES[@]}"})
_collect_arg_lines _gamma_emitter
gamma_result=(${COLLECTED_ARG_LINES[@]+"${COLLECTED_ARG_LINES[@]}"})
assert_eq "3 appels d'affilée : alpha intact après beta+gamma" "alpha-1" "${alpha_result[*]}"
assert_eq "3 appels d'affilée : beta intact après gamma" "beta-1 beta-2" "${beta_result[*]}"
assert_eq "3 appels d'affilée : gamma correct" "gamma-1 gamma-2 gamma-3" "${gamma_result[*]}"

# --- workspace_security_args_json (contrat d'isolation, rendu JSON) ---
expected_security_json='    "--userns=keep-id",
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--security-opt=label=disable",
    "--read-only",
    "--tmpfs=/tmp",
    "--tmpfs=/run",'
assert_eq "workspace_security_args_json (7 flags, JSON)" "$expected_security_json" "$(workspace_security_args_json)"

# --- proxy_url (dns vs static) ---
assert_eq "proxy_url en mode dns (défaut)" "http://gateway:3128" "$(proxy_url)"
GATEWAY_ADDR_MODE="static"
GATEWAY_IP="10.89.42.2"
assert_eq "proxy_url en mode static" "http://10.89.42.2:3128" "$(proxy_url)"
GATEWAY_ADDR_MODE="dns"
unset GATEWAY_IP

# --- _sanitize_name ---
assert_eq "sanitize_name minuscule+tirets" "at-t-project" "$(_sanitize_name "AT&T Project")"

# --- _sed_escape_replacement ---
assert_eq "sed_escape ampersand" '/chemin/AT\&T' "$(_sed_escape_replacement '/chemin/AT&T')"
assert_eq "sed_escape pipe" 'a\|b' "$(_sed_escape_replacement 'a|b')"

# --- Auto-protection : cas standard (in-tree) ---
assert_eq "relpath in-tree standard" "ia-dev-containers" "$(_self_protect_relpath)"
assert_eq "mount arg in-tree standard" "-v
${REPO_ROOT}:/workspace/ia-dev-containers:ro" "$(self_protect_mount_arg)"
assert_eq "status in-tree standard" "active (lecture seule sur ia-dev-containers/)" "$(self_protect_status)"

# --- Auto-protection : dogfooding (REPO_ROOT == PROJECT_ROOT) ---
REPO_ROOT="$PROJECT_ROOT"
assert_eq "relpath dogfooding" "" "$(_self_protect_relpath)"
assert_eq "mount arg dogfooding (vide)" "" "$(self_protect_mount_arg)"
assert_eq "status dogfooding" "non applicable (relocalisé hors du projet, ou dogfooding)" "$(self_protect_status)"

# --- Auto-protection : copie relocalisée hors de l'arbre du projet ---
REPO_ROOT="/tmp/ailleurs/ia-dev-containers"
assert_eq "relpath relocalisé" "" "$(_self_protect_relpath)"
assert_eq "mount arg relocalisé (vide)" "" "$(self_protect_mount_arg)"

# --- Auto-protection : échappatoire explicite ---
REPO_ROOT="/tmp/mon-projet/ia-dev-containers"
IA_SELF_MOUNT_RW=1
assert_eq "relpath avec IA_SELF_MOUNT_RW=1" "" "$(_self_protect_relpath)"
assert_eq "status avec IA_SELF_MOUNT_RW=1" "désactivée (IA_SELF_MOUNT_RW=1)" "$(self_protect_status)"
unset IA_SELF_MOUNT_RW

# --- render_devcontainer() contre le VRAI squelette, rendu isolé sous /tmp ---
# Un __TOKEN__ ajouté au squelette mais jamais câblé dans le sed de
# render_devcontainer() survit silencieusement au rendu — la seule façon de
# le remarquer jusqu'ici était de relire le JSON généré à la main après un
# `run.sh up` complet (arrivé 4 fois cette session : self-mount, contrat
# d'isolation, proxy, IA_CLIENT). Rendu contre une copie jetable du VRAI
# squelette partagé (pas un fixture synthétique, qui ne verrait pas un jeton
# oublié dans le vrai fichier) sous /tmp plutôt qu'en place : rendre
# directement dans clients/<client>/.devcontainer/ écraserait le
# devcontainer.json réellement généré par le dernier `run.sh up` de
# l'utilisateur (fichier généré, non suivi par git, mais potentiellement
# ouvert dans VS Code) avec des valeurs de test. Le squelette est partagé
# (scripts/devcontainer-skeleton.json.template), donc REPO_ROOT doit pointer
# vers le vrai dépôt ici (render_devcontainer() le résout via
# "$REPO_ROOT/scripts/...") — seul CLIENT_ROOT (sortie) est temporaire.
#
# _render_devcontainer_orphans() ne détecte qu'UNE forme de corruption (un
# jeton oublié, encore visible tel quel). Une corruption qui mange une
# virgule ou rate un échappement (voir _sed_escape_replacement) ne laisse
# aucun jeton orphelin et passerait ce test silencieusement — d'où le
# parseur JSON(C) ci-dessous, en complément, pas en remplacement.
REPO_ROOT="$SCRIPT_DIR/.."

_render_devcontainer_orphans() {
    local out="$1"
    grep -oE '__[A-Z_]+__' "$out" 2>/dev/null | sort -u | tr '\n' ' ' | sed -e 's/ $//'
}

# Détecte le premier parseur JSON disponible sur l'hôte, par ordre de
# disponibilité probable (macOS/Linux fournissent python3 par défaut ; jq est
# l'idiome bash standard mais pas préinstallé partout ; node est le moins
# probable côté hôte). Chaîne vide si aucun des trois n'est présent.
_json_parser_cmd() {
    if command -v python3 >/dev/null 2>&1; then
        echo python3
    elif command -v jq >/dev/null 2>&1; then
        echo jq
    elif command -v node >/dev/null 2>&1; then
        echo node
    fi
}

# Valide que le JSON(C) produit par render_devcontainer() parse sans erreur.
# Ne retire que les lignes ENTIÈREMENT commentaires (après espaces de tête) :
# un strip naïf de tout ce qui suit "//" corromprait la valeur JSON réelle
# "http://gateway:3128" présente dans postStartCommand des deux templates.
_render_devcontainer_json_valid() {
    local parser="$1" file="$2" stripped status
    stripped="$(mktemp)"
    grep -vE '^[[:space:]]*//' "$file" > "$stripped"
    case "$parser" in
        python3) python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$stripped" 2>/dev/null ;;
        jq)      jq empty "$stripped" 2>/dev/null ;;
        node)    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$stripped" 2>/dev/null ;;
    esac
    status=$?
    rm -f "$stripped"
    return "$status"
}

_json_parser="$(_json_parser_cmd)"

# Découverte automatique plutôt qu'une liste codée en dur : un client ajouté
# sans toucher ce fichier doit quand même être couvert par ce test (sinon
# aucune régression de rendu ne serait détectée pour lui avant un vrai
# `run.sh up`).
for _client_dir in "$SCRIPT_DIR"/../clients/*/; do
    _client="$(basename "$_client_dir")"
    _real_client_root="$SCRIPT_DIR/../clients/$_client"
    _tmp_client_root="$(mktemp -d)"

    # shellcheck source=/dev/null
    source "$_real_client_root/scripts/lib.sh"
    CLIENT_ROOT="$_tmp_client_root"
    GATEWAY_ADDR_MODE="dns"

    render_devcontainer
    _out="$_tmp_client_root/.devcontainer/devcontainer.json"
    assert_eq "render_devcontainer ($_client) : fichier produit" "oui" "$([ -f "$_out" ] && echo oui || echo non)"
    assert_eq "render_devcontainer ($_client) : aucun __TOKEN__ orphelin" "" "$(_render_devcontainer_orphans "$_out")"

    if [ -n "$_json_parser" ]; then
        if _render_devcontainer_json_valid "$_json_parser" "$_out"; then
            echo "✅ render_devcontainer ($_client) : JSON(C) valide ($_json_parser)"
            PASS=$((PASS + 1))
        else
            echo "❌ render_devcontainer ($_client) : JSON(C) invalide selon $_json_parser"
            FAIL=$((FAIL + 1))
        fi
    else
        skip_note "render_devcontainer ($_client) : validité JSON(C)" "aucun de python3/jq/node trouvé sur l'hôte"
    fi

    rm -rf "$_tmp_client_root"
done

echo ""
if [ "$SKIP" -gt 0 ]; then
    echo "Résultat : $PASS réussis, $FAIL échoués, $SKIP ignorés (aucun parseur JSON trouvé sur l'hôte)"
else
    echo "Résultat : $PASS réussis, $FAIL échoués"
fi
[ "$FAIL" -eq 0 ]
