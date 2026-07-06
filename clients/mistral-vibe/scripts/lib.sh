#!/bin/bash
# Adaptateur mistral-vibe : uniquement ce qui varie pour ce client. Le reste
# de l'orchestration est générique — voir scripts/orchestrator.py (partagé
# avec les autres clients), et scripts/security-tests.sh côté vérifications.
# Sourcé côté hôte (par run.sh) ET copié tel quel dans l'image workspace
# (sourcé par security-tests.sh) : ne doit dépendre de rien d'autre que
# bash — pas de `source` d'un autre fichier ici.
# Doit être sourcé, pas exécuté directement.

CLIENT_NAME="mistral-vibe"

# ~/.local contient les VRAIS paquets installés par `pip install --user`
# (pas un simple cache). Le nom du volume Podman (config.pkg_volume) est
# dérivé de ce chemin par Config.__post_init__ (scripts/orchestrator.py) —
# ne pas le déclarer ici.
PKG_VOLUME_TARGET="/home/devuser/.local"
# Libellé utilisé dans le message de security-tests.sh (section 2).
PKG_INSTALL_LABEL="pip"

# Nom affiché dans devcontainer.json ("name", et repris dans le message de
# postStartCommand) — voir scripts/devcontainer-skeleton.json.template,
# partagé par tous les clients (render_devcontainer() dans
# scripts/orchestrator.py).
DEVCONTAINER_DISPLAY_NAME="Mistral Vibe CLI"

# Extensions VS Code proposées à l'ouverture de ce devcontainer (client
# customizations.vscode.extensions, rendu en JSON par
# devcontainer_extensions_json() dans scripts/orchestrator.py).
DEVCONTAINER_EXTENSIONS=(
    "ms-python.python"
    "ms-python.vscode-pylance"
    "ms-python.black-formatter"
    "ms-python.isort"
    "ms-toolsai.jupyter"
)

# Réglages VS Code propres à ce client (customizations.vscode.settings),
# injectés tels quels avant le réglage générique
# "terminal.integrated.defaultProfile.linux" (déjà dans le squelette partagé
# — ne pas le redéclarer ici). Chaque ligne doit se terminer par une
# virgule : toujours suivi d'au moins ce réglage générique.
DEVCONTAINER_SETTINGS_JSON='        "python.pythonPath": "/home/devuser/.local/bin/python3",
        "python.linting.enabled": true,
        "python.linting.pylintEnabled": true,
        "python.formatting.provider": "black",
        "editor.formatOnSave": true,
        "[python]": {
          "editor.defaultFormatter": "ms-python.black-formatter"
        },'

# Commande affichée dans le message de bienvenue (postStartCommand) du
# devcontainer, pour installer le CLI lui-même (jamais fait au build, voir
# workspace/Dockerfile).
PKG_INSTALL_HINT="pip install --user mistral-vibe"

# Domaines vérifiés en section 3 de security-tests.sh :
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

    # Registre pip d'entreprise (optionnel) : décommenter si REGISTRY_URL
    # ci-dessous est défini. Création :
    # printf '%s' 'token...' | podman secret create mistral-vibe-registry-token -
    # "mistral-vibe-registry-token:REGISTRY_TOKEN"
)

# Registre pip d'entreprise (optionnel, vide par défaut = PyPI public
# inchangé). Si défini, REMPLACE l'index pip par défaut (voir
# client_configure_registry() ci-dessous) — pensez à aussi ajouter le domaine
# à gateway/config/allowed-urls.txt (et à ajuster TEST_DOMAIN_PRIMARY plus
# haut si pypi.org n'est alors plus joignable) puis à reconstruire. Le jeton
# associé est un secret (voir REGISTRY_TOKEN dans SECRETS ci-dessus), jamais
# cette variable. Détail : docs/enterprise-registry.md.
REGISTRY_URL=""
# Identifiant netrc associé (optionnel) — beaucoup de registres pip
# d'entreprise acceptent un identifiant arbitraire type "token" avec le vrai
# secret en mot de passe ; ne renseigner que si votre registre exige un
# identifiant précis.
REGISTRY_USER=""

# Chemins déterministes des fichiers écrits par client_configure_registry()
# ci-dessous — calculés ici (pas seulement par un `export` dans le callback)
# pour rester posés via `podman run -e` (voir EXTRA_ENV, run.sh, et
# scripts/orchestrator.py: extra_env_args()) et donc visibles aussi depuis
# `run.sh exec` (second shell dans le même workspace) : un `podman exec`
# hérite de l'environnement du conteneur figé à sa création, pas des
# `export` faits ensuite par entrypoint.sh (process PID 1).
REGISTRY_PIP_CONF="${PKG_VOLUME_TARGET}/pip.conf"
REGISTRY_NETRC="${PKG_VOLUME_TARGET}/.netrc"
EXTRA_ENV=()
if [ -n "$REGISTRY_URL" ]; then
    EXTRA_ENV+=(
        "PIP_CONFIG_FILE=${REGISTRY_PIP_CONF}"
        "NETRC=${REGISTRY_NETRC}"
    )
fi

# Callback appelé par workspace-base/scripts/entrypoint.sh au démarrage du
# conteneur, uniquement si REGISTRY_URL est défini — écrit la config pip
# (index-url + identifiants) à partir de REGISTRY_URL/REGISTRY_USER/
# REGISTRY_TOKEN (ce dernier injecté en variable d'environnement par
# scripts/orchestrator.py, depuis SECRETS ci-dessus). $HOME lui-même est en
# lecture seule (--read-only) : tout fichier généré doit vivre sous
# PKG_VOLUME_TARGET (~/.local), seul chemin inscriptible ici. PIP_CONFIG_FILE/
# NETRC sont déjà dans l'environnement (posés par EXTRA_ENV ci-dessus au
# `podman run`) : ce callback n'a qu'à écrire les fichiers, pas à les
# exporter.
client_configure_registry() {
    local token="${REGISTRY_TOKEN:?REGISTRY_URL défini mais REGISTRY_TOKEN absent (voir SECRETS ci-dessus)}"
    local user="${REGISTRY_USER:-token}"
    local host="${REGISTRY_URL#*://}"
    host="${host%%/*}"
    host="${host%%:*}"

    printf 'machine %s\nlogin %s\npassword %s\n' "$host" "$user" "$token" \
        > "${REGISTRY_NETRC}"
    chmod 600 "${REGISTRY_NETRC}"

    printf '[global]\nindex-url = %s\n' "$REGISTRY_URL" > "${REGISTRY_PIP_CONF}"
}

# Callback appelé par scripts/security-tests.sh (section 4) —
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
