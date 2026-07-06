#!/bin/bash
# Adaptateur copilot : uniquement ce qui varie pour ce client. Le reste de
# l'orchestration est générique — voir scripts/orchestrator.py (partagé
# avec les autres clients), et scripts/security-tests.sh côté vérifications.
# Sourcé côté hôte (par run.sh) ET copié tel quel dans l'image workspace
# (sourcé par security-tests.sh) : ne doit dépendre de rien d'autre que
# bash — pas de `source` d'un autre fichier ici.
# Doit être sourcé, pas exécuté directement.

CLIENT_NAME="copilot"

# ~/.npm-global contient les VRAIS paquets installés par `npm install -g`
# (pas un simple cache). Le nom du volume Podman (config.pkg_volume) est
# dérivé de ce chemin par Config.__post_init__ (scripts/orchestrator.py) —
# ne pas le déclarer ici.
PKG_VOLUME_TARGET="/home/devuser/.npm-global"
# Libellé utilisé dans le message de security-tests.sh (section 2).
PKG_INSTALL_LABEL="npm install -g"

# @github/copilot écrit son état (session, jeton d'auth après /login,
# config.json, logs) sous ~/.copilot, distinct de PKG_VOLUME_TARGET
# (~/.npm-global, réservé aux paquets npm). Sans volume dédié, ce chemin
# reste sous le filesystem racine en lecture seule et le CLI plante en
# silence dès le premier lancement (repéré dans ce sandbox : `copilot`
# quitte avec exit 1 sans aucune sortie tant que ~/.copilot n'est pas
# inscriptible). Simple chemin cible par entrée (le mount, côté CLI comme
# côté devcontainer.json, est entièrement dérivé par mounts() et
# devcontainer_mounts_json() dans scripts/orchestrator.py — aucun jeton à
# déclarer ici). Vide par défaut pour un client qui n'a pas ce besoin (ex.
# mistral-vibe) ; un client peut en déclarer plusieurs.
EXTRA_VOLUMES=(
    "/home/devuser/.copilot"
)

# Nom affiché dans devcontainer.json ("name", et repris dans le message de
# postStartCommand) — voir scripts/devcontainer-skeleton.json.template,
# partagé par tous les clients (render_devcontainer() dans
# scripts/orchestrator.py).
DEVCONTAINER_DISPLAY_NAME="GitHub Copilot CLI"

# Extensions VS Code proposées à l'ouverture de ce devcontainer (client
# customizations.vscode.extensions, rendu en JSON par
# devcontainer_extensions_json() dans scripts/orchestrator.py).
DEVCONTAINER_EXTENSIONS=(
    "dbaeumer.vscode-eslint"
    "esbenp.prettier-vscode"
)

# Réglages VS Code propres à ce client (customizations.vscode.settings) :
# aucun au-delà du réglage générique déjà dans le squelette partagé
# (scripts/devcontainer-skeleton.json.template) — vide, contrairement à
# mistral-vibe qui en ajoute (voir son lib.sh).
DEVCONTAINER_SETTINGS_JSON=""

# Commande affichée dans le message de bienvenue (postStartCommand) du
# devcontainer, pour installer le CLI lui-même (jamais fait au build, voir
# workspace/Dockerfile).
PKG_INSTALL_HINT="npm install -g @github/copilot"

# Domaines vérifiés en section 3 de security-tests.sh :
#   TEST_DOMAIN_PRIMARY   doit réussir, sinon échec dur (registre de paquets
#                         de base de l'allowlist)
#   TEST_DOMAIN_SECONDARY doit être joignable (code != 000), sinon
#                         avertissement seulement (domaine propre au
#                         service du client)
TEST_DOMAIN_PRIMARY="registry.npmjs.org"
# Sous-domaine couvert par l'entrée ".githubcopilot.com" (avec point de
# tête) dans allowed-urls.txt : ce domaine vérifie spécifiquement que le
# matching de sous-domaine Squid fonctionne (une entrée sans point de tête
# ne matcherait que l'hôte exact).
TEST_DOMAIN_SECONDARY="api.githubcopilot.com"

# Secrets exposés en variable d'environnement dans le workspace via
# `podman secret` (type=env), si le secret existe. Format par entrée :
# "nom-du-secret:VARIABLE_ENV". Absent -> repli sur .env (--env-file).
# Création : printf '%s' 'ghp_...' | podman secret create copilot-gh-token -
SECRETS=(
    "copilot-gh-token:GH_TOKEN"

    # Registre npm d'entreprise (optionnel) : décommenter si REGISTRY_URL
    # ci-dessous est défini. Création :
    # printf '%s' 'token...' | podman secret create copilot-registry-token -
    # "copilot-registry-token:REGISTRY_TOKEN"
)

# Registre npm d'entreprise (optionnel, vide par défaut = npmjs public
# inchangé). Si défini, REMPLACE le registre npm par défaut (voir
# client_configure_registry() ci-dessous) — pensez à aussi ajouter le domaine
# à gateway/config/allowed-urls.txt (et à ajuster TEST_DOMAIN_PRIMARY plus
# haut si registry.npmjs.org n'est alors plus joignable) puis à reconstruire.
# Le jeton associé est un secret (voir REGISTRY_TOKEN dans SECRETS
# ci-dessus), jamais cette variable. Détail : docs/enterprise-registry.md.
REGISTRY_URL=""
# Non utilisé par npm (authentification par jeton seul, voir
# client_configure_registry() ci-dessous) — présent uniquement pour la
# symétrie avec les autres clients (ex. mistral-vibe/pip, où un identifiant a
# un sens pour netrc).
REGISTRY_USER=""

# Chemin déterministe du fichier écrit par client_configure_registry()
# ci-dessous — calculé ici (pas seulement par un `export` dans le callback)
# pour rester posé via `podman run -e` (voir EXTRA_ENV, run.sh, et
# scripts/orchestrator.py: extra_env_args()) et donc visible aussi depuis
# `run.sh exec` (second shell dans le même workspace) : un `podman exec`
# hérite de l'environnement du conteneur figé à sa création, pas des
# `export` faits ensuite par entrypoint.sh (process PID 1). REGISTRY_TOKEN
# n'a pas besoin du même traitement : il est déjà posé au démarrage par
# `podman secret` (voir secret_args() dans scripts/orchestrator.py), donc
# déjà hérité par un `podman exec`.
REGISTRY_NPMRC="${PKG_VOLUME_TARGET}/.npmrc"
EXTRA_ENV=()
if [ -n "$REGISTRY_URL" ]; then
    EXTRA_ENV+=("NPM_CONFIG_USERCONFIG=${REGISTRY_NPMRC}")
fi

# Callback appelé par workspace-base/scripts/entrypoint.sh au démarrage du
# conteneur, uniquement si REGISTRY_URL est défini — écrit la config npm
# (registry + jeton) à partir de REGISTRY_URL/REGISTRY_TOKEN (ce dernier
# injecté en variable d'environnement par scripts/orchestrator.py, depuis
# SECRETS ci-dessus). $HOME lui-même est en lecture seule (--read-only) :
# tout fichier généré doit vivre sous PKG_VOLUME_TARGET (~/.npm-global), seul
# chemin inscriptible ici. Le jeton est écrit en tant que référence
# littérale ${REGISTRY_TOKEN} : npm l'interpole lui-même depuis
# l'environnement à la lecture de .npmrc, il ne touche donc jamais le disque.
client_configure_registry() {
    : "${REGISTRY_TOKEN:?REGISTRY_URL défini mais REGISTRY_TOKEN absent (voir SECRETS ci-dessus)}"
    local registry_key="${REGISTRY_URL#*://}"
    registry_key="${registry_key%/}"

    {
        printf 'registry=%s\n' "$REGISTRY_URL"
        printf '//%s/:_authToken=${REGISTRY_TOKEN}\n' "$registry_key"
    } > "${REGISTRY_NPMRC}"
    chmod 600 "${REGISTRY_NPMRC}"
}

# Callback appelé par scripts/security-tests.sh (section 4) —
# vérifications propres au gestionnaire de paquets de ce client. pass/fail/
# warn sont définies par le script appelant, pas ici.
client_package_manager_tests() {
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
}
