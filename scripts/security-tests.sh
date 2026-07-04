#!/bin/bash
set -uo pipefail

# =============================================================================
# IA Dev Container - Tests de sécurité (à exécuter DANS le workspace). Point
# d'entrée fixe attendu par start_workspace() (scripts/orchestrator.py) :
# COPY'd en /security-tests.sh par le Dockerfile de chaque client, à côté de
# /lib.sh (l'adaptateur du client, sourcé ci-dessous en premier). Partagé
# entre tous les clients — aucun contenu spécifique à un client ici, tout ce
# qui varie vient de lib.sh, déjà défini au moment où ce script s'exécute :
#   TEST_DOMAIN_PRIMARY    domaine allowlisté qui doit réussir (échec dur sinon)
#   TEST_DOMAIN_SECONDARY  domaine allowlisté propre au service du client
#                          (avertissement seulement si bloqué, pas un échec dur)
#   PKG_VOLUME_TARGET      chemin absolu du volume de paquets (ex. ~/.local)
#   PKG_INSTALL_LABEL      libellé de la commande d'installation (ex. "pip")
#   client_package_manager_tests()  vérifications propres au gestionnaire de
#                          paquets du client (section 4)
# Modèle à deux conteneurs : ce script ne teste plus jamais localhost, il
# vérifie l'accès réel au gateway (HTTP_PROXY) sur le réseau interne.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

PASS=0
FAIL=0
CLIENT="${IA_CLIENT:-unknown}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✅ [PASS]${NC} $1"; ((PASS++)) || true; }
fail() { echo -e "${RED}❌ [FAIL]${NC} $1"; ((FAIL++)) || true; }
warn() { echo -e "${YELLOW}⚠️  [WARN]${NC} $1"; }

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Tests de Sécurité - $CLIENT"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# 1. Isolation utilisateur
# =============================================================================
echo "🔒==== 1. Isolation de l'utilisateur ====🔒"

if [ "$(id -u)" = "0" ]; then
    fail "Le conteneur tourne en root (UID=0) !"
else
    pass "Utilisateur non-root (UID=$(id -u))"
fi

if sudo -n true 2>/dev/null; then
    fail "sudo est accessible sans mot de passe !"
else
    pass "sudo nécessite un mot de passe (ou est bloqué)"
fi

# =============================================================================
# 2. Isolation du système de fichiers
# =============================================================================
echo ""
echo "📁==== 2. Isolation du système de fichiers ====📁"

if touch /test-security 2>/dev/null; then
    fail "Le filesystem racine (/) n'est pas en lecture seule !"
    rm -f /test-security 2>/dev/null || true
else
    pass "/ est en lecture seule"
fi

# /workspace est un bind-mount du vrai projet hôte (pas un volume vide) :
# un nom fixe risquerait de "toucher" (mtime) puis supprimer un fichier
# préexistant du projet s'il portait ce nom. Nom unique au PID + vérif
# d'inexistence avant écriture, pour ne jamais rm un fichier qu'on n'a pas
# créé nous-mêmes.
ws_test_file="/workspace/.ia-sandbox-write-test.$$"
if [ -e "$ws_test_file" ]; then
    warn "$ws_test_file existe déjà, test d'écriture ignoré (collision improbable)"
elif touch "$ws_test_file" 2>/dev/null; then
    pass "/workspace est accessible en écriture"
    rm -f "$ws_test_file"
else
    fail "Impossible d'écrire dans /workspace !"
fi

# Auto-protection de ia-dev-containers/ (voir README, section Architecture) :
# absent si la copie a été relocalisée hors du projet (IA_PROJECT_ROOT), si
# ia-dev-containers est lui-même le projet sandboxé, ou si IA_SELF_MOUNT_RW=1
# — dans ces cas, rien à vérifier ici, ce n'est pas un échec.
sc_test_file="/workspace/ia-dev-containers/.ia-write-test.$$"
if [ ! -d "/workspace/ia-dev-containers" ]; then
    warn "/workspace/ia-dev-containers absent (relocalisé, dogfooding, ou IA_SELF_MOUNT_RW=1) — auto-protection non applicable"
elif [ -e "$sc_test_file" ]; then
    warn "$sc_test_file existe déjà, test d'auto-protection ignoré (collision improbable)"
else
    if cat "/workspace/ia-dev-containers/README.md" > /dev/null 2>&1; then
        pass "ia-dev-containers/ reste lisible depuis le workspace"
    else
        fail "ia-dev-containers/ n'est plus lisible depuis le workspace !"
    fi
    if touch "$sc_test_file" 2>/dev/null; then
        fail "ia-dev-containers/ est accessible en écriture depuis le workspace ! (auto-protection cassée)"
        rm -f "$sc_test_file"
    else
        pass "ia-dev-containers/ est protégé en écriture depuis le workspace"
    fi
fi

# Affichage "~/xxx" (comme avant la généricisation) plutôt que le chemin
# absolu complet : PKG_VOLUME_TARGET est toujours sous /home/devuser.
pkg_display="~${PKG_VOLUME_TARGET#/home/devuser}"
if touch "${PKG_VOLUME_TARGET}/test-security" 2>/dev/null; then
    pass "$pkg_display est accessible en écriture (pour $PKG_INSTALL_LABEL)"
    rm -f "${PKG_VOLUME_TARGET}/test-security"
else
    fail "Impossible d'écrire dans $pkg_display !"
fi

# EXTRA_VOLUMES (lib.sh) : optionnel, un test d'écriture par entrée — vide
# pour un client qui n'a pas d'état à persister hors PKG_VOLUME_TARGET
# (ex. mistral-vibe).
for extra_entry in "${EXTRA_VOLUMES[@]+"${EXTRA_VOLUMES[@]}"}"; do
    extra_target="${extra_entry%%:*}"
    extra_display="~${extra_target#/home/devuser}"
    if touch "${extra_target}/test-security" 2>/dev/null; then
        pass "$extra_display est accessible en écriture (état persistant du CLI)"
        rm -f "${extra_target}/test-security"
    else
        fail "Impossible d'écrire dans $extra_display !"
    fi
done

# =============================================================================
# 3. Isolation réseau — les 3 vérifications non négociables du redesign
# =============================================================================
echo ""
echo "🌐==== 3. Isolation réseau ====🌐"

# Test 3.1 : aucun accès direct (le réseau interne n'a pas de route par défaut)
if curl -s -m5 https://1.1.1.1 -o /dev/null 2>&1; then
    fail "Accès direct à internet réussi (1.1.1.1) — le workspace ne devrait avoir AUCUNE route directe !"
else
    pass "Accès direct à internet bloqué (pas de route)"
fi

# Test 3.2 : domaine principal autorisé via le gateway — échec dur si bloqué
if curl -s -m5 -x "${HTTP_PROXY:-http://gateway:3128}" "https://${TEST_DOMAIN_PRIMARY}" -o /dev/null -w '%{http_code}' 2>/dev/null | grep -qE '^[23]'; then
    pass "Accès via le gateway à $TEST_DOMAIN_PRIMARY (autorisé) réussi"
else
    fail "Accès via le gateway à $TEST_DOMAIN_PRIMARY (autorisé) échoué !"
fi

# Test 3.3 : domaine secondaire, propre au service du client, via le gateway
# — avertissement seulement si bloqué (voir lib.sh du client pour le détail
# de ce que ce domaine vérifie spécifiquement).
# (curl écrit déjà "000" lui-même via -w en cas d'échec de connexion ; ne pas
# ajouter de `|| echo "000"` après, ça doublerait la sortie en "000000".)
code=$(curl -s -m5 -x "${HTTP_PROXY:-http://gateway:3128}" "https://${TEST_DOMAIN_SECONDARY}" -o /dev/null -w '%{http_code}' 2>/dev/null)
code="${code:-000}"
if [ "$code" != "000" ]; then
    pass "Accès via le gateway à $TEST_DOMAIN_SECONDARY autorisé (http=$code)"
else
    warn "Accès via le gateway à $TEST_DOMAIN_SECONDARY bloqué (vérifiez allowed-urls.txt)"
fi

# Test 3.4 : domaine NON autorisé via le gateway doit être bloqué
code=$(curl -s -m5 -x "${HTTP_PROXY:-http://gateway:3128}" https://facebook.com -o /dev/null -w '%{http_code}' 2>/dev/null)
code="${code:-000}"
if [ "$code" = "403" ] || [ "$code" = "000" ]; then
    pass "Accès via le gateway à facebook.com correctement bloqué (http=$code)"
else
    fail "Accès via le gateway à facebook.com réussi (http=$code) — contournement de l'allowlist !"
fi

# =============================================================================
# 4. Spécifique au gestionnaire de paquets du client
# =============================================================================
echo ""
echo "📦==== 4. Spécifique $CLIENT ====📦"

client_package_manager_tests

# =============================================================================
# 5. Résumé
# =============================================================================
echo ""
echo "📊==== 5. Résumé ====📊"
echo ""
echo -e "   ${GREEN}✅ Réussis : $PASS${NC}"
echo -e "   ${RED}❌ Échoués : $FAIL${NC}"
echo ""

TOTAL=$((PASS + FAIL))
SCORE=100
[ "$TOTAL" -gt 0 ] && SCORE=$(( (PASS * 100) / TOTAL ))
echo "   🎯 Score de sécurité : ${SCORE}%"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "   ${GREEN}✅ TOUS LES TESTS ONT RÉUSSI !${NC}"
    exit 0
else
    echo -e "   ${RED}❌ LE SANDBOX N'EST PAS COMPLÈTEMENT VÉRIFIÉ !${NC}"
    exit 1
fi
