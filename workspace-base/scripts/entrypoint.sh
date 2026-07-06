#!/bin/bash
set -euo pipefail

echo "IA Dev Container (workspace) - client=${IA_CLIENT:-unknown}"

if [ "$(id -u)" = "0" ]; then
    echo "ERREUR : ce conteneur tourne en root ! Utilisez --user <uid>:<gid>." >&2
    exit 1
fi
echo "utilisateur : $(whoami) (uid=$(id -u))"
echo "proxy       : HTTP_PROXY=${HTTP_PROXY:-<non défini>}"
echo "workspace   : ${WORKSPACE:-/workspace}"
echo ""
echo "Remarque : seuls les remotes git en HTTPS fonctionnent (le SSH/port 22"
echo "n'est pas relayé par le gateway)."
echo ""

# /lib.sh est déjà copié dans l'image par chaque overlay client (voir
# clients/*/workspace/Dockerfile), pour security-tests.sh — le sourcer ici
# aussi est sans effet de bord (rien que des affectations de variables et des
# définitions de fonctions). Si REGISTRY_URL est défini (voir
# scripts/orchestrator.py: registry_env_args()) et que le client fournit le
# callback client_configure_registry() (voir clients/*/scripts/lib.sh), on
# l'appelle pour écrire les fichiers de config pip/npm correspondants
# (NETRC, PIP_CONFIG_FILE, NPM_CONFIG_USERCONFIG déjà présents dans
# l'environnement à ce stade — posés par `podman run -e`, voir EXTRA_ENV
# dans lib.sh et scripts/orchestrator.py: extra_env_args() — précisément
# pour rester visibles aussi depuis un `podman exec` ultérieur, qui n'hérite
# pas des `export` faits par ce process après sa création).
if [ -f /lib.sh ]; then
    # shellcheck source=/dev/null
    source /lib.sh
    if [ -n "${REGISTRY_URL:-}" ] && declare -f client_configure_registry > /dev/null; then
        client_configure_registry
    fi
fi

if [ $# -gt 0 ]; then
    exec "$@"
else
    exec /bin/bash
fi
