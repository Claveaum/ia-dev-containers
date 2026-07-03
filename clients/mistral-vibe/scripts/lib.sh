#!/bin/bash
# Adaptateur mistral-vibe : uniquement ce qui varie pour ce client. Le reste
# de l'orchestration est générique — voir scripts/common.sh et
# scripts/orchestrator.sh (partagés avec les autres clients), et
# scripts/security-tests-common.sh côté vérifications.
# Sourcé côté hôte (par run.sh) ET copié tel quel dans l'image workspace
# (sourcé par security-tests.sh) : ne doit dépendre de rien d'autre que
# bash — pas de `source` d'un autre fichier ici.
# Doit être sourcé, pas exécuté directement.

CLIENT_NAME="mistral-vibe"

# ~/.local contient les VRAIS paquets installés par `pip install --user`
# (pas un simple cache). Le nom du volume Podman (PKG_VOLUME) est dérivé de
# ce chemin par scripts/common.sh — ne pas le déclarer ici.
PKG_VOLUME_TARGET="/home/devuser/.local"
# Jeton substitué dans .devcontainer/devcontainer.json.template par
# render_devcontainer() (scripts/orchestrator.sh).
PKG_VOLUME_PLACEHOLDER="__LOCAL_VOLUME__"
# Libellé utilisé dans le message de security-tests-common.sh (section 2).
PKG_INSTALL_LABEL="pip"

# Domaines vérifiés en section 3 de security-tests-common.sh :
#   TEST_DOMAIN_PRIMARY   doit réussir, sinon échec dur (registre de paquets
#                         de base de l'allowlist)
#   TEST_DOMAIN_SECONDARY doit être joignable (code != 000), sinon
#                         avertissement seulement (domaine propre au
#                         service du client)
TEST_DOMAIN_PRIMARY="pypi.org"
TEST_DOMAIN_SECONDARY="api.mistral.ai"

# Secrets exposés en variable d'environnement dans le workspace via
# `podman secret` (type=env), si le secret existe. Format par entrée :
# "nom-du-secret:VARIABLE_ENV". Absent -> repli sur .env (--env-file).
# Création : printf '%s' 'sk-...' | podman secret create mistral-vibe-mistral-api-key -
SECRETS=(
    "mistral-vibe-mistral-api-key:MISTRAL_API_KEY"
)

# Callback appelé par scripts/security-tests-common.sh (section 4) —
# vérifications propres au gestionnaire de paquets de ce client. pass/fail/
# warn sont définies par le script appelant, pas ici.
client_package_manager_tests() {
    if command -v python3 &> /dev/null; then
        pass "Python 3 disponible : $(python3 --version 2>&1)"
    else
        fail "Python 3 non disponible !"
    fi

    if command -v pip &> /dev/null; then
        pass "pip disponible : $(pip --version 2>&1)"
    else
        fail "pip non disponible !"
    fi

    if pip install --user --dry-run numpy &> /dev/null; then
        pass "pip peut installer des paquets avec --user"
    else
        warn "pip ne peut pas installer de paquets (vérifiez les permissions ou le réseau)"
    fi
}
