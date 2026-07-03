#!/bin/sh
# Prépare un répertoire d'état persistant (paquets installés ou session/jeton
# d'un CLI) avant son tout premier montage en volume Podman nommé. Recette
# unique appelée par workspace-base/Dockerfile (.local, .cache, .npm-global)
# et par les overlays clients pour leurs EXTRA_VOLUMES (ex. clients/copilot/
# workspace/Dockerfile : ~/.copilot, ~/.npm-global/{lib,bin}) — ne pas
# reconstituer ce mkdir/chown/chmod à la main ailleurs.
#
# Le chmod 2775 (et pas 755, ce que ferait un simple chown -R devuser:devuser)
# est le point non-obvious : `--userns=keep-id` (scripts/common.sh,
# WORKSPACE_SECURITY_ARGS) ajoute automatiquement l'UID hôte au groupe
# ${USERNAME} en membre secondaire, mais un mode 755 ne donne au groupe que
# lecture/exécution. Sur un host dont l'UID correspond à USER_UID (Linux,
# souvent 1000), ça ne se voit jamais : l'hôte EST déjà le propriétaire. Sur
# un host dont l'UID diffère (macOS : 501/502), seule cette appartenance de
# groupe permet d'écrire, d'où le bit setgid + écriture groupe.
set -eu

USERNAME="${PREPARE_STATE_DIR_USER:-devuser}"

for dir in "$@"; do
    mkdir -p "$dir"
    chown "${USERNAME}:${USERNAME}" "$dir"
    chmod 2775 "$dir"
done
