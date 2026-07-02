#!/bin/bash
set -euo pipefail

# =============================================================================
# IA Dev Container - Tests de Sécurité
# Validations spécifiques pour Mistral Vibe CLI
# =============================================================================

PASS=0
FAIL=0
CLIENT="${IA_CLIENT:-unknown}"

# Couleurs pour l'affichage
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

pass() {
    echo -e "${GREEN}✅ [PASS]${NC} $1"
    ((PASS++))
}

fail() {
    echo -e "${RED}❌ [FAIL]${NC} $1"
    ((FAIL++))
}

warn() {
    echo -e "${YELLOW}⚠️  [WARN]${NC} $1"
}

# =============================================================================
# EN-TÊTE
# =============================================================================

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Tests de Sécurité - Mistral Vibe CLI                        ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# 1. TESTS D'ISOLATION DE L'UTILISATEUR
# =============================================================================

echo "🔒==== 1. Tests d'Isolation de l'Utilisateur ====🔒"
echo ""

# Test 1.1 : Vérifier qu'on n'est pas root
if [ "$(id -u)" = "0" ]; then
    fail "Le conteneur tourne en root (UID=0) !"
else
    pass "Utilisateur non-root (UID=$(id -u))"
fi

# Test 1.2 : Vérifier qu'on ne peut pas devenir root avec sudo
if sudo -n true 2>/dev/null; then
    fail "sudo est accessible sans mot de passe !"
else
    pass "sudo nécessite un mot de passe (ou est bloqué)"
fi

# =============================================================================
# 2. TESTS D'ISOLATION DU SYSTÈME DE FICHIERS
# =============================================================================

echo ""
echo "📁==== 2. Tests d'Isolation du Système de Fichiers ====📁"
echo ""

# Test 2.1 : Vérifier que / est en lecture seule
if touch /test-security 2>/dev/null; then
    fail "Le filesystem racine (/ ) n'est pas en lecture seule !"
    rm -f /test-security 2>/dev/null || true
else
    pass "/ est en lecture seule"
fi

# Test 2.2 : Vérifier que /usr est en lecture seule
if touch /usr/test-security 2>/dev/null; then
    fail "/usr n'est pas en lecture seule !"
    rm -f /usr/test-security 2>/dev/null || true
else
    pass "/usr est en lecture seule"
fi

# Test 2.3 : Vérifier que /etc est en lecture seule
if touch /etc/test-security 2>/dev/null; then
    fail "/etc n'est pas en lecture seule !"
    rm -f /etc/test-security 2>/dev/null || true
else
    pass "/etc est en lecture seule"
fi

# Test 2.4 : Vérifier que /workspace est accessible en écriture
if touch /workspace/test-security 2>/dev/null; then
    pass "/workspace est accessible en écriture"
    rm -f /workspace/test-security
else
    fail "Impossible d'écrire dans /workspace !"
fi

# Test 2.5 : Vérifier que ~/.local est accessible en écriture (pour pip install --user)
if touch /home/${USER}/.local/test-security 2>/dev/null; then
    pass "~/.local est accessible en écriture (pour pip)"
    rm -f /home/${USER}/.local/test-security
else
    fail "Impossible d'écrire dans ~/.local !"
fi

# =============================================================================
# 3. TESTS D'ISOLATION RÉSEAU
# =============================================================================

echo ""
echo "🌐==== 3. Tests d'Isolation Réseau ====🌐"
echo ""

# Test 3.1 : Vérifier qu'on ne peut pas accéder à internet directement
if curl -s -m 5 https://google.com > /dev/null 2>&1; then
    fail "Accès direct à internet autorisé (google.com) !"
else
    pass "Accès direct à internet bloqué"
fi

# Test 3.2 : Vérifier que le proxy est accessible
if curl -s -m 5 -x http://localhost:3128 https://github.com > /dev/null 2>&1; then
    pass "Accès via proxy à github.com autorisé"
else
    fail "Accès via proxy à github.com bloqué !"
fi

# Test 3.3 : Vérifier qu'on peut accéder à api.mistral.ai via proxy
if curl -s -m 5 -x http://localhost:3128 https://api.mistral.ai > /dev/null 2>&1; then
    pass "Accès via proxy à api.mistral.ai autorisé"
else
    warn "Accès via proxy à api.mistral.ai bloqué (vérifiez allowed-urls.txt)"
fi

# Test 3.4 : Vérifier qu'on ne peut pas accéder à une URL non autorisée
if curl -s -m 5 -x http://localhost:3128 https://facebook.com > /dev/null 2>&1; then
    fail "Accès via proxy à facebook.com autorisé (ne devrait pas l'être) !"
else
    pass "Accès via proxy à facebook.com correctement bloqué"
fi

# Test 3.5 : Vérifier qu'on ne peut pas accéder au socket Docker/Podman
for socket in /run/docker.sock /run/podman/podman.sock; do
    if [ -S "$socket" ] && [ -r "$socket" ]; then
        fail "Accès au socket $socket autorisé !"
    elif [ -S "$socket" ]; then
        pass "Socket $socket existe mais n'est pas accessible"
    else
        pass "Socket $socket n'existe pas"
    fi
done

# =============================================================================
# 4. TESTS SPÉCIFIQUES À PYTHON
# =============================================================================

echo ""
echo "🐍==== 4. Tests Spécifiques à Python ====🐍"
echo ""

# Test 4.1 : Vérifier que Python est disponible
if command -v python3 &> /dev/null; then
    pass "Python 3 est disponible : $(python3 --version 2>&1)"
else
    fail "Python 3 n'est pas disponible !"
fi

# Test 4.2 : Vérifier que pip est disponible
if command -v pip &> /dev/null; then
    pass "pip est disponible : $(pip --version 2>&1)"
else
    fail "pip n'est pas disponible !"
fi

# Test 4.3 : Vérifier que pip peut installer dans ~/.local
if pip install --user --dry-run numpy > /dev/null 2>&1; then
    pass "pip peut installer des paquets avec --user"
else
    warn "pip ne peut pas installer de paquets (vérifiez les permissions)"
fi

# Test 4.4 : Vérifier l'accès à PyPI via proxy
if curl -s -m 5 -x http://localhost:3128 https://pypi.org > /dev/null 2>&1; then
    pass "Accès via proxy à pypi.org autorisé"
else
    fail "Accès via proxy à pypi.org bloqué !"
fi

# =============================================================================
# 5. TESTS DE SÉCURITÉ DES PROCESSUS
# =============================================================================

echo ""
echo "⚙️==== 5. Tests de Sécurité des Processus ====⚙️"
echo ""

# Test 5.1 : Vérifier que Squid tourne en nobody
if pgrep -x squid > /dev/null; then
    SQUID_USER=$(ps -o user= -p $(pgrep squid) 2>/dev/null | tr -d ' ')
    if [ "$SQUID_USER" = "nobody" ]; then
        pass "Squid tourne en tant que 'nobody' (sécurisé)"
    else
        fail "Squid tourne en tant que '$SQUID_USER' (devrait être 'nobody') !"
    fi
else
    fail "Squid n'est pas en cours d'exécution !"
fi

# Test 5.2 : Vérifier les capabilities
if command -v capsh &> /dev/null; then
    CAPS=$(capsh --print 2>/dev/null | grep "Current:" | cut -d'=' -f2)
    if [ -z "$CAPS" ] || [ "$CAPS" = " " ]; then
        pass "Aucune capability spéciale (sécurité maximale)"
    else
        warn "Capabilities actives : $CAPS"
    fi
else
    warn "capsh non disponible, impossible de vérifier les capabilities"
fi

# =============================================================================
# 6. RÉSUMÉ DES TESTS
# =============================================================================

echo ""
echo "📊==== 6. Résumé des Tests ====📊"
echo ""
echo "   ${GREEN}✅ Réussis : $PASS${NC}"
echo "   ${RED}❌ Échoués : $FAIL${NC}"
echo ""

# Calcul du score de sécurité
TOTAL=$((PASS + FAIL))
if [ $TOTAL -gt 0 ]; then
    SCORE=$(( (PASS * 100) / TOTAL ))
else
    SCORE=100
fi

echo "   🎯 Score de sécurité : ${SCORE}%"
echo ""

# Message final
if [ $FAIL -eq 0 ]; then
    echo -e "   ${GREEN}✅ TOUS LES TESTS ONT RÉUSSI !${NC}"
    echo "   Le conteneur est sécurisé et prêt pour Mistral Vibe CLI."
    echo ""
    echo "   Pour installer Mistral Vibe :"
    echo "   $ pip install --user mistral-vibe"
    exit 0
else
    echo -e "   ${RED}❌ LE CONTENAIR N'EST PAS COMPLÈTEMENT SÉCURISÉ !${NC}"
    echo "   Corrigez les tests marqués en ❌ avant d'utiliser ce conteneur."
    exit 1
fi
