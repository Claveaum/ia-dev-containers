# Runtime Node.js officiel (glibc), copié plus bas plutôt qu'installé via le
# gestionnaire de paquets de workspace-base (Debian) : voir le commentaire
# juste en dessous pour le pourquoi (segfault musl/arm64), et l'en-tête de
# workspace-base/Dockerfile pour le contexte complet.
FROM node:22-bookworm-slim AS node-src

FROM ia-dev-containers-workspace-base:latest

# ---- Node.js 22+ (exigence de @github/copilot) + npm ----
# Copié depuis l'image officielle node:22-bookworm-slim (glibc) plutôt
# qu'installé via `apt-get install nodejs` : Debian ne package pas Node >= 22
# dans ses dépôts stables, et surtout, `@github/copilot` segfault de façon
# reproductible sur un binaire natif lié à musl (Alpine, voir l'historique de
# ce Dockerfile) - le lier à glibc (confirmé sur matériel réel, macOS Apple
# Silicon, avant cette bascule) est la raison même du passage de
# workspace-base sur Debian. `/usr/local` regroupe le binaire node et npm/npx
# (symlinks relatifs vers lib/node_modules/npm/bin/) : copier le dossier
# entier préserve ces liens, plutôt que de cibler chaque fichier un par un.
COPY --from=node-src /usr/local/ /usr/local/

# Installation globale sans root : préfixe pointé vers un répertoire déjà
# créé/chown par workspace-base. Le paquet @github/copilot lui-même N'EST
# PAS installé au build (comme mistral-vibe avec pip) : l'utilisateur
# l'installe au runtime avec `npm install -g @github/copilot`, une fois le
# gateway joignable - pas avant, sinon même piège que HTTP_PROXY figé au
# build (voir workspace-base/Dockerfile).
ENV NPM_CONFIG_PREFIX=/home/devuser/.npm-global
ENV PATH="/home/devuser/.npm-global/bin:${PATH}"
# npm écrit son cache par défaut dans ~/.npm, qui n'est pas un volume monté
# (le filesystem racine est --read-only) : rediriger vers ~/.cache, qui l'est
# (même bug que le volume /workspace root-owned croisé sur mistral-vibe -
# npm ne crée pas son répertoire de cache par défaut tout seul en lecture
# seule, il faut le pointer explicitement vers un chemin inscriptible).
ENV NPM_CONFIG_CACHE=/home/devuser/.cache/npm

# Contexte de build = racine du dépôt (voir build_images() dans
# scripts/orchestrator.sh), pas clients/copilot/ : security-tests.sh est
# partagé entre clients et vit hors de ce dossier.
COPY --chmod=0755 scripts/security-tests.sh /security-tests.sh
COPY clients/copilot/scripts/lib.sh /lib.sh

# ~/.npm-global est le PKG_VOLUME_TARGET de ce client (voir scripts/lib.sh) :
# ni générique ni partagé avec mistral-vibe, donc préparé ici et non plus
# dans workspace-base/Dockerfile (voir son commentaire).
#
# Un volume Podman nommé fraîchement créé est vide au premier mount : sans
# ces répertoires déjà présents dans l'image, npm (y compris en --dry-run)
# échoue avec ENOENT sur .npm-global/lib avant même toute tentative
# d'install (repéré via un volume scopé par projet réellement vide, jamais
# vu avant car le volume partagé de dev avait déjà ces dossiers depuis un
# ancien `npm install -g` réel).
#
# ~/.copilot (session, jeton d'auth après /login, logs de @github/copilot) :
# même piège de volume nommé root:root si ce répertoire n'existe pas déjà,
# chowné, dans l'image avant le premier mount.
#
# prepare-state-dir.sh (workspace-base) pose aussi le bit setgid + écriture
# groupe (2775, pas un simple chown) : sans lui, un host dont l'UID diffère
# de celui de devuser (macOS) ne peut pas écrire dans ces répertoires malgré
# son appartenance de groupe via --userns=keep-id (voir ce script pour le
# détail — vécu en prod avec `npm install -g @github/copilot` EACCES sur
# ~/.cache/npm).
RUN /prepare-state-dir.sh \
    /home/devuser/.npm-global \
    /home/devuser/.npm-global/lib \
    /home/devuser/.npm-global/bin \
    /home/devuser/.copilot

VOLUME /home/devuser/.npm-global
VOLUME /home/devuser/.cache
VOLUME /home/devuser/.copilot

# Doit rester la dernière instruction (cf. workspace-base/Dockerfile).
USER devuser
