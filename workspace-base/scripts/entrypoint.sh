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

if [ $# -gt 0 ]; then
    exec "$@"
else
    exec /bin/bash
fi
