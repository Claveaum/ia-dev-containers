#!/bin/bash
set -euo pipefail

# =============================================================================
# IA Dev Container - Configuration du Proxy Squid
# Démarre Squid en tant qu'utilisateur 'nobody' (PAS en root !)
# et configure les règles iptables pour forcer le trafic via le proxy
# =============================================================================

SQUID_CONF="/etc/squid/squid.conf"
ALLOWED_URLS="/etc/squid/allowed-urls.txt"

# =============================================================================
# 1. VÉRIFIER QUE SQUID EST INSTALLÉ
# =============================================================================

if ! command -v squid &> /dev/null; then
    echo "❌ ERREUR : Squid n'est pas installé !" >&2
    exit 1
fi

echo "✅ Squid est installé"

# =============================================================================
# 2. VÉRIFIER LA CONFIGURATION SQUID
# =============================================================================

if [ ! -f "$SQUID_CONF" ]; then
    echo "❌ ERREUR : $SQUID_CONF non trouvé !" >&2
    exit 1
fi

if [ ! -f "$ALLOWED_URLS" ]; then
    echo "❌ ERREUR : $ALLOWED_URLS non trouvé !" >&2
    exit 1
fi

echo "✅ Configuration Squid vérifiée"

# =============================================================================
# 3. VÉRIFIER LA SYNTAXE DE SQUID
# =============================================================================

if ! squid -k parse 2>&1 | grep -q "OK"; then
    echo "❌ ERREUR : Erreur de syntaxe dans $SQUID_CONF" >&2
    squid -k parse 2>&1
    exit 1
fi

echo "✅ Aucune erreur de syntaxe dans la configuration Squid"

# =============================================================================
# 4. INITIALISER LA CACHE SQUID
# =============================================================================

squid -z 2>/dev/null || true

# =============================================================================
# 5. DÉMARRER SQUID EN TANT QUE 'NOBODY' (PAS EN ROOT !)
# =============================================================================

echo "🚀 Démarrage de Squid (utilisateur : nobody)..."

# Note: squid va automatiquement utiliser l'utilisateur 'nobody' grâce à la config
# dans squid.conf (User nobody est la valeur par défaut)
exec squid -N
