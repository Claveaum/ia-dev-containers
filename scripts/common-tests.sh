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

CLIENT_NAME="test-client"
PKG_VOLUME_TARGET="/home/devuser/.local"
PROJECT_ROOT="/tmp/mon-projet"
REPO_ROOT="/tmp/mon-projet/ia-dev-containers"
unset IA_PROJECT_NAME IA_SELF_MOUNT_RW GATEWAY_ADDR_MODE GATEWAY_HARDENED 2>/dev/null || true

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

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

echo ""
echo "Résultat : $PASS réussis, $FAIL échoués"
[ "$FAIL" -eq 0 ]
