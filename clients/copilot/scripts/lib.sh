#!/bin/bash
# Adaptateur copilot : uniquement ce qui varie pour ce client. Le reste de
# l'orchestration est générique — voir scripts/common.sh et
# scripts/orchestrator.sh (partagés avec les autres clients), et
# scripts/security-tests-common.sh côté vérifications.
# Sourcé côté hôte (par run.sh) ET copié tel quel dans l'image workspace
# (sourcé par security-tests.sh) : ne doit dépendre de rien d'autre que
# bash — pas de `source` d'un autre fichier ici.
# Doit être sourcé, pas exécuté directement.

CLIENT_NAME="copilot"

# ~/.npm-global contient les VRAIS paquets installés par `npm install -g`
# (pas un simple cache). Le nom du volume Podman (PKG_VOLUME) est dérivé de
# ce chemin par scripts/common.sh — ne pas le déclarer ici.
PKG_VOLUME_TARGET="/home/devuser/.npm-global"
# Jeton substitué dans .devcontainer/devcontainer.json.template par
# render_devcontainer() (scripts/orchestrator.sh).
PKG_VOLUME_PLACEHOLDER="__NPM_GLOBAL_VOLUME__"
# Libellé utilisé dans le message de security-tests-common.sh (section 2).
PKG_INSTALL_LABEL="npm install -g"

# @github/copilot écrit son état (session, jeton d'auth après /login,
# config.json, logs) sous ~/.copilot, distinct de PKG_VOLUME_TARGET
# (~/.npm-global, réservé aux paquets npm). Sans volume dédié, ce chemin
# reste sous le filesystem racine en lecture seule et le CLI plante en
# silence dès le premier lancement (repéré dans ce sandbox : `copilot`
# quitte avec exit 1 sans aucune sortie tant que ~/.copilot n'est pas
# inscriptible). Format "chemin-cible:jeton-devcontainer" (même idiome que
# SECRETS ci-dessous) — consommé par scripts/common.sh (EXTRA_VOLUMES,
# dérive un volume par entrée). Vide par défaut pour un client qui n'a pas
# ce besoin (ex. mistral-vibe) ; un client peut en déclarer plusieurs.
EXTRA_VOLUMES=(
    "/home/devuser/.copilot:__COPILOT_STATE_VOLUME__"
)

# Domaines vérifiés en section 3 de security-tests-common.sh :
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
)

# Callback appelé par scripts/security-tests-common.sh (section 4) —
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
