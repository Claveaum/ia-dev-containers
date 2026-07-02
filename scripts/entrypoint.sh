#!/bin/bash
set -euo pipefail

# =============================================================================
# IA Dev Container - Entrypoint Principal
# Orchestrateur pour les conteneurs clients IA (Mistral Vibe, Copilot, etc.)
# =============================================================================

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  IA Dev Container - $IA_CLIENT                              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# 1. VÉRIFICATIONS DE SÉCURITÉ INITIALES
# =============================================================================

echo "🔒 Vérifications de sécurité..."

# ---- Vérifier qu'on n'est pas root ----
if [ "$(id -u)" = "0" ]; then
    echo "❌ ERREUR CRITIQUE : Le conteneur tourne en root !" >&2
    echo "   Utilisez : podman run --user 1000:1000 ..." >&2
    exit 1
fi
echo "✅ Utilisateur : $(whoami) (UID: $(id -u))"

# =============================================================================
# 2. DÉMARRAGE DU PROXY
# =============================================================================

echo "🔧 Démarrage du proxy Squid..."
/setup-proxy.sh &
PROXY_PID=$!

# Attendre que Squid soit prêt (max 5 secondes)
for i in $(seq 1 10); do
    sleep 0.5
    if ps -p $PROXY_PID > /dev/null; then
        break
    fi
done

if ! ps -p $PROXY_PID > /dev/null; then
    echo "❌ ERREUR : Le proxy Squid n'a pas pu démarrer !" >&2
    exit 1
fi
echo "✅ Proxy Squid démarré (PID: $PROXY_PID)"

# =============================================================================
# 3. CONFIGURATION DES VARIABLES D'ENVIRONNEMENT
# =============================================================================

export HTTP_PROXY=http://localhost:3128
export HTTPS_PROXY=http://localhost:3128
export NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16

# =============================================================================
# 4. MONTAGE DES VOLUMES EN LECTURE SEULE
# =============================================================================

echo "🔧 Application des restrictions de filesystem..."

# Monter les répertoires système en lecture seule
mount --bind -o remount,ro /usr 2>/dev/null || true
mount --bind -o remount,ro /etc 2>/dev/null || true
mount --bind -o remount,ro /lib 2>/dev/null || true
mount --bind -o remount,ro /bin 2>/dev/null || true
mount --bind -o remount,ro /sbin 2>/dev/null || true

# =============================================================================
# 5. RESTRICTIONS SUPPLÉMENTAIRES
# =============================================================================

echo "🔧 Application des restrictions de sécurité..."

# Empêcher l'accès aux sockets Docker/Podman
chmod 000 /run/docker.sock /run/podman/podman.sock 2>/dev/null || true

# Empêcher l'accès aux périphériques système
chmod 000 /dev/kmsg /dev/mem /dev/kmem 2>/dev/null || true

# =============================================================================
# 6. AFFICHAGE DE LA CONFIGURATION
# =============================================================================

echo ""
echo "📋 Configuration :"
echo "   - Client IA : $IA_CLIENT"
echo "   - Workspace : $WORKSPACE"
echo "   - Proxy : http://localhost:3128"
echo "   - Utilisateur : $(whoami)"
echo ""

# =============================================================================
# 7. EXÉCUTION DE LA COMMANDE
# =============================================================================

if [ $# -gt 0 ]; then
    echo "🚀 Exécution de : $*"
    exec "$@"
else
    echo "🚀 Démarrage d'un shell interactif..."
    echo ""
    
    case "$IA_CLIENT" in
        mistral-vibe)
            echo "   📌 Pour installer Mistral Vibe CLI :"
            echo "      pip install --user mistral-vibe"
            echo ""
            echo "   📌 Pour démarrer :"
            echo "      mistral-vibe"
            echo ""
            echo "   📌 Pour mettre à jour :"
            echo "      pip install --user --upgrade mistral-vibe"
            ;;
        *)
            echo "   💡 Conteneur prêt pour le développement sécurisé."
            ;;
    esac
    
    exec /bin/bash
fi
