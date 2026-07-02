#!/bin/bash
set -uo pipefail

# =============================================================================
# IA Dev Container - Tests de sécurité (à exécuter DANS le workspace)
# Modèle à deux conteneurs : ce script ne teste plus jamais localhost, il
# vérifie l'accès réel au gateway (HTTP_PROXY) sur le réseau interne.
# =============================================================================

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

if touch /workspace/test-security 2>/dev/null; then
    pass "/workspace est accessible en écriture"
    rm -f /workspace/test-security
else
    fail "Impossible d'écrire dans /workspace !"
fi

if touch "/home/${USER:-devuser}/.npm-global/test-security" 2>/dev/null; then
    pass "~/.npm-global est accessible en écriture (pour npm install -g)"
    rm -f "/home/${USER:-devuser}/.npm-global/test-security"
else
    fail "Impossible d'écrire dans ~/.npm-global !"
fi

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

# Test 3.2 : registre npm (autorisé) via le gateway
if curl -s -m5 -x "${HTTP_PROXY:-http://gateway:3128}" https://registry.npmjs.org -o /dev/null -w '%{http_code}' 2>/dev/null | grep -qE '^[23]'; then
    pass "Accès via le gateway à registry.npmjs.org (autorisé) réussi"
else
    fail "Accès via le gateway à registry.npmjs.org (autorisé) échoué !"
fi

# Test 3.3 : api.githubcopilot.com — sous-domaine couvert par l'entrée
# ".githubcopilot.com" (avec point de tête) dans allowed-urls.txt. Ce test
# vérifie spécifiquement que le matching de sous-domaine Squid fonctionne
# (une entrée sans point de tête ne matcherait que l'hôte exact).
# (curl écrit déjà "000" lui-même via -w en cas d'échec de connexion ; ne pas
# ajouter de `|| echo "000"` après, ça doublerait la sortie en "000000".)
code=$(curl -s -m5 -x "${HTTP_PROXY:-http://gateway:3128}" https://api.githubcopilot.com -o /dev/null -w '%{http_code}' 2>/dev/null)
code="${code:-000}"
if [ "$code" != "000" ]; then
    pass "Accès via le gateway à api.githubcopilot.com autorisé (http=$code, sous-domaine bien matché)"
else
    warn "Accès via le gateway à api.githubcopilot.com bloqué (vérifiez allowed-urls.txt / matching dstdomain)"
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
# 4. Spécifique Node.js / npm
# =============================================================================
echo ""
echo "⬢ ==== 4. Spécifique Node.js / npm ====⬢ "

if command -v node &> /dev/null; then
    pass "Node.js disponible : $(node --version 2>&1)"
else
    fail "Node.js non disponible !"
fi

if command -v npm &> /dev/null; then
    pass "npm disponible : $(npm --version 2>&1)"
else
    fail "npm non disponible !"
fi

if npm install -g --dry-run @github/copilot &> /dev/null; then
    pass "npm peut installer des paquets globaux dans ~/.npm-global"
else
    warn "npm ne peut pas installer de paquets (vérifiez les permissions ou le réseau)"
fi

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
